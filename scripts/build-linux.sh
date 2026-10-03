#!/bin/bash
# Builds the Linux engine runtime: voile-wine for x86-64 Linux, which the engine (voile-lkd) runs on macOS arm64,
# beside the pinned engine, Debian root, Neptune and DXMT archives of sources.json. Run build.sh first: the Linux
# build reuses the Wine build tools of the macOS build and its llvm-mingw. Each step reruns only when its inputs
# change. Result: build/linux/stage.
set -euo pipefail
RUNTIME="$(cd "$(dirname "$0")/.." && pwd)"
WINE_SOURCES="$RUNTIME/wine"
WORK="$RUNTIME/build"
DOWNLOADS="$WORK/downloads"
LINUX="$WORK/linux"
ZIG="$LINUX/zig"
TOOLS="$LINUX/tools"
SYSROOT="$LINUX/sysroot"
OBJECTS="$LINUX/obj/wine"
STAGE="$LINUX/stage"
MINGW="$WORK/toolchain/llvm-mingw"
WINE_TOOLS="$WORK/obj/wine"
# At most 4 jobs: the Linux engine work keeps this rule for the whole machine.
JOBS=4
TARGET=x86_64-linux-gnu.2.36
export PATH="/opt/homebrew/opt/bison/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
export ZIG_GLOBAL_CACHE_DIR="$LINUX/zig-cache" ZIG_LOCAL_CACHE_DIR="$LINUX/zig-cache-local"
# What the guest Wine does without: no X11, no system audio or Vulkan (wsd, winesailaudio and Neptune replace them).
WINE_OPTIONS=(--enable-win64 --enable-archs=x86_64 --disable-tests --without-x --without-fontconfig
    --without-gstreamer --without-pulse --without-alsa --without-cups --without-sdl --without-vulkan
    --without-opengl --without-dbus --without-udev --without-usb --without-v4l2 --without-gphoto --without-sane
    --without-pcap --without-krb5 --without-oss --without-capi --without-netapi --without-unwind
    --without-wayland --without-inotify)

fail() {
    echo "$*" >&2
    exit 1
}

field() {
    plutil -extract "$1.$2" raw -o - "$RUNTIME/sources.json"
}

verified() {
    [[ -f "$1" && "$(shasum -a 256 "$1" | cut -d' ' -f1)" == "$2" ]]
}

fetch() {
    local url sha file
    url="$(field "$1" url)"
    sha="$(field "$1" sha256)"
    file="$DOWNLOADS/$(basename "$url")"
    if ! verified "$file" "$sha"; then
        mkdir -p "$DOWNLOADS"
        curl -fL --retry 3 --progress-bar -o "$file.partial" "$url" >&2
        verified "$file.partial" "$sha" || fail "Checksum mismatch for $url"
        mv "$file.partial" "$file"
    fi
    echo "$file"
}

current() {
    [[ -f "$LINUX/stamps/$1" && "$(cat "$LINUX/stamps/$1")" == "$2" ]]
}

stamp() {
    mkdir -p "$LINUX/stamps"
    printf '%s' "$2" > "$LINUX/stamps/$1"
}

[[ -f "$WINE_SOURCES/configure" ]] || fail "The wine submodule is missing: git submodule update --init"
[[ -x "$WINE_TOOLS/tools/winebuild/winebuild" && -x "$MINGW/bin/ld.lld" ]] ||
    fail "Build the macOS runtime first (./scripts/build.sh): its Wine tools and llvm-mingw build this one"

