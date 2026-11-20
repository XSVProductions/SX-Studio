#!/bin/bash
# SYNC FROM WINDOWS  -  Awaaz Lightshow: Windows (Boot Camp) side -> this Mac.  ONE WAY ONLY.
#   The Mac show folder is found the first time and remembered in ~/AwaazTools/show_path.txt
#   (delete that file to choose again).
#   Before every sync the Mac show is saved to ~/AwaazTools/previous Mac show (one copy, replaced each time).
#   Part of ShowXpress Helper (installed inside ShowXpress Helper.app; Desktop launcher made by the installer).

SHOW="Awaaz Lightshow"
TOOLS="$HOME/AwaazTools"
PATHFILE="$TOOLS/show_path.txt"
PREV="$TOOLS/previous Mac show"
mkdir -p "$TOOLS"

fail() { echo; echo "  $1"; echo "  NOTHING was changed."; echo; exit 1; }

echo
echo "  SYNC FROM WINDOWS  ($SHOW)"
echo "  ------------------------------------"

# 1. ShowXpress must be closed (it rewrites the show when it quits)
if ps -axo comm= | grep -iqE 'showxpress|lightingcontroller'; then
  fail "ShowXpress is OPEN - quit it (save first) and run this again."
fi

# 2. the Windows drive (macOS shows it read-only under /Volumes, normally /Volumes/BOOTCAMP)
SRC=""
for s in /Volumes/*/Users/*/TheLightingController/LightShows/"$SHOW"; do
  if [ -f "$s/Live/live.ini" ]; then SRC="$s"; break; fi
done
if [ -z "$SRC" ]; then
  fail "Can't find the Windows show. Check the BOOTCAMP drive shows in Finder.
  If macOS asked whether Terminal may access files, say Allow
  (System Settings > Privacy & Security > Files and Folders > Terminal)."
fi
echo "  from: $SRC"

