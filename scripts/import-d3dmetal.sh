#!/bin/bash
# Copies D3DMetal, unmodified and with Apple's notices, from a Game Porting
# Toolkit disk image into build/d3dmetal for local testing.
set -euo pipefail
DESTINATION="$(cd "$(dirname "$0")/.." && pwd)/build/d3dmetal"
TOOLKIT="${1:?Usage: $0 <Game_Porting_Toolkit.dmg>}"

attach() {
    hdiutil attach -nobrowse -readonly -plist "$1" |
        plutil -extract system-entities xml1 -o - - |
        grep -A1 '<key>mount-point</key>' | grep -o '/Volumes/[^<]*'
}

OUTER="$(attach "$TOOLKIT")"
trap 'hdiutil detach -quiet "$OUTER"' EXIT
EVALUATION="$(find "$OUTER" -maxdepth 1 -name 'Evaluation environment*.dmg' | head -1)"
[[ -n "$EVALUATION" ]] || { echo "No evaluation environment in $TOOLKIT" >&2; exit 1; }
INNER="$(attach "$EVALUATION")"
trap 'hdiutil detach -quiet "$INNER"; hdiutil detach -quiet "$OUTER"' EXIT

rm -rf "$DESTINATION"
mkdir -p "$DESTINATION"
ditto "$INNER/redist/lib" "$DESTINATION/lib"
cp "$INNER/License.rtf" "$INNER/Acknowledgements.rtf" "$DESTINATION/"
basename "$EVALUATION" .dmg > "$DESTINATION/VERSION"
echo "D3DMetal: $(cat "$DESTINATION/VERSION") in $DESTINATION"
