#!/bin/bash
# Builds the runtime and the Linux engine's runtime, then packages them the way a release publishes them:
# build/release/voile-<version>.tar.xz, with the Linux engine's runtime in its linux folder, and its SHA-256.
set -euo pipefail
RUNTIME="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$RUNTIME/build"
VERSION="${1:-}"
NAME="voile-$VERSION"
PACKAGE="$WORK/package/$NAME"
RELEASE="$WORK/release"
ARCHIVE="$RELEASE/$NAME.tar.xz"
STRIP="$WORK/toolchain/llvm-mingw/bin/llvm-strip"
JOBS="$(sysctl -n hw.ncpu)"
WINE_ENVIRONMENT=(WINEDEBUG=-all "WINEDLLOVERRIDES=mscoree,mshtml=;winemenubuilder.exe=d")

fail() {
    echo "$*" >&2
    exit 1
}

field() {
    plutil -extract "$1.$2" raw -o - "$RUNTIME/sources.json"
}

download() {
    echo "$WORK/downloads/$(basename "$(field "$1" url)")"
}

[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]] ||
    fail "Usage: package.sh v<CrossOver version>-<revision>, such as v26.3.0-1"
CROSSOVER="$(basename "$(field crossover url)" .tar.gz)"
CROSSOVER="${CROSSOVER#crossover-sources-}"
[[ "$VERSION" == "v$CROSSOVER-"* ]] || fail "$VERSION does not match CrossOver $CROSSOVER in sources.json"
# runtime.json names commits, so the archive must hold exactly what they contain.
for repository in "$RUNTIME" "$RUNTIME/wine"; do
    [[ -z "$(git -C "$repository" status --porcelain)" ]] || fail "$repository has uncommitted changes"
done

"$RUNTIME/scripts/build.sh"
"$RUNTIME/scripts/build-linux.sh"

