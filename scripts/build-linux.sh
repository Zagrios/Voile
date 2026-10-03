#!/bin/bash
# Builds the Linux engine runtime: voile-wine for x86-64 Linux, which the engine runs on macOS arm64, the engine
# itself (the voile-lkd submodule) and Neptune (the neptune submodule), beside the pinned DXMT and Debian root
# archives of sources.json. Run build.sh first: the Linux build reuses the Wine build tools of the macOS build and its
# llvm-mingw. voile-lkd needs cmake, Neptune meson and Python with Mako and PyYAML, all from the caller's PATH. Each
# step reruns only when its inputs change. Result: build/linux/stage.
set -euo pipefail
RUNTIME="$(cd "$(dirname "$0")/.." && pwd)"
WINE_SOURCES="$RUNTIME/wine"
LKD_SOURCES="$RUNTIME/voile-lkd"
NEPTUNE_SOURCES="$RUNTIME/neptune"
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
# voile-lkd and Neptune build with the caller's tools; Wine with these only.
CALLER_PATH="$PATH"
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

# A checkout's commit, and a digest of its uncommitted changes and nested submodules: a local edit rebuilds it.
tree_key() {
    printf '%s-%s' "$(git -C "$1" rev-parse HEAD)" \
        "$({ git -C "$1" diff HEAD; git -C "$1" submodule status --recursive; } | shasum -a 256 | cut -c1-16)"
}

current() {
    [[ -f "$LINUX/stamps/$1" && "$(cat "$LINUX/stamps/$1")" == "$2" ]]
}

stamp() {
    mkdir -p "$LINUX/stamps"
    printf '%s' "$2" > "$LINUX/stamps/$1"
}

[[ -f "$WINE_SOURCES/configure" ]] || fail "The wine submodule is missing: git submodule update --init"
[[ -f "$LKD_SOURCES/fex/CMakeLists.txt" && -f "$NEPTUNE_SOURCES/scripts/build-server.sh" ]] ||
    fail "The voile-lkd and neptune submodules are missing: git submodule update --init --recursive"
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

