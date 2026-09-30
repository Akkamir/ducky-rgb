#!/bin/sh
# Builds "Ducky RGB.app" from the Swift package, ad hoc signed for local use.
set -eu
cd "$(dirname "$0")/.."

swift build -c release --product DuckyRGB
BIN="$(swift build -c release --show-bin-path)/DuckyRGB"
APP="build/Ducky RGB.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DuckyRGB"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DuckyRGB</string>
    <key>CFBundleIdentifier</key><string>com.akkamir.ducky-rgb</string>
    <key>CFBundleName</key><string>Ducky RGB</string>
    <key>CFBundleDisplayName</key><string>Ducky RGB</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.2</string>
    <key>NSAudioCaptureUsageDescription</key><string>Ducky RGB lit le son du système pour animer le clavier au rythme de la musique.</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "$APP"
