#!/bin/bash
# Builds build/mac/SX-Studio-mac-<version>.pkg. Run on macOS with Flutter on PATH
# (needs Xcode's swiftc, codesign, pkgbuild, productbuild).
#   bash packaging/mac/build_pkg.sh 2.0.0
set -euo pipefail
VER="${1:-2.0.0}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
B="$ROOT/build/mac"
APP="$B/payload/SX Studio.app"

cd "$ROOT/ui"
# no CDN: a phone on a venue network must get every file from the laptop
flutter build web --release --no-web-resources-cdn
flutter build macos --release --build-name="$VER" --dart-define=SX_VERSION="$VER"

rm -rf "$B"
mkdir -p "$B/payload" "$B/scripts"
ditto "$ROOT/ui/build/macos/Build/Products/Release/SX Studio.app" "$APP"
# the page phones and tablets load from the laptop
ditto "$ROOT/ui/build/web" "$APP/Contents/Resources/web"
# live output's DMX tool: ShowXpress's Mac driver is Intel only, so this tool is too (Rosetta on Apple Silicon)
xcrun swiftc -O -target x86_64-apple-macos10.15 "$ROOT/packaging/mac/dmx/main.swift" -o "$APP/Contents/MacOS/sxh_dmx"
chmod 755 "$APP/Contents/MacOS/sxh_dmx"

# ad-hoc signature (Apple Silicon only runs signed code). The app changed after Flutter signed it, so sign again.
codesign --force --sign - "$APP/Contents/MacOS/sxh_dmx"
codesign --force --sign - "$APP"
codesign --verify --deep --strict --verbose "$APP"

cp "$ROOT/packaging/mac/scripts/preinstall" "$ROOT/packaging/mac/scripts/postinstall" "$B/scripts/"
chmod 755 "$B/scripts/preinstall" "$B/scripts/postinstall"

# always install to /Applications (don't follow a copy the user moved somewhere else)
pkgbuild --analyze --root "$B/payload" "$B/component.plist"
plutil -replace 0.BundleIsRelocatable -bool NO "$B/component.plist"
pkgbuild --root "$B/payload" --component-plist "$B/component.plist" --install-location /Applications \
  --scripts "$B/scripts" --identifier io.github.aimmovers.pkg --version "$VER" "$B/component.pkg"
productbuild --package "$B/component.pkg" "$B/SX-Studio-mac-$VER.pkg"
rm -f "$B/component.pkg"
echo "built $B/SX-Studio-mac-$VER.pkg"
