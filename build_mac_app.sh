#!/usr/bin/env bash
# Builds both the standalone PingCube binary and a macOS PingCube.app bundle.
set -euo pipefail

cd "$(dirname "$0")"

echo "Compiling PingCube.swift..."
swiftc -O PingCube.swift -o PingCube
chmod +x PingCube

APP_DIR="PingCube.app/Contents"
mkdir -p "$APP_DIR/MacOS"
cp PingCube "$APP_DIR/MacOS/PingCube"

cat > "$APP_DIR/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>PingCube</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.pingcube</string>
    <key>CFBundleName</key>
    <string>PingCube</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "✅ Done! You can now run:"
echo "   ./PingCube"
echo "   or: open PingCube.app"
