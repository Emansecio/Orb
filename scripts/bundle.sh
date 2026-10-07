#!/bin/zsh
# Builds OpenBot.app from the SwiftPM executable (ad-hoc signed, local use only).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/OpenBotMac"

APP="build/OpenBot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OpenBot"
cp -R Sources/OpenBotMac/Resources/Orbs "$APP/Contents/Resources/Orbs"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>OpenBot</string>
  <key>CFBundleDisplayName</key><string>OpenBot</string>
  <key>CFBundleIdentifier</key><string>app.openbot.mac</string>
  <key>CFBundleExecutable</key><string>OpenBot</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>pt-BR</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>O OpenBot usa Mail, Calendário e Notas quando você pede.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Pronto: $APP"
