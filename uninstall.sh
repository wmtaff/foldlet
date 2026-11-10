#!/bin/bash
# Removes every Foldlet group from your Dock and moves Foldlet's files to the Trash.
# Your apps themselves are never touched.
#
#   curl -fsSL https://raw.githubusercontent.com/wmtaff/foldlet/main/uninstall.sh | bash
set -euo pipefail

GROUPS_DIR="$HOME/Applications/Foldlet"
DATA_DIR="$HOME/Library/Application Support/Foldlet"
STAMP="$(date +%Y%m%d-%H%M%S)"

shopt -s nullglob
apps=("$GROUPS_DIR"/*.app)

if [ ${#apps[@]} -gt 0 ]; then
  echo "→ Removing Foldlet groups from the Dock…"
  "${apps[0]}/Contents/MacOS/Foldlet" --remove-all-from-dock || true
fi
killall Foldlet 2>/dev/null || true

for d in "$GROUPS_DIR" "$DATA_DIR"; do
  if [ -e "$d" ]; then
    mv "$d" "$HOME/.Trash/$(basename "$d")-$STAMP"
    echo "→ Moved $d to the Trash"
  fi
done

echo "✓ Foldlet is uninstalled."
