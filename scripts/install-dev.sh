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

# The Linux engine runtime, when build-linux.sh built it, goes in its linux
# folder, where SailOver looks for it as it does in a release's.
if [[ -x "$WORK/linux/stage/wine/bin/wine" && -x "$WORK/linux/stage/engine/fexdarwin-run" ]]; then
    cp -cR "$WORK/linux/stage" "$DESTINATION/linux"
    echo "Linux engine runtime installed in $DESTINATION/linux"
fi
