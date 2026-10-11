#!/bin/sh
# Builds GPUBar.app next to this script. Run it with: open GPUBar.app
set -e
cd "$(dirname "$0")"
mkdir -p GPUBar.app/Contents/MacOS GPUBar.app/Contents/Resources
swiftc -O -parse-as-library GPUBar.swift -o GPUBar.app/Contents/MacOS/GPUBar

set_=$(mktemp -d)/AppIcon.iconset
mkdir "$set_"
for s in 16 32 128 256 512; do
  sips -z $s $s icon.png --out "$set_/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) icon.png --out "$set_/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$set_" -o GPUBar.app/Contents/Resources/AppIcon.icns

cat > GPUBar.app/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>GPUBar</string>
<key>CFBundleIdentifier</key><string>local.gpubar</string>
<key>CFBundleName</key><string>GPUBar</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign -s - --force GPUBar.app
