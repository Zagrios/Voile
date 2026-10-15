#!/bin/bash
# Runs the locally built Wine runtime against a development prefix.
# OBELISK_GRAPHICS=d3dmetal uses the D3DMetal the build extracted.
set -euo pipefail
WORK="$(cd "$(dirname "$0")/.." && pwd)/build"
STAGE="$WORK/stage"
if [[ ! -x "$STAGE/bin/wine" ]]; then
    echo "Build the runtime first: ./scripts/build.sh" >&2
    exit 1
fi
export WINEPREFIX="${WINEPREFIX:-$WORK/prefix}"

case "${OBELISK_GRAPHICS:-wined3d}" in
    wined3d) ;;
    d3dmetal)
        D3DMETAL="$WORK/d3dmetal"
        OVERLAY="$WORK/stage-d3dmetal"
        [[ -f "$D3DMETAL/VERSION" ]] || { echo "Build the runtime first: ./scripts/build.sh" >&2; exit 1; }
        # Wine searches its own lib/wine before WINEDLLPATH, so D3DMetal's
        # DLLs replace Wine's in an APFS clone of the runtime.
        if [[ ! -f "$OVERLAY/.ready" || "$WORK/stamps" -nt "$OVERLAY/.ready" \
            || "$D3DMETAL/VERSION" -nt "$OVERLAY/.ready" ]]; then
            rm -rf "$OVERLAY"
            cp -cR "$STAGE" "$OVERLAY"
            ditto "$D3DMETAL/lib" "$OVERLAY/lib"
            touch "$OVERLAY/.ready"
        fi
        STAGE="$OVERLAY"
        # CrossOver's Wine preloads libd3dshared so D3DMetal's unix libraries
        # resolve it, and reports the hardware scheduling D3D12 expects.
        export CX_APPLEGPTK_LIBD3DSHARED_PATH="$OVERLAY/lib/external/libd3dshared.dylib"
        export CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal
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
