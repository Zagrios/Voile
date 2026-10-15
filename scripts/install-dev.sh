#!/bin/bash
# Installs the locally built runtime where a development build of Obelisk looks
# for it, with the D3DMetal the build extracted, laid as package.sh lays it.
# Released builds of Obelisk will download their runtime instead.
set -euo pipefail
WORK="$(cd "$(dirname "$0")/.." && pwd)/build"
LIBRARY="${OBELISK_LIBRARY_DIRECTORY:-$HOME/Library/Application Support/com.zagrios.obelisk}"
DESTINATION="$LIBRARY/Voile/current"

if [[ ! -x "$WORK/stage/bin/wine" || ! -f "$WORK/steam-windows/steamclient64.dll" ]]; then
    echo "Build the runtime first: ./scripts/build.sh" >&2
    exit 1
fi
rm -rf "$DESTINATION"
mkdir -p "$(dirname "$DESTINATION")"
cp -cR "$WORK/stage" "$DESTINATION"
if [[ -f "$WORK/d3dmetal/VERSION" ]]; then
    ditto "$WORK/d3dmetal/lib/external" "$DESTINATION/lib/external"
    ditto "$WORK/d3dmetal/lib/wine" "$DESTINATION/lib/d3dmetal"
fi
mkdir -p "$DESTINATION/steam"
cp "$WORK/steam-windows/steamclient.dll" "$WORK/steam-windows/steamclient64.dll" "$DESTINATION/steam/"
echo "Wine runtime installed in $DESTINATION"

# The Linux engine runtime, when build-linux.sh built it, goes in its linux
# folder, where Obelisk looks for it as it does in a release's.
if [[ -x "$WORK/linux/stage/wine/bin/wine" && -x "$WORK/linux/stage/engine/fexdarwin-run" ]]; then
    cp -cR "$WORK/linux/stage" "$DESTINATION/linux"
    echo "Linux engine runtime installed in $DESTINATION/linux"
fi
