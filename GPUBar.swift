// GPUBar: menu bar overview of GPU usage on remote hosts, via `ssh <host> nvidia-smi`.
// Hosts: one per line in ~/.config/gpubar/hosts, resolved through ~/.ssh/config (users, jump hosts, ControlMaster).
import ServiceManagement
import SwiftUI

let hostsFile = URL.homeDirectory.appending(path: ".config/gpubar/hosts")
// The ssh user's name, GPU rows, then "uuid, pid, MiB, owner, command" per compute process. sh -c: any login shell.
let query = """
sh -c 'id -un && \
nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,uuid --format=csv,noheader,nounits && \
nvidia-smi --query-compute-apps=gpu_uuid,pid,used_memory --format=csv,noheader,nounits | \
while IFS=", " read -r g p m; do \
echo "$g, $p, $m, $(stat -c %U /proc/$p 2>/dev/null), $(tr "\\0" " " 2>/dev/null </proc/$p/cmdline)"; done'
"""

// Re-read on every refresh, so edits apply without a restart. Lines starting with # are skipped.
func hosts() -> [String] {
    ((try? String(contentsOf: hostsFile, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

struct GPU: Identifiable {
    let id: Int, name: String, util: Int, memUsed: Int, memTotal: Int, temp: Int
    var procs: [Proc] = []
    var mine: Int { procs.filter(\.mine).map(\.mib).reduce(0, +) }  // MiB held by your processes
    var you: Bool { procs.contains(where: \.mine) }
    var users: [String] { Set(procs.filter { !$0.mine }.map(\.user)).sorted() }  // everyone else
    // free = idle and holding under 5% of its memory
    var free: Bool { util < 10 && memUsed * 20 < memTotal }
}

struct Proc {
    let pid: String, mib: Int, user: String, mine: Bool, command: String
}

struct Node: Identifiable {
    let id: String
    var gpus: [GPU] = []
    var error: String?
}

func fetch(_ host: String) async -> Node {
    await withCheckedContinuation { done in
        let p = Process(), out = Pipe(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, query]
        p.standardOutput = out
        p.standardError = err
        p.terminationHandler = { p in
            let text = { (pipe: Pipe) in String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }
            guard p.terminationStatus == 0 else {
                let msg = p.terminationReason == .uncaughtSignal ? "timed out" : text(err).split(separator: "\n").last.map(String.init)
                return done.resume(returning: Node(id: host, error: msg ?? "exit \(p.terminationStatus)"))
            }
            let lines = text(out).split(separator: "\n")
            let me = lines.first.map(String.init) ?? ""
            var procs = [String: [Proc]]()
            for l in lines where l.hasPrefix("GPU-") {  // the command is last and may itself contain commas
                let f = l.split(separator: ",", maxSplits: 4, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                guard f.count == 5, !f[3].isEmpty else { continue }  // empty owner: process exited meanwhile
                procs[f[0], default: []].append(Proc(pid: f[1], mib: Int(f[2]) ?? 0, user: f[3], mine: f[3] == me, command: f[4]))
            }
            let gpus = lines.filter { !$0.hasPrefix("GPU-") }.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                .filter { $0.count == 7 }.map { f in
                    let n = f.map { Int($0) ?? 0 }  // "[N/A]" fields read as 0
                    return GPU(id: n[0], name: f[1].replacingOccurrences(of: "NVIDIA ", with: ""), util: n[2], memUsed: n[3], memTotal: n[4], temp: n[5],
                               procs: procs[f[6], default: []].sorted { $0.mib > $1.mib })
                }
            done.resume(returning: Node(id: host, gpus: gpus))
        }
        do { try p.run() } catch { return done.resume(returning: Node(id: host, error: error.localizedDescription)) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { if p.isRunning { p.terminate() } }
    }
}

@MainActor @Observable final class Monitor {
    var nodes = hosts().map { Node(id: $0) }
    var updated: Date?
    var interval = UserDefaults.standard.object(forKey: "interval") as? Double ?? 10
    var openAtLogin = SMAppService.mainApp.status == .enabled
    var gpus: [GPU] { nodes.flatMap(\.gpus) }
    var expanded: Set<String> = []  // "host/index" of GPUs showing their processes
    var pinned = false  // popover stays open when it loses focus
    @ObservationIgnored private var loop: Task<Void, Never>?

    init() { restart() }

    // Poll now, then every `interval`. Called again on a manual refresh or a new interval.
    func restart() {
        loop?.cancel()
        loop = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func refresh() async {
        let hs = hosts()
        let byHost = await withTaskGroup(of: Node.self) { g in
            for h in hs { g.addTask { await fetch(h) } }
            return await g.reduce(into: [String: Node]()) { $0[$1.id] = $1 }
        }
        nodes = hs.map { byHost[$0]! }
        updated = .now
    }

    func setInterval(_ seconds: Double) {
        interval = seconds
        UserDefaults.standard.set(seconds, forKey: "interval")
        restart()
    }

    func setOpenAtLogin(_ on: Bool) {
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// AppKit status item + NSPopover: unlike MenuBarExtra, a popover can stay open when it loses focus (pin).
@main @MainActor final class GPUBar: NSObject {
    static func main() {
        let app = NSApplication.shared
        withExtendedLifetime(GPUBar()) { app.run() }
    }

    let monitor = Monitor()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()

    override init() {
        super.init()
        let host = NSHostingController(rootView: Panel(monitor: monitor))
        host.sizingOptions = .preferredContentSize  // popover follows the panel's height as rows expand
        popover.contentViewController = host
        item.button?.image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "GPUs")
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        sync()
    }

    @objc func toggle() {
        guard let b = item.button else { return }
        if popover.isShown { popover.performClose(nil) } else { NSApp.activate(); popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY) }
    }

    // Re-run whenever the menu bar numbers or the pin change.
    func sync() {
        withObservationTracking {
            let g = monitor.gpus
            item.button?.title = g.isEmpty ? " –" : " \(g.filter(\.free).count)/\(g.count) · \(g.map(\.util).reduce(0, +) / g.count)%"
            popover.behavior = monitor.pinned ? .applicationDefined : .transient
        } onChange: {
            Task { @MainActor in self.sync() }
        }
    }
}

struct Panel: View {
    let monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if monitor.nodes.isEmpty {
                Text("Add SSH hosts, one per line, to ~/.config/gpubar/hosts").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(monitor.nodes) { node in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(node.id).font(.headline)
                        Spacer()
                        if let e = node.error {
                            Text(e).foregroundStyle(.red).lineLimit(1).truncationMode(.tail).help(e)
                        } else if let g = node.gpus.first {
                            Text("\(node.gpus.filter(\.free).count)/\(node.gpus.count) free · \(g.name)").foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .font(.caption)
                    ForEach(node.gpus) { g in
                        let key = "\(node.id)/\(g.id)"
                        Row(gpu: g).onTapGesture { monitor.expanded.formSymmetricDifference([key]) }
                        if monitor.expanded.contains(key) {
                            ForEach(g.procs, id: \.pid) { p in
                                HStack(spacing: 8) {
                                    Text(p.pid).frame(width: 50, alignment: .trailing)
                                    (p.mine ? Text("you").foregroundStyle(.purple) : Text(p.user)).frame(width: 62, alignment: .leading)
                                    Text(String(format: "%.1fG", Double(p.mib) / 1024)).frame(width: 38, alignment: .trailing)
                                    Text(p.command).lineLimit(1).truncationMode(.middle).help(p.command)
                                }
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                if let t = monitor.updated { Text("Updated \(t, style: .time)") }
                Spacer()
                Button { monitor.restart() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh now")
                Button { monitor.pinned.toggle() } label: { Image(systemName: monitor.pinned ? "pin.fill" : "pin") }
                    .help(monitor.pinned ? "Unpin" : "Keep open when clicking elsewhere")
                let interval = monitor.interval, on = monitor.openAtLogin  // read here so the panel re-renders when they change
                Menu {
                    Picker("Refresh every", selection: Binding(get: { interval }, set: { monitor.setInterval($0) })) {
                        ForEach([5.0, 10, 30, 60], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                    }
                    Toggle("Open at login", isOn: Binding(get: { on }, set: { monitor.setOpenAtLogin($0) }))
                    Divider()
                    Button("Quit GPUBar") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 410)
    }
}

struct Row: View {
    let gpu: GPU

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(gpu.free ? .green : .orange).frame(width: 6, height: 6)
            Text("\(gpu.id)").foregroundStyle(.secondary)
            Bar(fraction: Double(gpu.util) / 100, color: .accentColor)
            Text("\(gpu.util)%").frame(width: 32, alignment: .trailing)
            Bar(fraction: Double(gpu.memUsed) / Double(max(gpu.memTotal, 1)), color: .secondary, mine: Double(gpu.mine) / Double(max(gpu.memTotal, 1)))
            Text(gpu.mine > 0 ? "\(gb(gpu.mine))G" : "").foregroundStyle(.purple).frame(width: 26, alignment: .trailing)
            Text("\(gb(gpu.memUsed))/\(gb(gpu.memTotal))G").frame(width: 50, alignment: .trailing)
            Text("\(gpu.temp)°").foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
            // "you" in purple, so a user literally named "you" stays distinguishable
            let others = gpu.users.joined(separator: ", ")
            (gpu.you ? Text("\(Text("you").foregroundStyle(.purple))\(others.isEmpty ? "" : ", " + others)") : Text(others))
                .foregroundStyle(.secondary).lineLimit(1).frame(width: 62, alignment: .leading)
        }
        .font(.system(size: 11).monospacedDigit())
        .contentShape(.rect)
        .help("\(gpu.name) · \(gpu.procs.count) processes, click to show")
    }

    func gb(_ mib: Int) -> Int { Int((Double(mib) / 1024).rounded()) }
}

struct Bar: View {
    let fraction: Double, color: Color
    var mine = 0.0  // your share, drawn over the fill in purple

    var body: some View {
        Capsule().fill(.quaternary)
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule().fill(color).frame(width: g.size.width * fraction)
                    Capsule().fill(.purple).frame(width: g.size.width * mine)
                }
            }
            .frame(height: 5)
    }
}
