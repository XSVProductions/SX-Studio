#!/bin/bash
# Started by the SX Helper app (Contents/MacOS/SXHelper): needs PowerShell 7 (offers to install it),
# then starts the Helper's server in the background. The app shows the window. Exit 0 = started, anything else = give up.
RES="$(cd "$(dirname "$0")" && pwd)"
LOG="$HOME/AwaazTools/showxpress_helper_error.log"
mkdir -p "$HOME/AwaazTools"

find_pwsh() {
  for p in "$(command -v pwsh 2>/dev/null)" /usr/local/bin/pwsh /usr/local/microsoft/powershell/7/pwsh /opt/homebrew/bin/pwsh; do
    [ -n "$p" ] && [ -x "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}
alert() { osascript -e "display alert \"SX Helper\" message \"$1\"" >/dev/null 2>&1; }

PW="$(find_pwsh)"
if [ -z "$PW" ]; then
  ans="$(osascript -e 'button returned of (display dialog "SX Helper needs PowerShell 7 (free, from Microsoft).\n\nDownload and install it now? macOS will ask for your password." buttons {"Cancel", "Install"} default button "Install" with title "SX Helper")' 2>/dev/null)"
  [ "$ans" = "Install" ] || exit 3
  case "$(uname -m)" in arm64) ARCH=osx-arm64;; *) ARCH=osx-x64;; esac
  osascript -e 'display notification "Downloading PowerShell 7..." with title "SX Helper"' >/dev/null 2>&1
  URL="$(curl -fsSL https://api.github.com/repos/PowerShell/PowerShell/releases/latest | grep -o "https://[^\"]*powershell-[0-9.]*-$ARCH\.pkg" | head -n 1)"
  PKG="/tmp/powershell-$ARCH.pkg"
  if [ -z "$URL" ] || ! curl -fsSL -o "$PKG" "$URL"; then
    alert "Couldn't download PowerShell 7. Check the internet connection, or install it by hand (search: install PowerShell on macOS)."
    exit 1
  fi
  osascript -e "do shell script \"installer -pkg '$PKG' -target /\" with administrator privileges" >/dev/null 2>>"$LOG"
  rm -f "$PKG"
  PW="$(find_pwsh)"
  [ -n "$PW" ] || { alert "PowerShell 7 didn't install (this macOS may be too old for the newest version). Details: ~/AwaazTools/showxpress_helper_error.log"; exit 1; }
fi

nohup "$PW" -NoProfile -File "$RES/df_aim_gui.ps1" -NoBrowser >/dev/null 2>"$LOG" &
disown
exit 0
