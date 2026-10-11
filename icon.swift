// Renders the app logo to icon.png (1024×1024). Run: swift icon.swift
import SwiftUI

func hex(_ v: UInt32, _ a: Double = 1) -> Color {
    Color(red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255, opacity: a)
}

let line = hex(0xFFFFFF, 0.14)
let mint = [hex(0x34D399), hex(0x22D3EE)]

let chip = ZStack {
    RoundedRectangle(cornerRadius: 56, style: .continuous).stroke(line, lineWidth: 14).frame(width: 440, height: 440)
    ForEach(0..<4) { side in
        HStack(spacing: 49) { ForEach(0..<4) { _ in Capsule().fill(line).frame(width: 14, height: 48) } }
            .offset(y: -251)
            .rotationEffect(.degrees(Double(side) * 90))
    }
    HStack(alignment: .bottom, spacing: 26) {
        ForEach([0.42, 0.78, 0.58, 0.95], id: \.self) { h in
            Capsule().fill(LinearGradient(colors: mint, startPoint: .bottom, endPoint: .top)).frame(width: 56, height: 264 * h)
        }
    }
    .frame(height: 264, alignment: .bottom)
}

let badge = RoundedRectangle(cornerRadius: 48, style: .continuous).fill(hex(0x16181D))
    .overlay(RoundedRectangle(cornerRadius: 48, style: .continuous).stroke(hex(0xFFFFFF, 0.16), lineWidth: 10))
    .overlay(
        Text(">_").font(.system(size: 150, weight: .heavy, design: .monospaced))
            .foregroundStyle(LinearGradient(colors: mint, startPoint: .bottomLeading, endPoint: .topTrailing))
            .offset(y: -6)
    )
    .frame(width: 300, height: 220)
    .shadow(color: .black.opacity(0.45), radius: 24, y: 12)

let logo = ZStack {
    RoundedRectangle(cornerRadius: 185, style: .continuous)
        .fill(LinearGradient(colors: [hex(0x2B2E36), hex(0x111317)], startPoint: .top, endPoint: .bottom))
        .frame(width: 824, height: 824)
        .shadow(color: .black.opacity(0.28), radius: 14, y: 10)
    chip.offset(x: -40, y: -40)
    badge.offset(x: 200, y: 215)
}
.frame(width: 1024, height: 1024)

MainActor.assumeIsolated {
    let image = ImageRenderer(content: logo).nsImage!
    try! NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "icon.png"))
}