# zig cc is the x86-64 Linux C compiler (glibc 2.36 ABI); llvm-mingw's lld and binutils do the rest.
build_zig() {
    local archive key
    archive="$(fetch zig)"
    key="$(field zig sha256)"
    current zig "$key" && return
    echo "==> zig"
    rm -rf "$ZIG" "$TOOLS"
    mkdir -p "$ZIG" "$TOOLS/bin" "$TOOLS/stub"
    tar -xJf "$archive" -C "$ZIG" --strip-components 1
    # zig cc ignores -nostartfiles and cannot make a static-pie without libc: the wine-preloader link
    # (-static-pie -nostartfiles, objects without relocations) goes straight to ld.lld.
    cat > "$TOOLS/bin/x86_64-linux-gnu-gcc" <<WRAPPER
#!/bin/sh
case " \$* " in
  *" -nostartfiles "*" -static-pie "*|*" -static-pie "*" -nostartfiles "*)
    out=; objs=
    while [ \$# -gt 0 ]; do
      case "\$1" in -o) out=\$2; shift;; -static-pie|-nostartfiles|-nodefaultlibs|-m64|-std=*) ;; *) objs="\$objs \$1";; esac
      shift
    done
    exec '$MINGW/bin/ld.lld' -pie --no-dynamic-linker -z norelro -o "\$out" \$objs;;
esac
case " \$* " in
  *" -shared "*) exec '$ZIG/zig' cc -target $TARGET "\$@" -L'$TOOLS/stub' -Wl,--as-needed -lgcc_s;;