# 3. where the show lives on this Mac
valid_dest() {   # an existing ShowXpress show, or a new folder inside an existing folder; never home/volumes
  local d="$1"
  case "$d" in ""|"/"|"$HOME"|"$HOME/"|/Volumes/*|"$TOOLS"*) return 1;; esac
  [ -f "$d/Live/live.ini" ] && return 0
  [ ! -e "$d" ] && [ -d "$(dirname "$d")" ] && return 0
  return 1
}
clean_path() {   # path typed or dragged into Terminal: strip quotes, \-escapes, trailing spaces/slash
  local p="$1"
  p="$(printf '%s' "$p" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e "s/^'//" -e "s/'\$//" -e 's/^"//' -e 's/"$//' -e 's/\\\(.\)/\1/g' -e 's:/*$::')"
  printf '%s' "$p"
}

DEST=""
FIRST=0
if [ -f "$PATHFILE" ]; then
  DEST="$(head -n 1 "$PATHFILE")"
  valid_dest "$DEST" || { echo "  saved Mac show folder no longer valid: $DEST"; DEST=""; }
fi
if [ -z "$DEST" ]; then
  FIRST=1
  echo "  looking for ShowXpress shows on this Mac (first time only, takes a moment)..."
  PRUNE=( \( -path "$HOME/Library/CloudStorage" -o -path "$HOME/Library/Mobile Documents" -o -path "$HOME/Library/Containers"
          -o -path "$HOME/Library/Group Containers" -o -path "$HOME/Library/Caches" -o -path "$HOME/.Trash"
          -o -path "$TOOLS" -o -name "*.photoslibrary" -o -name "node_modules" \) -prune -o )
  CANDS=()
  while IFS= read -r f; do
    CANDS+=("$(dirname "$(dirname "$f")")")
  done < <(find "$HOME" /Users/Shared -maxdepth 8 "${PRUNE[@]}" -type f -path "*/Live/live.ini" -print 2>/dev/null)
  if [ ${#CANDS[@]} -eq 0 ]; then   # no show yet - offer LightShows folders
    while IFS= read -r d; do
      CANDS+=("$d/$SHOW")
    done < <(find "$HOME" /Users/Shared -maxdepth 7 "${PRUNE[@]}" -type d -iname "LightShows" -print 2>/dev/null)
  fi

  PICK=""
  n_named=0
  for c in "${CANDS[@]}"; do [ "$(basename "$c")" = "$SHOW" ] && { n_named=$((n_named+1)); PICK="$c"; }; done
  [ $n_named -eq 1 ] || PICK=""

  if [ -n "$PICK" ]; then
    echo
    echo "  Found the Mac show:  $PICK"
    read -r -p "  Is this the show ShowXpress uses on this Mac? (y/n) " yn
    case "$yn" in [yY]*) ;; *) PICK="";; esac
  fi
  if [ -z "$PICK" ] && [ ${#CANDS[@]} -gt 0 ]; then
    echo
    echo "  Which folder is the Awaaz show ShowXpress uses on this Mac?"
    i=1; for c in "${CANDS[@]}"; do echo "    $i  $c"; i=$((i+1)); done
    echo "    0  none of these"
    read -r -p "  number: " n
    if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#CANDS[@]} ]; then PICK="${CANDS[$((n-1))]}"; fi
  fi
  if [ -z "$PICK" ]; then
    echo
    echo "  In Finder, find the Awaaz show folder ShowXpress uses on this Mac"
    echo "  (the folder that has 'Live', 'scenes', 'Editor' inside it)."
    echo "  Drag that folder into this window, then press Enter.  (Just Enter = cancel)"
    read -r -p "  > " typed
    PICK="$(clean_path "$typed")"
    [ -n "$PICK" ] || fail "Cancelled."
  fi
  valid_dest "$PICK" || fail "'$PICK' doesn't look like a ShowXpress show folder."
  DEST="$PICK"
fi
echo "  to:   $DEST"

# 4. keep the Mac show as it was, outside the show folder (one rolling copy)
if [ -d "$DEST" ]; then
  echo "  saving current Mac show to: $PREV"
  mkdir -p "$PREV"
  # run twice: the Mac disk ignores upper/lower case, so a file renamed only in case (Blush -> BLUSH)
  # can be removed by the first pass and is put back by the second
  rsync -rt --delete "$DEST/" "$PREV/" && rsync -rt --delete "$DEST/" "$PREV/" || fail "Couldn't save a copy of the current Mac show."
fi

# 5. mirror Windows -> Mac (files removed on Windows are removed on the Mac too)
mkdir -p "$DEST" || fail "Can't create $DEST"
EXC=(--exclude '._*' --exclude '.DS_Store' --exclude 'Thumbs.db' --exclude 'desktop.ini')
rsync -rt --delete "${EXC[@]}" "$SRC/" "$DEST/"
rc=$?
[ $rc -eq 0 ] && { rsync -rt --delete "${EXC[@]}" "$SRC/" "$DEST/"; rc=$?; }   # second pass: see above
chmod -R u+rwX "$DEST" 2>/dev/null   # the Windows drive is read-only on the Mac - make the copy writable
# every Windows file must now exist on the Mac with exactly the same name (upper/lower case included)
list() { (cd "$1" && find . -type f ! -name '._*' ! -name '.DS_Store' ! -name 'Thumbs.db' ! -name 'desktop.ini' | LC_ALL=C sort); }
MISSING="$(LC_ALL=C comm -23 <(list "$SRC") <(list "$DEST"))"
if [ -n "$MISSING" ]; then
  echo
  echo "  WARNING: these Windows files didn't arrive on the Mac with the right name:"
  echo "$MISSING" | sed 's/^\.\//    /'
  rc=99
fi
if [ $rc -ne 0 ]; then
  echo
  echo "  WARNING: the copy finished with errors (rsync code $rc)."
  echo "  The Mac show as it was before is in: $PREV"
  echo
  exit 1
fi
[ $FIRST -eq 1 ] && printf '%s\n' "$DEST" > "$PATHFILE"

nsrc=$(find "$SRC" -type f ! -name '._*' ! -name '.DS_Store' ! -name 'Thumbs.db' ! -name 'desktop.ini' | wc -l | tr -d ' ')
ndst=$(find "$DEST" -type f ! -name '._*' ! -name '.DS_Store' | wc -l | tr -d ' ')
echo
echo "  DONE - Mac show now matches Windows ($ndst files; Windows has $nsrc)."
echo "  Open ShowXpress on the Mac."

echo
exit 0
