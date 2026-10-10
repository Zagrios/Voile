#!/bin/bash
# Builds the Linux engine runtime: voile-wine for x86-64 Linux, which the engine runs on macOS arm64, with Proton's
# Steam bridge, the engine itself (the voile-lkd submodule) and Neptune (the neptune submodule), beside the pinned
# DXMT, d3dmetal-native, Valve Linux steamclient and Debian root inputs of sources.json. Run build.sh first: the
# Linux build reuses the Wine build tools of the macOS build, its llvm-mingw and its patched Proton sources.
# voile-lkd needs cmake, Neptune meson and Python with Mako and PyYAML, all from the caller's PATH. Each step reruns
# only when its inputs change. Result: build/linux/stage.
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
PROTON_SOURCES="$WORK/src-proton"
# At most 4 jobs: the Linux engine work keeps this rule for the whole machine.
JOBS=4
TARGET=x86_64-linux-gnu.2.36
# voile-lkd and Neptune build with the caller's tools; Wine with these only.
CALLER_PATH="$PATH"
export PATH="/opt/homebrew/opt/bison/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
export ZIG_GLOBAL_CACHE_DIR="$LINUX/zig-cache" ZIG_LOCAL_CACHE_DIR="$LINUX/zig-cache-local"
# What the guest Wine does without: no X11, no system audio or Vulkan (wsd, wineobeliskaudio and Neptune replace them).
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
[[ -x "$WINE_TOOLS/tools/winebuild/winebuild" && -x "$MINGW/bin/ld.lld" && -f "$WORK/stamps/proton-sources" ]] ||
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
# libraries, and the X11 key symbols lsteamclient maps Windows keys to (headers only: the guest has no X11).
build_sysroot() {
    local key package archive member
    key="$(field debian-freetype-dev sha256)-$(field debian-gnutls-dev sha256)-$(field debian-root sha256)"
    key+="-$(field debian-x11proto-dev sha256)"
    current sysroot "$key" && return
    echo "==> sysroot"
    rm -rf "$SYSROOT"
    mkdir -p "$SYSROOT"
    for package in debian-freetype-dev debian-gnutls-dev debian-x11proto-dev; do
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

# The 64-bit preloader's file name. Older EAC launcher modules (ELDEN RING's) read /proc/self/exe and start the game
# only from a loader named wine64-preloader, beside a wine64: GE-Proton keeps that layout. Wine still runs
# wine-preloader, now a link to this file, and /proc/self/exe shows the file's own name.
WINE_PRELOADER=wine64-preloader

build_wine() {
    local source_key key unix="$STAGE/wine/lib/wine/x86_64-unix"
    source_key="$(git -C "$WINE_SOURCES" rev-parse HEAD)-$(git -C "$WINE_SOURCES" diff HEAD | shasum -a 256 | cut -c1-16)"
    key="$source_key $(field zig sha256) $(cat "$LINUX/stamps/sysroot") ${WINE_OPTIONS[*]} $WINE_UNIX_LDFLAGS"
    key+=" $WINE_PRELOADER"
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
    mv "$unix/wine-preloader" "$unix/$WINE_PRELOADER"
    ln -s "$WINE_PRELOADER" "$unix/wine-preloader"
    ln -s wine "$unix/wine64"
    stamp wine "$key"
}

# Proton's Steam bridge, built against this Wine the way build.sh builds it for macOS (see build_proton_module
# there): lsteamclient, whose unix side loads Valve's Linux client from $HOME/.steam/sdk64/steamclient.so, and the
# steam.exe helper games start behind. The runtime's ntdll redirects Valve's Windows steamclient64.dll to
# lsteamclient. They install into the stage's Wine.
build_steam() {
    local key name objects
    key="$(cat "$LINUX/stamps/wine") $(cat "$WORK/stamps/proton-sources")"
    current steam "$key" && return
    for name in lsteamclient steam_helper; do
        echo "==> $name for Linux"
        objects="$LINUX/obj/$name"
        rm -rf "$objects"
        mkdir -p "$objects"
        sed -e "1i\\
UNIX_LIBS = $OBJECTS/dlls/ntdll/ntdll.so
" -e '/^all:$/,$c\
all:' -e "/^SUBDIRS/,/[^\\\\]\$/c\\
SUBDIRS = $PROTON_SOURCES/$name" -e "/^srcdir/a\\
objdir = $OBJECTS" -e '/^TOP_INSTALL_LIB/c\
TOP_INSTALL_LIB =' -e "/^CXXFLAGS/s|\$| -std=c++17 -include string.h -include wchar.h -DNOMINMAX -I$SYSROOT/usr/include|" \
            "$OBJECTS/Makefile" > "$objects/Makefile"
        touch "$objects/config.status"
        (
            cd "$objects"
            export PATH="$TOOLS/bin:$MINGW/bin:$PATH"
            "$WINE_TOOLS/tools/makedep"
            nice -n 10 make -j"$JOBS"
            make install-lib prefix="$STAGE/wine" bindir="$STAGE/wine/bin" libdir="$STAGE/wine/lib" \
                dlldir="$STAGE/wine/lib/wine"
        )
    done
    stamp steam "$key"
}

# Valve's Linux steamclient (the bins_sdk_ubuntu12 package of Valve's client CDN, the build of Obelisk's macOS
# steamclient.dylib) with its crash handler, which its RUNPATH $ORIGIN finds beside it. The guest's
# ~/.steam/sdk64 must lead to this folder: lsteamclient loads it from there. Shipped unmodified.
build_steam_client() {
    local archive key
    archive="$(fetch steam-linux)"
    key="$(field steam-linux sha256)"
    current steam-linux "$key" && return
    echo "==> Valve Linux steamclient"
    rm -rf "$LINUX/steam"
    mkdir -p "$LINUX/steam"
    unzip -q -o "$archive" linux64/steamclient.so linux64/crashhandler.so -d "$LINUX/steam"
    stamp steam-linux "$key"
}

# The engine's host programs: fexdarwin-run (FEXCore and LKD), the window server (wsd, wsdctl), the input service
# (obelisk-input, with SDL3 inside) and the supervisor wrapper, without their debug information, which points into
# the build tree. And a guest library, built with this zig: steam-hostpid.so, which a launch preloads in the guest so
# that Valve's steamclient.so gives Obelisk's Steam host the macOS pid of its process.
build_lkd() {
    local key out="$LINUX/lkd" binary notice
    key="$(tree_key "$LKD_SOURCES")"
    current lkd "$key" && return
    echo "==> voile-lkd $(git -C "$LKD_SOURCES" rev-parse --short=12 HEAD)"
    PATH="$CALLER_PATH" JOBS="$JOBS" ZIG="$ZIG/zig" nice -n 10 "$LKD_SOURCES/build.sh"
    rm -rf "$out"
    mkdir -p "$out/bin" "$out/guest" "$out/licenses"
    cp "$LKD_SOURCES/guest/bin/steam-hostpid.so" "$out/guest/"
    cp "$LKD_SOURCES/fexdarwin/build/host/fexdarwin-run" "$LKD_SOURCES/wsd/bin/wsd" "$LKD_SOURCES/wsd/bin/wsdctl" \
        "$LKD_SOURCES/input/bin/obelisk-input" "$LKD_SOURCES/fexdarwin/scripts/run-with-timeout.sh" "$out/bin/"
    for binary in fexdarwin-run wsd wsdctl obelisk-input; do
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
    cp "$LKD_SOURCES/input/bin/SDL3-LICENSE.txt" "$out/licenses/sdl3.txt"
    printf '{\n  "voile-lkd": "%s",\n  "fex": "%s"\n}\n' "$(git -C "$LKD_SOURCES" rev-parse HEAD)" \
        "$(git -C "$LKD_SOURCES/fex" rev-parse HEAD)" > "$out/VERSION.json"
    stamp lkd "$key"
}

# A render server built into PREFIX, copied to DESTINATION ({bin,libexec,lib}) and relinked to find its libraries
# through @rpath: the build links them by absolute path into its prefix. They lose their debug information.
copy_render_server() {
    local prefix="$1" destination="$2" binary
    mkdir -p "$destination/bin" "$destination/libexec" "$destination/lib"
    cp "$prefix/bin/virgl_test_server" "$destination/bin/"
    cp "$prefix/libexec/virgl_render_server" "$destination/libexec/"
    cp "$prefix/lib/libvirglrenderer.1.dylib" "$prefix/lib/libepoxy.0.dylib" "$destination/lib/"
    install_name_tool -id @rpath/libepoxy.0.dylib "$destination/lib/libepoxy.0.dylib"
    install_name_tool -id @rpath/libvirglrenderer.1.dylib \
        -change "$prefix/lib/libepoxy.0.dylib" @rpath/libepoxy.0.dylib \
        -add_rpath @loader_path "$destination/lib/libvirglrenderer.1.dylib"
    install_name_tool -change "$prefix/lib/libvirglrenderer.1.dylib" @rpath/libvirglrenderer.1.dylib \
        -add_rpath @executable_path/../lib "$destination/bin/virgl_test_server"
    for binary in "$destination"/bin/* "$destination"/libexec/* "$destination"/lib/*; do
        codesign --remove-signature "$binary" 2>/dev/null || true
        strip -S "$binary"
        codesign --sign - "$binary"
    done
    ! otool -L "$destination"/bin/* "$destination"/libexec/* "$destination"/lib/* | grep -q "$prefix" ||
        fail "a Neptune library still points into its build tree"
}

# Neptune's render server for x86_64, which runs under Rosetta: Apple's D3DMetal, which the D3DMetal backend loads,
# is x86_64 only, and so is every process that loads it. Built outside the submodule, from the libepoxy that
# build-server.sh downloads.
build_neptune_x86_64() {
    local objects="$LINUX/obj/neptune-x86_64" prefix="$LINUX/obj/neptune-x86_64/prefix" cross
    cross="$LINUX/x86_64-darwin.ini"
    cat > "$cross" <<'EOF'
[binaries]
c = ['clang', '-arch', 'x86_64']
cpp = ['clang++', '-arch', 'x86_64']
objc = ['clang', '-arch', 'x86_64']
objcpp = ['clang++', '-arch', 'x86_64']
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'
exe_wrapper = ['arch', '-x86_64']

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'darwin'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
    (
        export PATH="$CALLER_PATH"
        if [[ ! -f "$prefix/lib/libepoxy.0.dylib" ]]; then
            rm -rf "$objects"
            meson setup "$objects/epoxy" "$NEPTUNE_SOURCES/build/dl/libepoxy-1.5.10" --cross-file "$cross" \
                --prefix="$prefix" -Dtests=false -Dglx=no -Degl=no -Dx11=false --buildtype=release
            nice -n 10 ninja -j "$JOBS" -C "$objects/epoxy"
            meson install --no-rebuild -C "$objects/epoxy" >/dev/null
        fi
        [[ -f "$objects/server/build.ninja" ]] ||
            meson setup "$objects/server" "$NEPTUNE_SOURCES/virglrenderer" --cross-file "$cross" --prefix="$prefix" \
                --pkg-config-path="$prefix/lib/pkgconfig" -Dneptune=true -Dvenus=false -Dvtest=true \
                -Drender-server-mode=process -Drender-server-worker=process -Dtests=false -Dcheck-gl-errors=false \
                --buildtype=release
        nice -n 10 ninja -j "$JOBS" -C "$objects/server"
        meson install --no-rebuild -C "$objects/server" >/dev/null
    )
}

# Neptune: the guest driver (d3d11.dll, dxgi.dll, d3d12.dll for the prefix) and the macOS render server with its
# libraries, for arm64 in graphics (DXMT) and for x86_64 in graphics/x86_64 (D3DMetal). The render server needs
# RENDER_SERVER_EXEC_PATH=<its folder>/libexec/virgl_render_server at run time.
build_neptune() {
    local key out="$LINUX/neptune"
    key="$(tree_key "$NEPTUNE_SOURCES")"
    current neptune "$key" && return
    echo "==> Neptune $(git -C "$NEPTUNE_SOURCES" rev-parse --short=12 HEAD)"
    PATH="$CALLER_PATH" LLVM_MINGW="$MINGW" JOBS="$JOBS" nice -n 10 "$NEPTUNE_SOURCES/scripts/build-client.sh"
    PATH="$CALLER_PATH" JOBS="$JOBS" nice -n 10 "$NEPTUNE_SOURCES/scripts/build-server.sh"
    build_neptune_x86_64
    rm -rf "$out"
    mkdir -p "$out/windows" "$out/licenses"
    cp "$NEPTUNE_SOURCES"/build/client/src/virtio/neptune/{d3d11,dxgi,d3d12}.dll "$out/windows/"
    "$MINGW/bin/llvm-strip" --strip-debug "$out"/windows/*.dll
    copy_render_server "$NEPTUNE_SOURCES/build/prefix" "$out/graphics"
    copy_render_server "$LINUX/obj/neptune-x86_64/prefix" "$out/graphics/x86_64"
    cp "$NEPTUNE_SOURCES/mesa/docs/license.rst" "$out/licenses/mesa.rst"
    cp "$NEPTUNE_SOURCES/virglrenderer/COPYING" "$out/licenses/virglrenderer.txt"
    cp "$NEPTUNE_SOURCES"/build/dl/libepoxy-1.5.10/COPYING "$out/licenses/libepoxy.txt"
    printf '{\n  "neptune": "%s"\n}\n' "$(git -C "$NEPTUNE_SOURCES" rev-parse HEAD)" > "$out/VERSION.json"
    stamp neptune "$key"
}

# UTM's d3dmetal-native, the host interface Apple's D3DMetal expects from its Wine, for a native process: the
# render server's D3DMetal backend. x86_64 only, like D3DMetal, which it finds through D3DMETAL_FRAMEWORK_PATH; the
# runtime's lib/external/D3DMetal.framework is the one to name, never a copy. MIT, built from the pinned commit.
build_d3dmetal_native() {
    local archive key sources="$LINUX/obj/d3dmetal-native-src" objects="$LINUX/obj/d3dmetal-native"
    local out="$LINUX/d3dmetal-native"
    archive="$(fetch d3dmetal-native)"
    key="$(field d3dmetal-native sha256)"
    current d3dmetal-native "$key" && return
    echo "==> d3dmetal-native"
    rm -rf "$sources" "$objects" "$out"
    mkdir -p "$sources" "$out/lib" "$out/licenses"
    tar -xzf "$archive" -C "$sources" --strip-components 1
    (
        export PATH="$CALLER_PATH"
        # Its last resort, when D3DMETAL_FRAMEWORK_PATH is unset, is a compiled-in path: D3DMetal's own install
        # name rather than the source tree.
        meson setup "$objects" "$sources" --cross-file "$sources/build-macos-x86_64.txt" --buildtype=release \
            -Dtests=disabled -Ddev_framework_path=/System/Library/Frameworks/D3DMetal.framework/Versions/A/D3DMetal
        nice -n 10 ninja -j "$JOBS" -C "$objects"
    )
    cp "$objects/libd3dmetal-native.dylib" "$out/lib/"
    install_name_tool -id @rpath/libd3dmetal-native.dylib "$out/lib/libd3dmetal-native.dylib"
    codesign --remove-signature "$out/lib/libd3dmetal-native.dylib" 2>/dev/null || true
    strip -S "$out/lib/libd3dmetal-native.dylib"
    codesign --sign - "$out/lib/libd3dmetal-native.dylib"
    cp "$sources/LICENSE" "$out/licenses/d3dmetal-native.txt"
    stamp d3dmetal-native "$key"
}

# The runtime's layout: engine/ (host programs), graphics/ (arm64 render server, DXMT), graphics/x86_64 (x86_64
# render server, d3dmetal-native), windows/ (Neptune's DLLs for the prefix), wine/ (voile-wine for Linux, with
# lsteamclient and steam.exe), steam/ (Valve's Linux steamclient), guest/ (libraries a launch preloads in the guest),
# root/ (the Debian root).
build_stage() {
    local key
    key="$(cat "$LINUX"/stamps/{wine,steam,lkd,neptune,dxmt,d3dmetal-native,steam-linux,debian-root})"
    current stage "$key" && return
    echo "==> Linux runtime stage"
    rm -rf "$STAGE/engine" "$STAGE/guest" "$STAGE/graphics" "$STAGE/windows" "$STAGE/steam" "$STAGE/root"
    ditto "$LINUX/lkd/bin" "$STAGE/engine"
    ditto "$LINUX/lkd/guest" "$STAGE/guest"
    ditto "$LINUX/neptune/graphics" "$STAGE/graphics"
    ditto "$LINUX/dxmt/dxmt-native.framework" "$STAGE/graphics/dxmt-native.framework"
    ditto "$LINUX/d3dmetal-native/lib" "$STAGE/graphics/x86_64/lib"
    ditto "$LINUX/steam" "$STAGE/steam"
    # Valve's Windows steamclient libraries, which a prefix needs in C:\Program Files (x86)\Steam as on macOS: links
    # to the release's steam/ folder, beside this runtime's folder, so the archive holds them once.
    ln -s ../../steam/steamclient.dll ../../steam/steamclient64.dll "$STAGE/steam/"
    ditto "$LINUX/neptune/windows" "$STAGE/windows"
    cp -cR "$LINUX/debian-root/root" "$STAGE/root"
    stamp stage "$key"
}

build_zig
build_archives
build_lkd
build_neptune
build_d3dmetal_native
build_steam_client
build_sysroot
build_wine
build_steam
build_stage
echo "Linux engine runtime: $STAGE"
