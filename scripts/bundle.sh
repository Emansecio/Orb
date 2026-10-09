#!/bin/zsh
# Builds Orb.app from the SwiftPM executable, for local use.
# Signing: with ORB_SIGN_IDENTITY, or the self-signed "Orb Local" identity when the keychain has it
# (scripts/make-signing-identity.sh), the app keeps the same identity across rebuilds and macOS keeps its
# Automation / Accessibility / Full Disk Access grants. Otherwise it is ad-hoc signed and macOS asks again each build.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Orb"

APP="build/Orb.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Orb"
cp -R Sources/Orb/Resources/Orbs "$APP/Contents/Resources/Orbs"

# App icon: rendered by the app itself (AppIcon), straight at each size.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  "$BIN" --render-icon "$ICONSET/icon_${size}x${size}.png" $size
  "$BIN" --render-icon "$ICONSET/icon_${size}x${size}@2x.png" $((size * 2))
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Orb</string>
  <key>CFBundleDisplayName</key><string>Orb</string>
  <key>CFBundleIdentifier</key><string>app.orb.mac</string>
  <key>CFBundleExecutable</key><string>Orb</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>pt-BR</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>NSCalendarsFullAccessUsageDescription</key><string>O Orb lê e cria eventos da sua Agenda, inclusive da conta Google que você adicionou ao Mac, quando você pede.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>O Orb lê e cria lembretes no app Lembretes quando você pede.</string>
  <key>NSAppleEventsUsageDescription</key><string>O Orb controla outros apps quando você pede, como Mail, Calendário, Notas, Finder e navegadores.</string>
</dict>
</plist>
PLIST

SIGN_IDENTITY="${ORB_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  [[ "$IDENTITIES" == *'"Orb Local"'* ]] && SIGN_IDENTITY="Orb Local"
fi
if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" "$APP" >/dev/null
  echo "Assinado com \"$SIGN_IDENTITY\": as permissões do macOS sobrevivem a novas compilações."
else
  codesign --force --sign - "$APP" >/dev/null
  echo "Dica: assinatura temporária (ad-hoc); o macOS esquece as permissões a cada compilação. Rode scripts/make-signing-identity.sh uma vez para manter."
fi
echo "Pronto: $APP"
