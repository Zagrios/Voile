#!/bin/bash
# Packs D3DMetal, unmodified and with Apple's notices, from a Game Porting
# Toolkit disk image into the archive the runtime pins in sources.json. The
# archive lands in build/downloads, where the build finds it once sources.json
# names its checksum.
set -euo pipefail
WORK="$(cd "$(dirname "$0")/.." && pwd)/build"
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

# "Evaluation environment for Windows games 4.0 beta 2" becomes d3dmetal-4.0-beta2.
VERSION="$(basename "$EVALUATION" .dmg)"
NAME="d3dmetal-$(sed -E 's/.* games //; s/ beta /-beta/; s/ /-/g' <<< "$VERSION")"
STAGING="$WORK/d3dmetal-import"
rm -rf "$STAGING"
mkdir -p "$STAGING/$NAME" "$WORK/downloads"
# redist/ holds the Redistributables, which Apple's license lets anyone
# distribute on their own, for non-commercial purposes.
ditto "$INNER/redist/lib" "$STAGING/$NAME/lib"
cp "$INNER/License.rtf" "$INNER/Acknowledgements.rtf" "$STAGING/$NAME/"
echo "$VERSION" > "$STAGING/$NAME/VERSION"
ARCHIVE="$WORK/downloads/$NAME.tar.xz"
COPYFILE_DISABLE=1 tar --create --xz --options xz:compression-level=9,xz:threads=0 \
    --no-mac-metadata --no-xattrs --uid 0 --gid 0 --numeric-owner \
    --file "$ARCHIVE" -C "$STAGING" "$NAME"
rm -rf "$STAGING"
cat <<EOF
D3DMetal: $VERSION
Archive: $ARCHIVE
SHA-256: $(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)

Publish it, then point sources.json's "d3dmetal" at it with this checksum:
  gh release create $NAME "$ARCHIVE" --title "$VERSION" \\
    --notes "D3DMetal from Apple's Game Porting Toolkit, unmodified."
  https://github.com/Zagrios/forge-runtime/releases/download/$NAME/$NAME.tar.xz
EOF
