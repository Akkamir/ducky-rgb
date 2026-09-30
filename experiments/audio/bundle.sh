#!/bin/sh
# Builds DuckyAudio.app (ad hoc signed); the bundle carries the audio capture usage string macOS requires.
set -eu
cd "$(dirname "$0")"
swift build -c release
APP="build/DuckyAudio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/AudioSpike "$APP/Contents/MacOS/AudioSpike"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AudioSpike</string>
<key>CFBundleIdentifier</key><string>com.akkamir.ducky-audio</string>
<key>CFBundleName</key><string>Ducky Audio</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.2</string>
<key>LSUIElement</key><true/>
<key>NSAudioCaptureUsageDescription</key><string>Ducky RGB lit le son du système pour animer le clavier au rythme de la musique.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "$APP"
