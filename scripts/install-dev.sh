#!/bin/bash
# Installs the locally built runtime where a development build of SailOver looks
# for it, with the D3DMetal the build extracted.
# Released builds of SailOver will download their runtime instead.
set -euo pipefail
WORK="$(cd "$(dirname "$0")/.." && pwd)/build"
LIBRARY="${SAILOVER_LIBRARY_DIRECTORY:-$HOME/Library/Application Support/com.zagrios.sailover}"
DESTINATION="$LIBRARY/Voile/current"

if [[ ! -x "$WORK/stage/bin/wine" || ! -f "$WORK/steam-windows/steamclient64.dll" ]]; then
    echo "Build the runtime first: ./scripts/build.sh" >&2
    exit 1
fi
rm -rf "$DESTINATION"
mkdir -p "$(dirname "$DESTINATION")"
cp -cR "$WORK/stage" "$DESTINATION"
if [[ -f "$WORK/d3dmetal/VERSION" ]]; then
    ditto "$WORK/d3dmetal/lib" "$DESTINATION/lib"
fi
mkdir -p "$DESTINATION/steam"
cp "$WORK/steam-windows/steamclient.dll" "$WORK/steam-windows/steamclient64.dll" "$DESTINATION/steam/"
echo "Wine runtime installed in $DESTINATION"