# The build keeps its debug information for development. Without it, the
# runtime shrinks from about 1 GB to 400 MB. Mach-O files lose their debug map,
# which points into this build tree, and are signed again.
strip_debug() {
    local binary
    find "$PACKAGE/lib/wine" -path '*-windows/*' -type f -print0 |
        xargs -0 -n 64 -P "$JOBS" "$STRIP" --strip-debug
    for binary in "$PACKAGE"/bin/* "$PACKAGE"/lib/wine/x86_64-unix/*; do
        codesign --remove-signature "$binary"
        strip -S "$binary"
        codesign --sign - "$binary"
    done
}

# Apple's license forbids modifying D3DMetal, so it goes in after stripping:
# its unix libraries link to libd3dshared.dylib, which strip would follow.
add_d3dmetal() {
    ditto "$WORK/d3dmetal/lib" "$PACKAGE/lib"
}

# The Linux engine's runtime: the engine, the render server and DXMT, Neptune's
# DLLs for the prefix, voile-wine built for Linux and the Debian root. Wine's ELF
# and PE files lose their debug information, which points into this build tree.
add_linux() {
    local linux="$PACKAGE/linux"
    cp -cR "$WORK/linux/stage" "$linux"
    rm -rf "$linux/wine/share/man"
    find "$linux/wine/lib/wine" -type f \( -path '*-windows/*' -o -path '*-unix/*' \) -print0 |
        xargs -0 -n 64 -P "$JOBS" "$STRIP" --strip-debug
}

# The licenses of everything the archive ships. Valve's steamclient libraries
# come with none.
copy_licenses() {
    local licenses="$PACKAGE/licenses"
    mkdir -p "$licenses/d3dmetal"
    cp "$WORK/d3dmetal/License.rtf" "$WORK/d3dmetal/Acknowledgements.rtf" "$licenses/d3dmetal/"
    cp "$RUNTIME/wine/COPYING.LIB" "$licenses/wine.txt"
    cp "$WORK/src/freetype/docs/FTL.TXT" "$licenses/freetype.txt"
    cp "$WORK/src/gnutls/gnutls/doc/COPYING.LESSER" "$licenses/gnutls.txt"
    cp "$WORK/src/gnutls/gmp/COPYING.LESSERv3" "$licenses/gmp.txt"
    cp "$WORK/obj/nettle/COPYING.LESSERv3" "$licenses/nettle.txt"
    cp "$WORK/src-proton/lsteamclient/LICENSE" "$licenses/lsteamclient.txt"
    cp "$(download wine-mono-license)" "$licenses/wine-mono.txt"
    tar -xzOf "$(download proton)" '*/LICENSE.proton' > "$licenses/steam_helper.txt"
    mkdir -p "$licenses/linux"
    cp "$WORK"/linux/lkd/licenses/* "$WORK"/linux/neptune/licenses/* "$WORK"/linux/dxmt/licenses/* \
        "$licenses/linux/"
    cp "$WORK/linux/dxmt/SOURCE" "$licenses/linux/dxmt-source.txt"
    # The Debian root: every package with its version and URL, which also locate its source package.
    cp "$WORK"/linux/debian-root/lock*.json "$licenses/linux/"
}

write_manifest() {
    local proton
    proton="$(basename "$(field proton url)" .tar.gz)"
    cat > "$PACKAGE/runtime.json" <<EOF
{
  "version": "$VERSION",
  "voile": "$(git -C "$RUNTIME" rev-parse HEAD)",
  "crossover": "$CROSSOVER",
  "voile-wine": "$(git -C "$RUNTIME/wine" rev-parse HEAD)",
  "proton": "$proton",
  "wine-mono": "$(basename "$(field wine-mono url)" -x86.tar.xz | sed 's/^wine-mono-//')",
  "d3dmetal": "$(cat "$WORK/d3dmetal/VERSION")",
  "linux": {
    "voile-lkd": "$(plutil -extract voile-lkd raw -o - "$WORK/linux/lkd/VERSION.json")",
    "fex": "$(plutil -extract fex raw -o - "$WORK/linux/lkd/VERSION.json")",
    "neptune": "$(plutil -extract neptune raw -o - "$WORK/linux/neptune/VERSION.json")",
    "dxmt": "$(basename "$(field dxmt url)" .tar.xz)",
    "debian-root": "$(basename "$(field debian-root url)" .tar.xz)"
  }
}
EOF
}

# Extracted anywhere, the archive must create a prefix and run Windows programs
# of both architectures, and run one through the Linux engine.
verify() {
    local root="$WORK/verify" output program
    rm -rf "$root"
    mkdir -p "$root"
    tar -xJf "$ARCHIVE" -C "$root"
    local wine="$root/$NAME/bin/wine" prefix="WINEPREFIX=$root/prefix"
    env "$prefix" "${WINE_ENVIRONMENT[@]}" "$wine" wineboot --init
    for program in cmd 'C:\windows\syswow64\cmd.exe'; do
        output="$(env "$prefix" "${WINE_ENVIRONMENT[@]}" "$wine" "$program" /c ver)"
        [[ "$output" == *Windows* ]] || fail "$program did not run from the archive: $output"
    done
    env "$prefix" "$root/$NAME/bin/wineserver" -w
    local linux="$root/$NAME/linux"
    mkdir -p "$root/home"
    output="$(FEXDARWIN_LKD=1 FEXDARWIN_ROOT="$linux/root" FEXDARWIN_ROOT_RO=1 \
        FEXDARWIN_BIND="/opt/wine=$linux/wine:ro;/home/user=$root/home" \
        "$linux/engine/run-with-timeout.sh" 600 "$linux/engine/fexdarwin-run" \
        --env HOME=/home/user --env USER=user --env PATH=/opt/wine/bin:/usr/bin:/bin \
        --env WINEPREFIX=/home/user/prefix --env WINEDEBUG=-all \
        --env 'WINEDLLOVERRIDES=mscoree,mshtml=;winemenubuilder.exe=d' \
        /bin/sh -c '/opt/wine/bin/wine cmd /c ver; /opt/wine/bin/wineserver -w' 2>/dev/null)" || true
    [[ "$output" == *Windows* ]] || fail "cmd did not run through the Linux engine from the archive: $output"
    rm -rf "$root"
}

echo "==> $NAME"
rm -rf "$WORK/package" "$RELEASE"
mkdir -p "$WORK/package" "$RELEASE"
cp -cR "$WORK/stage" "$PACKAGE"
rm -rf "$PACKAGE/share/man"
mkdir "$PACKAGE/steam"
cp "$WORK/steam-windows/steamclient.dll" "$WORK/steam-windows/steamclient64.dll" "$PACKAGE/steam/"
strip_debug
add_d3dmetal
add_linux
copy_licenses
write_manifest
COPYFILE_DISABLE=1 tar --create --xz --options xz:compression-level=9,xz:threads=0 \
    --no-mac-metadata --no-xattrs --uid 0 --gid 0 --numeric-owner \
    --file "$ARCHIVE" -C "$WORK/package" "$NAME"
(cd "$RELEASE" && shasum -a 256 "$NAME.tar.xz" > "$NAME.tar.xz.sha256")
echo "==> Checking the archive"
verify
echo "Runtime archive: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
