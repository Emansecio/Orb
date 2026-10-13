#!/bin/zsh
# Builds Orb.app from the SwiftPM executable, for local use.
# Signing: with ORB_SIGN_IDENTITY, or the self-signed "Orb Local" identity when the keychain has it
# (scripts/make-signing-identity.sh), the app keeps the same identity across rebuilds and macOS keeps its
# Automation / Accessibility / Full Disk Access grants. Otherwise (no identity in the keychain, as on CI, or
# ORB_SIGN_IDENTITY=-) it is ad-hoc signed and macOS asks again each build. The script never opens or quits the app.
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

# Version from git, so "Sobre" and diagnostics can tell builds apart: the build number is the commit count, the short
# version is 1.0.<count>, and OrbGitCommit is the short hash ("-dirty" when tracked files have uncommitted changes).
# Falls back to 1.0.0 / 1 / unknown outside a git repository or when git fails.
BUILD_NUMBER="1"
SHORT_VERSION="1.0.0"
GIT_COMMIT="unknown"
if COUNT="$(git rev-list --count HEAD 2>/dev/null)" && [[ "$COUNT" == <1-> ]]; then
  BUILD_NUMBER="$COUNT"
  SHORT_VERSION="1.0.$COUNT"
  if HASH="$(git rev-parse --short HEAD 2>/dev/null)" && [[ -n "$HASH" ]]; then
    GIT_COMMIT="$HASH"
    if [[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null || true)" ]]; then
      GIT_COMMIT="$HASH-dirty"
    fi
  fi
fi
echo "Versão $SHORT_VERSION (build $BUILD_NUMBER, commit $GIT_COMMIT)"

# The heredoc is not quoted so the version values above are expanded; the text below has no other $ or backtick.
# NSAllowsArbitraryLoads stays true on purpose: model providers over plain HTTP (a server on the local network or over
# Tailscale, set up by the user) and web_fetch of HTTP-only sites need loads that App Transport Security would block.
cat > "$APP/Contents/Info.plist" <<PLIST
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
  <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>OrbGitCommit</key><string>$GIT_COMMIT</string>
  <key>CFBundleDevelopmentRegion</key><string>pt-BR</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>NSCalendarsFullAccessUsageDescription</key><string>O Orb lê e cria eventos da sua Agenda, inclusive da conta Google que você adicionou ao Mac, quando você pede.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>O Orb lê e cria lembretes no app Lembretes quando você pede.</string>
  <key>NSAppleEventsUsageDescription</key><string>O Orb controla outros apps quando você pede, como Mail, Calendário, Notas, Finder e navegadores.</string>
  <key>NSMicrophoneUsageDescription</key><string>O Orb usa o microfone quando você clica para ditar uma mensagem. O áudio é transcrito no próprio Mac e não sai dele.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>O Orb transcreve o que você dita no próprio Mac.</string>
</dict>
</plist>
PLIST

SIGN_IDENTITY="${ORB_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  [[ "$IDENTITIES" == *'"Orb Local"'* ]] && SIGN_IDENTITY="Orb Local"
fi
if [[ -n "$SIGN_IDENTITY" && "$SIGN_IDENTITY" != "-" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" "$APP" >/dev/null
  echo "Assinado com \"$SIGN_IDENTITY\": as permissões do macOS sobrevivem a novas compilações."
else
  codesign --force --sign - "$APP" >/dev/null
  echo "Assinatura ad-hoc (sem identidade fixa)."
  [[ -n "${CI:-}" ]] || echo "Dica: assinatura temporária (ad-hoc); o macOS esquece as permissões a cada compilação. Rode scripts/make-signing-identity.sh uma vez para manter."
fi
echo "Pronto: $APP"
# An Orb open from this bundle now runs code that no longer matches the disk: macOS stops handing it the keys it keeps in
# the Keychain (a key pasted in it is written but not read back). It has to be opened again.
if [[ -z "${CI:-}" ]] && pgrep -f "$PWD/$APP/Contents/MacOS/Orb" >/dev/null 2>&1; then
  echo "Atenção: o Orb está aberto com a versão anterior. Feche (⌘Q) e abra de novo; até lá ele não lê as chaves do Keychain."
fi
