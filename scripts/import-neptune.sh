#!/bin/bash
# Builds Neptune (private) and packs it into the archive sources.json pins as "neptune": the guest driver
# (d3d11.dll, dxgi.dll, d3d12.dll for the prefix) and the macOS render server with its libraries, relinked to find
# each other through @rpath. The render server needs RENDER_SERVER_EXEC_PATH=<archive>/graphics/libexec/
# virgl_render_server at run time. Needs build.sh's llvm-mingw (or LLVM_MINGW), meson and ninja.
set -euo pipefail
RUNTIME="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$RUNTIME/build"
NEPTUNE="$(cd "${1:?Usage: $0 <neptune checkout>}" && pwd)"
[[ -z "$(git -C "$NEPTUNE" status --porcelain)" ]] || { echo "$NEPTUNE has uncommitted changes" >&2; exit 1; }
COMMIT="$(git -C "$NEPTUNE" rev-parse HEAD)"
NAME="neptune-${COMMIT:0:12}"
export LLVM_MINGW="${LLVM_MINGW:-$WORK/toolchain/llvm-mingw}"
"$NEPTUNE/scripts/build-client.sh"
"$NEPTUNE/scripts/build-server.sh"
STAGING="$WORK/neptune-import"
OUT="$STAGING/$NAME"
rm -rf "$STAGING"
mkdir -p "$OUT/windows" "$OUT/graphics/bin" "$OUT/graphics/libexec" "$OUT/graphics/lib" "$OUT/licenses" \
    "$WORK/downloads"
cp "$NEPTUNE"/build/client/src/virtio/neptune/{d3d11,dxgi,d3d12}.dll "$OUT/windows/"
"$LLVM_MINGW/bin/llvm-strip" --strip-debug "$OUT"/windows/*.dll
PREFIX="$NEPTUNE/build/prefix"
cp "$PREFIX/bin/virgl_test_server" "$OUT/graphics/bin/"
cp "$PREFIX/libexec/virgl_render_server" "$OUT/graphics/libexec/"
cp "$PREFIX/lib/libvirglrenderer.1.dylib" "$PREFIX/lib/libepoxy.0.dylib" "$OUT/graphics/lib/"
# The build links by absolute path into its prefix: relink through @rpath.
install_name_tool -id @rpath/libepoxy.0.dylib "$OUT/graphics/lib/libepoxy.0.dylib"
install_name_tool -id @rpath/libvirglrenderer.1.dylib \
    -change "$PREFIX/lib/libepoxy.0.dylib" @rpath/libepoxy.0.dylib \
    -add_rpath @loader_path "$OUT/graphics/lib/libvirglrenderer.1.dylib"
install_name_tool -change "$PREFIX/lib/libvirglrenderer.1.dylib" @rpath/libvirglrenderer.1.dylib \
    -add_rpath @executable_path/../lib "$OUT/graphics/bin/virgl_test_server"
for binary in "$OUT"/graphics/bin/* "$OUT"/graphics/libexec/* "$OUT"/graphics/lib/*; do
    codesign --remove-signature "$binary" 2>/dev/null || true
    strip -S "$binary"
    codesign --sign - "$binary"
done
otool -L "$OUT"/graphics/bin/* "$OUT"/graphics/lib/* | grep -q "$NEPTUNE" &&
    { echo "a library still points into the build tree" >&2; exit 1; }
cp "$NEPTUNE/mesa/docs/license.rst" "$OUT/licenses/mesa.rst"
cp "$NEPTUNE/virglrenderer/COPYING" "$OUT/licenses/virglrenderer.txt"
cp "$NEPTUNE"/build/dl/libepoxy-1.5.10/COPYING "$OUT/licenses/libepoxy.txt"
printf '{\n  "neptune": "%s"\n}\n' "$COMMIT" > "$OUT/VERSION.json"
ARCHIVE="$WORK/downloads/$NAME.tar.xz"
COPYFILE_DISABLE=1 tar --create --xz --options xz:compression-level=9,xz:threads=0 \
    --no-mac-metadata --no-xattrs --uid 0 --gid 0 --numeric-owner \
    --file "$ARCHIVE" -C "$STAGING" "$NAME"
rm -rf "$STAGING"
cat <<MSG
Neptune: $COMMIT
Archive: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))
SHA-256: $(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)

Publish it, then point sources.json's "neptune" at it with this checksum:
  gh release create $NAME "$ARCHIVE" --title "Neptune ${COMMIT:0:12}" --notes "Neptune guest driver and render server."
  https://github.com/Zagrios/voile/releases/download/$NAME/$NAME.tar.xz
MSG
