#!/bin/bash
# Builds the Linux engine runtime, then packages it the way a release publishes it:
# build/release/voile-linux-<version>.tar.xz and its SHA-256. Same version scheme as package.sh.
set -euo pipefail
RUNTIME="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$RUNTIME/build"
VERSION="${1:-}"
NAME="voile-linux-$VERSION"
PACKAGE="$WORK/package-linux/$NAME"
RELEASE="$WORK/release"
ARCHIVE="$RELEASE/$NAME.tar.xz"
STAGE="$WORK/linux/stage"
STRIP="$WORK/toolchain/llvm-mingw/bin/llvm-strip"
JOBS=4

fail() {
    echo "$*" >&2
    exit 1
}

field() {
    plutil -extract "$1.$2" raw -o - "$RUNTIME/sources.json"
}

[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]] ||
    fail "Usage: package-linux.sh v<CrossOver version>-<revision>, such as v26.3.0-1"
for repository in "$RUNTIME" "$RUNTIME/wine"; do
    [[ -z "$(git -C "$repository" status --porcelain)" ]] || fail "$repository has uncommitted changes"
done

"$RUNTIME/scripts/build-linux.sh"

# Wine's ELF and PE files lose their debug information (it points into this build tree).
strip_debug() {
    find "$PACKAGE/wine/lib/wine" -type f \( -path '*-windows/*' -o -path '*-unix/*' \) -print0 |
        xargs -0 -n 64 -P "$JOBS" "$STRIP" --strip-debug
}

copy_licenses() {
    local licenses="$PACKAGE/licenses"
    mkdir -p "$licenses"
    cp "$RUNTIME/wine/COPYING.LIB" "$licenses/wine.txt"
    cp "$WORK"/linux/lkd/licenses/* "$WORK"/linux/neptune/licenses/* "$WORK"/linux/dxmt/licenses/* "$licenses/"
    cp "$WORK/linux/dxmt/SOURCE" "$licenses/dxmt-source.txt"
    # The Debian root: every package with its version and URL, which also locate its source package.
    cp "$WORK"/linux/debian-root/lock*.json "$licenses/"
}

write_manifest() {
    cat > "$PACKAGE/runtime.json" <<JSON
{
  "version": "$VERSION",
  "voile": "$(git -C "$RUNTIME" rev-parse HEAD)",
  "voile-wine": "$(git -C "$RUNTIME/wine" rev-parse HEAD)",
  "voile-lkd": "$(plutil -extract voile-lkd raw -o - "$WORK/linux/lkd/VERSION.json")",
  "fex": "$(plutil -extract fex raw -o - "$WORK/linux/lkd/VERSION.json")",
  "neptune": "$(plutil -extract neptune raw -o - "$WORK/linux/neptune/VERSION.json")",
  "dxmt": "$(basename "$(field dxmt url)" .tar.xz)",
  "debian-root": "$(basename "$(field debian-root url)" .tar.xz)"
}
JSON
}

# Extracted anywhere, the archive must run a Windows program through the engine.
verify() {
    local root="$WORK/verify-linux" output
    rm -rf "$root"
    mkdir -p "$root/home"
    tar -xJf "$ARCHIVE" -C "$root"
    local base="$root/$NAME"
    output="$(FEXDARWIN_LKD=1 FEXDARWIN_ROOT="$base/root" FEXDARWIN_ROOT_RO=1 \
        FEXDARWIN_BIND="/opt/wine=$base/wine:ro;/home/user=$root/home" \
        "$base/engine/run-with-timeout.sh" 600 "$base/engine/fexdarwin-run" \
        --env HOME=/home/user --env USER=user --env PATH=/opt/wine/bin:/usr/bin:/bin \
        --env WINEPREFIX=/home/user/prefix --env WINEDEBUG=-all \
        --env 'WINEDLLOVERRIDES=mscoree,mshtml=;winemenubuilder.exe=d' \
        /bin/sh -c '/opt/wine/bin/wine cmd /c ver; /opt/wine/bin/wineserver -w' 2>/dev/null)" || true
    [[ "$output" == *Windows* ]] || fail "cmd did not run through the engine from the archive: $output"
    rm -rf "$root"
}

echo "==> $NAME"
rm -rf "$WORK/package-linux" "$RELEASE/$NAME.tar.xz" "$RELEASE/$NAME.tar.xz.sha256"
mkdir -p "$WORK/package-linux" "$RELEASE"
cp -cR "$STAGE" "$PACKAGE"
rm -rf "$PACKAGE/wine/share/man"
strip_debug
copy_licenses
write_manifest
COPYFILE_DISABLE=1 tar --create --xz --options xz:compression-level=9,xz:threads=0 \
    --no-mac-metadata --no-xattrs --uid 0 --gid 0 --numeric-owner \
    --file "$ARCHIVE" -C "$WORK/package-linux" "$NAME"
(cd "$RELEASE" && shasum -a 256 "$NAME.tar.xz" > "$NAME.tar.xz.sha256")
echo "==> Checking the archive"
verify
echo "Linux engine runtime archive: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
