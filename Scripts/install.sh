#!/usr/bin/env bash
# Move Wizard into /Applications and launch it from there.
#
# Worth doing once you are past development: the TCC grants for Accessibility
# and Input Monitoring are keyed to the code signature, which is stable across
# rebuilds — but the build directory is not. Anything that deletes `build/`
# leaves the grants pointing at a path that no longer exists, and macOS shows a
# stale entry you have to remove by hand before it will take a new one.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-Release}"
CONFIG="$CONFIG" ./Scripts/build-app.sh >/tmp/wizard-install.log 2>&1 || {
  echo "build failed — see /tmp/wizard-install.log" >&2; exit 1; }

SRC="build/Build/Products/$CONFIG/Wizard.app"
DEST="/Applications/Wizard.app"

if pgrep -x Wizard >/dev/null; then
  echo "quitting the running copy"
  osascript -e 'tell application "Wizard" to quit' 2>/dev/null || pkill -x Wizard || true
  sleep 1
fi

rm -rf "$DEST"
cp -R "$SRC" "$DEST"
echo "installed: $DEST"
codesign -dv "$DEST" 2>&1 | grep -E "Identifier|TeamIdentifier" | sed 's/^/  /'

echo
echo "The copy in /Applications is a different path to the one you may already have"
echo "granted, so macOS will ask for Accessibility and Input Monitoring once more."
open "$DEST"
