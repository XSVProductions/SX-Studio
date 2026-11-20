#!/bin/bash
# Builds build/mac/ShowXpress-Helper-mac-<version>.pkg  (run on macOS: needs sips, iconutil, pkgbuild, productbuild)
set -euo pipefail
VER="${1:-1.0.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="$ROOT/build/mac"
APP="$B/payload/ShowXpress Helper.app"
rm -rf "$B"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$B/scripts"

cp "$ROOT/mac/run" "$APP/Contents/MacOS/run"
sed "s/__VERSION__/$VER/g" "$ROOT/mac/Info.plist" > "$APP/Contents/Info.plist"
cp "$ROOT/src/df_aim.ps1" "$ROOT/src/df_aim_gui.ps1" "$ROOT/src/skip_flash.ps1" "$ROOT/src/rig.ps1" "$ROOT/src/apc.ps1" "$ROOT/src/speed.ps1" "$ROOT/src/health.ps1" "$ROOT/src/rig_test.ps1" "$ROOT/src/preshow.ps1" "$ROOT/src/color.ps1" "$ROOT/src/gdrive.ps1" "$ROOT/src/show_common.ps1" "$ROOT/src/version.txt" "$ROOT/assets/aim_movers_1024.png" "$APP/Contents/Resources/"
chmod 755 "$APP/Contents/MacOS/run"

IS="$B/AppIcon.iconset"; mkdir -p "$IS"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ROOT/assets/aim_movers_1024.png" --out "$IS/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2)); sips -z $d $d "$ROOT/assets/aim_movers_1024.png" --out "$IS/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$IS" -o "$APP/Contents/Resources/AppIcon.icns"

cp "$ROOT/mac/scripts/postinstall" "$B/scripts/postinstall"
chmod 755 "$B/scripts/postinstall"

# always install to /Applications (don't follow a copy the user moved somewhere else)
pkgbuild --analyze --root "$B/payload" "$B/component.plist"
plutil -replace 0.BundleIsRelocatable -bool NO "$B/component.plist"
pkgbuild --root "$B/payload" --component-plist "$B/component.plist" --install-location /Applications \
  --scripts "$B/scripts" --identifier io.github.aimmovers.pkg --version "$VER" "$B/component.pkg"
productbuild --package "$B/component.pkg" "$B/ShowXpress-Helper-mac-$VER.pkg"
rm -f "$B/component.pkg"
echo "built $B/ShowXpress-Helper-mac-$VER.pkg"