esac
exec '$ZIG/zig' cc -target $TARGET "\$@"
WRAPPER
    local tool
    printf '#!/bin/sh\nexec %q c++ -target %s "$@"\n' "$ZIG/zig" "$TARGET" > "$TOOLS/bin/x86_64-linux-gnu-g++"
    printf '#!/bin/sh\nexec %q cc -target %s -E "$@"\n' "$ZIG/zig" "$TARGET" > "$TOOLS/bin/x86_64-linux-gnu-cpp"
    printf '#!/bin/sh\nexec %q ar "$@"\n' "$ZIG/zig" > "$TOOLS/bin/x86_64-linux-gnu-ar"
    printf '#!/bin/sh\nexec %q ranlib "$@"\n' "$ZIG/zig" > "$TOOLS/bin/x86_64-linux-gnu-ranlib"
    printf '#!/bin/sh\nexec %q "$@"\n' "$MINGW/bin/ld.lld" > "$TOOLS/bin/x86_64-linux-gnu-ld"
    for tool in nm objdump readelf strip objcopy; do
        printf '#!/bin/sh\nexec %q "$@"\n' "$MINGW/bin/llvm-$tool" > "$TOOLS/bin/x86_64-linux-gnu-$tool"
    done
    chmod +x "$TOOLS"/bin/*
    # ntdll.so needs _Unwind_Find_FDE, which glibc systems get from libgcc_s.so.1 (zig ships none): link against a
    # stub with that soname; the guest loads the real one from the Debian root.
    echo 'void *_Unwind_Find_FDE(void *pc, void *bases) { return 0; }' > "$TOOLS/stub/stub.c"
    "$ZIG/zig" cc -target "$TARGET" -shared -Wl,-soname,libgcc_s.so.1 -o "$TOOLS/stub/libgcc_s.so" \
        "$TOOLS/stub/stub.c"
    stamp zig "$key"
}

# The pinned archives of the private and binary parts: the engine, Neptune, DXMT, the Debian root.
build_archives() {
    local name archive key
    for name in lkd neptune dxmt debian-root; do
        archive="$(fetch "$name")"
        key="$(field "$name" sha256)"
        current "$name" "$key" && continue
        echo "==> $name"
        rm -rf "$LINUX/$name"
        mkdir -p "$LINUX/$name"
        tar -xJf "$archive" -C "$LINUX/$name" --strip-components 1
        stamp "$name" "$key"
    done
}

# Headers of FreeType and GnuTLS for the guest's versions (Debian -dev packages), linked against the root's
# libraries.
build_sysroot() {
    local key package archive member
    key="$(field debian-freetype-dev sha256)-$(field debian-gnutls-dev sha256)-$(field debian-root sha256)"
    current sysroot "$key" && return
    echo "==> sysroot"
    rm -rf "$SYSROOT"
    mkdir -p "$SYSROOT"
    for package in debian-freetype-dev debian-gnutls-dev; do
        archive="$(fetch "$package")"
        member="$(ar t "$archive" | grep '^data.tar')"
        ar p "$archive" "$member" | tar -xf - -C "$SYSROOT" ./usr/include
    done
    mkdir -p "$SYSROOT/usr/lib/x86_64-linux-gnu"
    ln -sf "$LINUX/debian-root/root/usr/lib/x86_64-linux-gnu/libfreetype.so.6" \
        "$SYSROOT/usr/lib/x86_64-linux-gnu/libfreetype.so"
    ln -sf "$LINUX/debian-root/root/usr/lib/x86_64-linux-gnu/libgnutls.so.30" \
        "$SYSROOT/usr/lib/x86_64-linux-gnu/libgnutls.so"
    stamp sysroot "$key"
}

build_wine() {
    local source_key key
    source_key="$(git -C "$WINE_SOURCES" rev-parse HEAD)-$(git -C "$WINE_SOURCES" diff HEAD | shasum -a 256 | cut -c1-16)"
    key="$source_key $(field zig sha256) $(cat "$LINUX/stamps/sysroot") ${WINE_OPTIONS[*]}"
    current wine "$key" && return
    echo "==> Wine for Linux $(git -C "$WINE_SOURCES" rev-parse --short=12 HEAD)"
    rm -rf "$OBJECTS" "$STAGE/wine"
    mkdir -p "$OBJECTS"
    (
        cd "$OBJECTS"
        export PATH="$TOOLS/bin:$MINGW/bin:$PATH"
        "$WINE_SOURCES/configure" --host=x86_64-linux-gnu --with-wine-tools="$WINE_TOOLS" --prefix=/opt/wine \
            "${WINE_OPTIONS[@]}" \
            FREETYPE_CFLAGS="-I$SYSROOT/usr/include/freetype2" \
            FREETYPE_LIBS="-L$SYSROOT/usr/lib/x86_64-linux-gnu -lfreetype -Wl,--allow-shlib-undefined" \
            GNUTLS_CFLAGS="-I$SYSROOT/usr/include" \
            GNUTLS_LIBS="-L$SYSROOT/usr/lib/x86_64-linux-gnu -lgnutls -Wl,--allow-shlib-undefined"
        nice -n 10 make -j"$JOBS"
        make install-lib prefix="$STAGE/wine" bindir="$STAGE/wine/bin" libdir="$STAGE/wine/lib" \
            dlldir="$STAGE/wine/lib/wine" datadir="$STAGE/wine/share" fontdir="$STAGE/wine/share/wine/fonts" \
            nlsdir="$STAGE/wine/share/wine/nls"
    )
    # A 64-bit-only build installs the loader under lib/wine/x86_64-unix; bin/wine points at it.
    ln -sf ../lib/wine/x86_64-unix/wine "$STAGE/wine/bin/wine"
    stamp wine "$key"
}

# The runtime's layout: engine/ (host programs), graphics/ (render server, DXMT), windows/ (Neptune's DLLs for the
# prefix), wine/ (voile-wine for Linux), root/ (the Debian root).
build_stage() {
    local key
    key="$(cat "$LINUX"/stamps/{wine,lkd,neptune,dxmt,debian-root})"
    current stage "$key" && return
    echo "==> Linux runtime stage"
    rm -rf "$STAGE/engine" "$STAGE/graphics" "$STAGE/windows" "$STAGE/root"
    ditto "$LINUX/lkd/bin" "$STAGE/engine"
    ditto "$LINUX/neptune/graphics" "$STAGE/graphics"
    ditto "$LINUX/dxmt/dxmt-native.framework" "$STAGE/graphics/dxmt-native.framework"
    ditto "$LINUX/neptune/windows" "$STAGE/windows"
    cp -cR "$LINUX/debian-root/root" "$STAGE/root"
    stamp stage "$key"
}

build_zig
build_archives
build_sysroot
build_wine
build_stage
echo "Linux engine runtime: $STAGE"
