#!/bin/zsh
set -euo pipefail

APP_NAME="mixerMac"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

cd "$ROOT_DIR"
pkill -x "$APP_NAME" 2>/dev/null || true
TASK_BUILD_MODE="${MIXERMAC_BUILD_CONFIGURATION:-release}"
swift build -c "$TASK_BUILD_MODE"
TASK_BIN_DIR="$(swift build -c "$TASK_BUILD_MODE" --show-bin-path)"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$TASK_BIN_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/LICENSE" "$APP_BUNDLE/Contents/Resources/LICENSE"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleExecutable</key><string>$APP_NAME</string>
<key>CFBundleIdentifier</key><string>local.mixermac.app</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.2</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSMicrophoneUsageDescription</key><string>mixerMac reads system playback from its optional virtual audio input device for EQ processing. It does not open your physical microphone.</string>
<key>NSAudioCaptureUsageDescription</key><string>mixerMac analyzes the sound playing on your Mac to display the live spectrum and level meters. No audio is saved or uploaded.</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"
/usr/bin/open -n "$APP_BUNDLE"

if [[ "${1:-}" == "--verify" ]]; then
  sleep 1
  pgrep -x "$APP_NAME" >/dev/null
  echo "$APP_NAME is running (PID $(pgrep -x "$APP_NAME" | head -1))."
fi
