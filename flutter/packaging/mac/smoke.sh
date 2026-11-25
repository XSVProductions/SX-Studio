#!/bin/bash
# Installs the built pkg, opens the app and checks it answers. Used by the build workflow (needs sudo).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
sudo installer -pkg "$ROOT"/build/mac/*.pkg -target /
A="/Applications/SX Studio.app/Contents"
test -x "$A/MacOS/SX Studio" && test -x "$A/MacOS/sxh_dmx" && test -f "$A/Resources/web/index.html" && test -f "$A/Resources/AppIcon.icns"
lipo "$A/MacOS/SX Studio" -verify_arch x86_64 arm64
lipo "$A/MacOS/sxh_dmx" -verify_arch x86_64 arm64
# nothing of the PowerShell app may be left inside
test ! -e "$A/Resources/df_aim_gui.ps1" && test ! -e "$A/MacOS/SXHelper"
open -n "/Applications/SX Studio.app" --env SX_PORT=47390
CODE=0
for i in $(seq 30); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:47390/api/sx || true)"
  [ "$CODE" = 403 ] && break
  sleep 1
done
# no key, so the engine must refuse: that proves it is up and guarded
test "$CODE" = 403
curl -fsS http://127.0.0.1:47390/ | grep -q flutter
osascript -e 'quit app id "io.github.aimmovers.app"' || true
echo "Installer OK"
