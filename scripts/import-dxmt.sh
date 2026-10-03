#!/bin/bash
# Packs a built DXMT (dxmt-native.framework), unmodified, with its license and the source it was built from, into
# the archive sources.json pins as "dxmt". v1 uses UTM 5.0.5's build (utmapp/dxmt bcdcf6da): its Developer ID
# signature covers Info.plist, so the framework is copied whole with ditto and never edited.
set -euo pipefail
WORK="$(cd "$(dirname "$0")/.." && pwd)/build"
FRAMEWORK="${1:?Usage: $0 <dxmt-native.framework> <DXMT LICENSE> <source, e.g. utmapp/dxmt@bcdcf6da>}"
LICENSE="${2:?the LICENSE file of the DXMT sources}"
SOURCE="${3:?the repository and commit the framework was built from}"
NAME="dxmt-${SOURCE##*@}"
NAME="${NAME:0:17}"
STAGING="$WORK/dxmt-import"
rm -rf "$STAGING"
mkdir -p "$STAGING/$NAME/licenses" "$WORK/downloads"
ditto "$FRAMEWORK" "$STAGING/$NAME/dxmt-native.framework"
codesign --verify --deep "$STAGING/$NAME/dxmt-native.framework"
cp "$LICENSE" "$STAGING/$NAME/licenses/dxmt.txt"
printf 'DXMT built from %s (https://github.com/%s/tree/%s).\n' "$SOURCE" "${SOURCE%@*}" "${SOURCE##*@}" \
    > "$STAGING/$NAME/SOURCE"
ARCHIVE="$WORK/downloads/$NAME.tar.xz"
COPYFILE_DISABLE=1 tar --create --xz --options xz:compression-level=9,xz:threads=0 \
    --no-mac-metadata --no-xattrs --uid 0 --gid 0 --numeric-owner \
    --file "$ARCHIVE" -C "$STAGING" "$NAME"
rm -rf "$STAGING"
cat <<OUT
DXMT: $SOURCE
Archive: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))
SHA-256: $(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)

Publish it, then point sources.json's "dxmt" at it with this checksum:
  gh release create $NAME "$ARCHIVE" --title "DXMT ${SOURCE##*@}" --notes "DXMT from $SOURCE, unmodified."
  https://github.com/Zagrios/voile/releases/download/$NAME/$NAME.tar.xz
OUT