# The pinned archives of the parts this repository does not build: DXMT, the Debian root.
build_archives() {
    local name archive key
    for name in dxmt debian-root; do
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

# The engine's host pages are 16 KiB and the guest's 4 KiB: code and often-written data that share a 16 KiB page make
# every store fault and drop the code's translations (nptunix.so: about 19,000 faults a second in Rocket League). Each
# PT_LOAD of a Linux library and of the loader starts on its own 16 KiB page.
WINE_UNIX_LDFLAGS="-Wl,-z,max-page-size=16384"

build_wine() {
    local source_key key
    source_key="$(git -C "$WINE_SOURCES" rev-parse HEAD)-$(git -C "$WINE_SOURCES" diff HEAD | shasum -a 256 | cut -c1-16)"
    key="$source_key $(field zig sha256) $(cat "$LINUX/stamps/sysroot") ${WINE_OPTIONS[*]} $WINE_UNIX_LDFLAGS"
    current wine "$key" && return
    echo "==> Wine for Linux $(git -C "$WINE_SOURCES" rev-parse --short=12 HEAD)"
    rm -rf "$OBJECTS" "$STAGE/wine"
    mkdir -p "$OBJECTS"
    (
        cd "$OBJECTS"
        export PATH="$TOOLS/bin:$MINGW/bin:$PATH"
        "$WINE_SOURCES/configure" --host=x86_64-linux-gnu --with-wine-tools="$WINE_TOOLS" --prefix=/opt/wine \
            "${WINE_OPTIONS[@]}" LDFLAGS="$WINE_UNIX_LDFLAGS" \
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

# The engine's host programs: fexdarwin-run (FEXCore and LKD), the window server (wsd, wsdctl) and the supervisor
# wrapper, without their debug information, which points into the build tree.
build_lkd() {
    local key out="$LINUX/lkd" binary notice
    key="$(tree_key "$LKD_SOURCES")"
    current lkd "$key" && return
    echo "==> voile-lkd $(git -C "$LKD_SOURCES" rev-parse --short=12 HEAD)"
    PATH="$CALLER_PATH" JOBS="$JOBS" nice -n 10 "$LKD_SOURCES/build.sh"
    rm -rf "$out"
    mkdir -p "$out/bin" "$out/licenses"
    cp "$LKD_SOURCES/fexdarwin/build/host/fexdarwin-run" "$LKD_SOURCES/wsd/bin/wsd" "$LKD_SOURCES/wsd/bin/wsdctl" \
        "$LKD_SOURCES/fexdarwin/scripts/run-with-timeout.sh" "$out/bin/"
    for binary in fexdarwin-run wsd wsdctl; do
        codesign --remove-signature "$out/bin/$binary" 2>/dev/null || true
        strip -S "$out/bin/$binary"
        codesign --sign - "$out/bin/$binary"
    done
    cp "$LKD_SOURCES/LICENSE" "$out/licenses/voile-lkd.txt"
    {
        cat "$LKD_SOURCES/NOTICE"
        for notice in "$LKD_SOURCES"/lkd/NOTICE "$LKD_SOURCES"/lkd/src/*/NOTICE; do
            [[ -f "$notice" ]] && printf '\n----- %s\n' "${notice#"$LKD_SOURCES"/}" && cat "$notice"
        done
    } > "$out/licenses/voile-lkd-notices.txt"
    cp "$LKD_SOURCES/fex/LICENSE" "$out/licenses/fex.txt"
    printf '{\n  "voile-lkd": "%s",\n  "fex": "%s"\n}\n' "$(git -C "$LKD_SOURCES" rev-parse HEAD)" \
        "$(git -C "$LKD_SOURCES/fex" rev-parse HEAD)" > "$out/VERSION.json"
    stamp lkd "$key"
}

# Neptune: the guest driver (d3d11.dll, dxgi.dll, d3d12.dll for the prefix) and the macOS render server with its
# libraries, relinked to find each other through @rpath. The render server needs
# RENDER_SERVER_EXEC_PATH=graphics/libexec/virgl_render_server at run time. They lose their debug information.
build_neptune() {
    local key out="$LINUX/neptune" prefix="$NEPTUNE_SOURCES/build/prefix" binary
    key="$(tree_key "$NEPTUNE_SOURCES")"
    current neptune "$key" && return
    echo "==> Neptune $(git -C "$NEPTUNE_SOURCES" rev-parse --short=12 HEAD)"
    PATH="$CALLER_PATH" LLVM_MINGW="$MINGW" JOBS="$JOBS" nice -n 10 "$NEPTUNE_SOURCES/scripts/build-client.sh"
    PATH="$CALLER_PATH" JOBS="$JOBS" nice -n 10 "$NEPTUNE_SOURCES/scripts/build-server.sh"
    rm -rf "$out"
    mkdir -p "$out/windows" "$out/graphics/bin" "$out/graphics/libexec" "$out/graphics/lib" "$out/licenses"
    cp "$NEPTUNE_SOURCES"/build/client/src/virtio/neptune/{d3d11,dxgi,d3d12}.dll "$out/windows/"
    "$MINGW/bin/llvm-strip" --strip-debug "$out"/windows/*.dll
    cp "$prefix/bin/virgl_test_server" "$out/graphics/bin/"
    cp "$prefix/libexec/virgl_render_server" "$out/graphics/libexec/"
    cp "$prefix/lib/libvirglrenderer.1.dylib" "$prefix/lib/libepoxy.0.dylib" "$out/graphics/lib/"
    # The build links by absolute path into its prefix: relink through @rpath.
    install_name_tool -id @rpath/libepoxy.0.dylib "$out/graphics/lib/libepoxy.0.dylib"
    install_name_tool -id @rpath/libvirglrenderer.1.dylib \
        -change "$prefix/lib/libepoxy.0.dylib" @rpath/libepoxy.0.dylib \
        -add_rpath @loader_path "$out/graphics/lib/libvirglrenderer.1.dylib"
    install_name_tool -change "$prefix/lib/libvirglrenderer.1.dylib" @rpath/libvirglrenderer.1.dylib \
        -add_rpath @executable_path/../lib "$out/graphics/bin/virgl_test_server"
    for binary in "$out"/graphics/bin/* "$out"/graphics/libexec/* "$out"/graphics/lib/*; do
        codesign --remove-signature "$binary" 2>/dev/null || true
        strip -S "$binary"
        codesign --sign - "$binary"
    done
    ! otool -L "$out"/graphics/bin/* "$out"/graphics/lib/* | grep -q "$NEPTUNE_SOURCES" ||
        fail "a Neptune library still points into its build tree"
    cp "$NEPTUNE_SOURCES/mesa/docs/license.rst" "$out/licenses/mesa.rst"
    cp "$NEPTUNE_SOURCES/virglrenderer/COPYING" "$out/licenses/virglrenderer.txt"
    cp "$NEPTUNE_SOURCES"/build/dl/libepoxy-1.5.10/COPYING "$out/licenses/libepoxy.txt"
    printf '{\n  "neptune": "%s"\n}\n' "$(git -C "$NEPTUNE_SOURCES" rev-parse HEAD)" > "$out/VERSION.json"
    stamp neptune "$key"
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
build_lkd
build_neptune
build_sysroot
build_wine
build_stage
echo "Linux engine runtime: $STAGE"
