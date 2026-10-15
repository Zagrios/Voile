#!/bin/bash
# Runs the locally built Wine runtime against a development prefix.
# OBELISK_GRAPHICS picks what renders Direct3D 10 to 12, as Obelisk does:
# wined3d (Wine's own, the default here), d3dmetal (the D3DMetal the build
# extracted, with DXMT for 32-bit programs, Obelisk's default) or dxmt.
set -euo pipefail
WORK="$(cd "$(dirname "$0")/.." && pwd)/build"
STAGE="$WORK/stage"
D3DMETAL="$WORK/d3dmetal/lib"
if [[ ! -x "$STAGE/bin/wine" ]]; then
    echo "Build the runtime first: ./scripts/build.sh" >&2
    exit 1
fi
export WINEPREFIX="${WINEPREFIX:-$WORK/prefix}"

# Wine searches the folders of WINEDLLPATH_PREPEND before its own lib/wine, so
# the backend's DLLs replace Wine's d3d11 and dxgi.
case "${OBELISK_GRAPHICS:-wined3d}" in
    wined3d) ;;
    d3dmetal)
        [[ -f "$WORK/d3dmetal/VERSION" ]] || { echo "Build the runtime first: ./scripts/build.sh" >&2; exit 1; }
        export WINEDLLPATH_PREPEND="$D3DMETAL/wine:$STAGE/lib/dxmt"
        # CrossOver's Wine preloads libd3dshared so D3DMetal's unix libraries
        # resolve it, and reports the hardware scheduling D3D12 expects.
        export CX_APPLEGPTK_LIBD3DSHARED_PATH="$D3DMETAL/external/libd3dshared.dylib"
        export CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal
        # Outside Apple's own layout, D3DMetal's unix libraries do not find the
        # framework by themselves: Obelisk names it.
        export D3DMETAL_FRAMEWORK_PATH="$D3DMETAL/external/D3DMetal.framework/D3DMetal"
        ;;
    dxmt)
        export WINEDLLPATH_PREPEND="$STAGE/lib/dxmt"
        export CX_ACTIVE_GRAPHICS_BACKEND=dxmt
        ;;
    *)
        echo "Unknown OBELISK_GRAPHICS: $OBELISK_GRAPHICS" >&2
        exit 1
        ;;
esac
# As Obelisk does: only the runtime's GStreamer plugins, with their registry in
# the prefix.
export GST_PLUGIN_SYSTEM_PATH="$STAGE/lib/gstreamer-1.0"
export GST_REGISTRY="$WINEPREFIX/obelisk-gstreamer-registry.bin"
exec "$STAGE/bin/wine" "$@"
