#!/bin/bash
# Foldlet installer — builds Foldlet from source on your Mac and pins your first group to the Dock.
#
#   curl -fsSL https://raw.githubusercontent.com/wmtaff/foldlet/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/wmtaff/foldlet/main/install.sh | bash -s -- "Games"  # custom first group name
#   ./install.sh [FirstGroupName]                                                                   # from a clone
#
# Running it again rebuilds and updates every existing group in place.
set -euo pipefail

REPO="wmtaff/foldlet"
BRANCH="main"
FIRST_GROUP="${1:-Work}"
GROUPS_DIR="$HOME/Applications/Foldlet"
EXE="Foldlet"

say() { printf '\033[1m→ %s\033[0m\n' "$*"; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "Foldlet only runs on macOS."

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Foldlet is compiled on your Mac and needs Apple's free Command Line Tools."
  echo "A window should open to install them. When it's done, run this installer again."
  xcode-select --install 2>/dev/null || true
  exit 1
fi

case "$FIRST_GROUP" in
  *[\<\>\&/:]*|"") die "Group names can't contain < > & / or :" ;;
esac

# Find the source next to this script, or download it.
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/Sources/main.swift" ]; then
  SRC="$SCRIPT_DIR/Sources/main.swift"
else
  say "Downloading Foldlet…"
  curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" | tar -xz -C "$WORK"
  SRC="$(find "$WORK" -path '*/Sources/main.swift' | head -n 1)"
  [ -n "$SRC" ] && [ -f "$SRC" ] || die "Couldn't download the source."
fi

say "Compiling (takes ~20 seconds)…"
xcrun swiftc -O -o "$WORK/$EXE" "$SRC" -framework AppKit -framework UniformTypeIdentifiers

mkdir -p "$GROUPS_DIR"

sign_bundle() {
  local app="$1"
  rm -f "$app/Icon"$'\r'          # custom icon file; codesign refuses it. The app redraws it on launch.
  xattr -cr "$app"
  codesign --force --sign - "$app" >/dev/null
}

existing=()
shopt -s nullglob
for app in "$GROUPS_DIR"/*.app; do
  if /usr/libexec/PlistBuddy -c "Print :FoldletGroup" "$app/Contents/Info.plist" >/dev/null 2>&1; then
    existing+=("$app")
  fi
done

if [ ${#existing[@]} -gt 0 ]; then
  say "Updating ${#existing[@]} group(s)…"
  killall "$EXE" 2>/dev/null || true
  sleep 0.5
  for app in "${existing[@]}"; do
    cp "$WORK/$EXE" "$app/Contents/MacOS/$EXE"
    sign_bundle "$app"
    open -g "$app" --args --no-panel     # relaunch quietly so the Dock icon is redrawn
    echo "   updated $(basename "$app" .app)"
  done
else
  app="$GROUPS_DIR/$FIRST_GROUP.app"
  bid="io.github.wmtaff.foldlet.group.$(uuidgen | cut -c1-8 | tr '[:upper:]' '[:lower:]')"
  say "Creating your first group: $FIRST_GROUP"
  mkdir -p "$app/Contents/MacOS"
  cp "$WORK/$EXE" "$app/Contents/MacOS/$EXE"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleIdentifier</key><string>$bid</string>
  <key>CFBundleName</key><string>$FIRST_GROUP</string>
  <key>CFBundleDisplayName</key><string>$FIRST_GROUP</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>FoldletGroup</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Application</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>com.apple.application-bundle</string>
        <string>com.apple.application</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST
  sign_bundle "$app"
  say "Pinning it to your Dock…"
  defaults write com.apple.dock persistent-apps -array-add \
    "<dict><key>tile-type</key><string>file-tile</string><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>$app</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>"
  killall Dock
  sleep 1.5
  open "$app"
fi

printf '\n\033[32m✓ Foldlet is installed.\033[0m Click the group in your Dock, then drop apps onto it.\n'
echo "  Right-click a group in the Dock for New Group…, Rename Group… and Delete Group…"
