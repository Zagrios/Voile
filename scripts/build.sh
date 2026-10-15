#!/bin/bash
# Builds Obelisk's Wine runtime from the wine submodule and the pinned inputs in
# sources.json. Each step reruns only when its inputs change.
set -euo pipefail
RUNTIME="$(cd "$(dirname "$0")/.." && pwd)"
WINE_SOURCES="$RUNTIME/wine"
WORK="$RUNTIME/build"
DOWNLOADS="$WORK/downloads"
SOURCES="$WORK/src"
PROTON_SOURCES="$WORK/src-proton"
GNOME_SOURCES="$WORK/src-gnome"
GLIB_SOURCES="$GNOME_SOURCES/glib"
DEPS="$WORK/deps"
FREETYPE_PREFIX="$DEPS/freetype"
GNUTLS_PREFIX="$DEPS/gnutls"
GSTREAMER_PREFIX="$DEPS/gstreamer"
MACOS_PKGCONFIG="$DEPS/macos/pkgconfig"
OBJECTS="$WORK/obj"
STAGE="$WORK/stage"
STEAM_WINDOWS="$WORK/steam-windows"
D3DMETAL="$WORK/d3dmetal"
TOOLCHAIN="$WORK/toolchain/llvm-mingw"
JOBS="$(sysctl -n hw.ncpu)"
export MACOSX_DEPLOYMENT_TARGET=26.0
# Build tools may stay arm64. Everything Wine loads is compiled for x86_64.
# llvm-mingw comes last: its bare clang must not shadow Xcode's.
export PATH="/opt/homebrew/opt/bison/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$TOOLCHAIN/bin"
# pkg-config sees only the x86_64 libraries built here and macOS's own, never
# Homebrew's arm64 ones.
export PKG_CONFIG_LIBDIR="$FREETYPE_PREFIX/lib/pkgconfig:$GNUTLS_PREFIX/lib/pkgconfig"
PKG_CONFIG_LIBDIR+=":$GSTREAMER_PREFIX/lib/pkgconfig:$MACOS_PKGCONFIG"

FREETYPE_OPTIONS=(-Dbrotli=disabled -Dbzip2=disabled -Dharfbuzz=disabled -Dpng=disabled
    -Dzlib=internal)
GNUTLS_OPTIONS=(--enable-shared --disable-static --with-included-libtasn1
    --with-included-unistring --without-p11-kit --without-idn --without-zlib --without-brotli
    --without-zstd --without-tpm --without-tpm2 --disable-tools --disable-doc --disable-tests
    --disable-cxx --disable-nls --disable-libdane --disable-openssl-compatibility)
GLIB_OPTIONS=(-Dtests=false -Dnls=disabled -Dlibelf=disabled -Dselinux=disabled
    -Dlibmount=disabled -Dglib_debug=disabled)
# The GStreamer plugins CrossOver ships, from which winegstreamer builds the
# pipelines behind Media Foundation, DirectShow and WMReader. macOS decodes:
# applemedia's vtdec (VideoToolbox) and atdec (AudioToolbox). Without FFmpeg,
# WMV and WMA demux but do not decode, as in CrossOver.
GSTREAMER_PLUGINS=(coreelements audioconvert audioresample opengl playback typefindfunctions
    videoconvertscale audioparsers avi deinterlace id3demux isomp4 videofilter wavparse
    applemedia videoparsersbad asf)
# Each module builds only what those plugins need. Core keeps its tools, such as
# gst-inspect-1.0, for development: the runtime does not ship them.
GSTREAMER_MODULES=(
    "gstreamer -Dtools=enabled"
    "gst-plugins-base -Daudioconvert=enabled -Daudioresample=enabled -Dplayback=enabled
        -Dtypefind=enabled -Dvideoconvertscale=enabled -Dgl=enabled -Dgl_api=opengl
        -Dgl_platform=cgl -Dgl_winsys=cocoa"
    "gst-plugins-good -Daudioparsers=enabled -Davi=enabled -Ddeinterlace=enabled
        -Did3demux=enabled -Disomp4=enabled -Dvideofilter=enabled -Dwavparse=enabled"
    "gst-plugins-bad -Dapplemedia=enabled -Dvideoparsers=enabled -Dgl=enabled"
    "gst-plugins-ugly -Dasfdemux=enabled"
)
WINE_OPTIONS=(--enable-archs=i386,x86_64 --disable-tests --without-x --with-gstreamer
    --without-sdl --without-vulkan)
# Proton's Steam modules. Every other patches/ folder applies to the CrossOver tarball, except the Linux engine's,
# which build-linux.sh applies, and glib's, which applies to GNOME's release.
PROTON_COMPONENTS=(lsteamclient steam_helper)
LINUX_COMPONENTS=(d3dmetal-native)
GNOME_COMPONENTS=(glib)

fail() {
    echo "$*" >&2
    exit 1
}

arch -x86_64 /usr/bin/true 2>/dev/null || fail "Rosetta is required: softwareupdate --install-rosetta"
for tool in meson ninja pkg-config; do
    command -v "$tool" >/dev/null || fail "$tool is missing: brew install bison meson ninja pkgconf"
done
[[ "$(bison --version | head -1)" == *" 3."* ]] || fail "Bison 3 is missing: brew install bison"
[[ -f "$WINE_SOURCES/configure" ]] || fail "The wine submodule is missing: git submodule update --init"

field() {
    plutil -extract "$1.$2" raw -o - "$RUNTIME/sources.json"
}

verified() {
    [[ -f "$1" && "$(shasum -a 256 "$1" | cut -d' ' -f1)" == "$2" ]]
}

# Prints the path of a verified download, fetching it when missing or corrupt.
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

# A step's key names its inputs; the step is skipped while its key is unchanged.
current() {
    [[ -f "$WORK/stamps/$1" && "$(cat "$WORK/stamps/$1")" == "$2" ]]
}

stamp() {
    mkdir -p "$WORK/stamps"
    printf '%s' "$2" > "$WORK/stamps/$1"
}

is_proton_component() {
    [[ " ${PROTON_COMPONENTS[*]} " == *" $1 "* ]]
}

# The patch folders that apply to the CrossOver tarball.
crossover_components() {
    local directory
    for directory in "$RUNTIME"/patches/*/; do
        [[ -d "$directory" ]] || continue
        is_proton_component "$(basename "$directory")" && continue
        [[ " ${LINUX_COMPONENTS[*]} " == *" $(basename "$directory") "* ]] && continue
        [[ " ${GNOME_COMPONENTS[*]} " == *" $(basename "$directory") "* ]] && continue
        basename "$directory"
    done
}

# Hashes the names and contents of the named components' patches.
patches_key() {
    (
        cd "$RUNTIME"
        for component in "$@"; do
            if [[ -d "patches/$component" ]]; then
                find "patches/$component" -type f -name '*.patch'
            fi
        done | sort | while read -r patch; do
            echo "$patch"
            cat "$patch"
        done
    ) | shasum -a 256 | cut -d' ' -f1
}

# Applies patches/<component>/*.patch in order onto <root>/<component>.
apply_patches() {
    local root="$1" component patch
    shift
    for component in "$@"; do
        [[ -d "$RUNTIME/patches/$component" ]] || continue
        [[ -d "$root/$component" ]] || fail "No $component sources for its patches"
        for patch in "$RUNTIME/patches/$component"/*.patch; do
            [[ -f "$patch" ]] || continue
            patch -p1 -N -s -d "$root/$component" -i "$patch" || fail "$patch no longer applies"
        done
    done
}

# The deps rpaths only serve Wine's build tools, which run freetype while
# generating fonts. The runtime must not point back into this build tree.
strip_build_rpath() {
    local binary prefix changed
    for binary in "$STAGE"/bin/* "$STAGE"/lib/wine/x86_64-unix/*; do
        changed=false
        for prefix in "$FREETYPE_PREFIX" "$GNUTLS_PREFIX"; do
            if otool -l "$binary" 2>/dev/null | grep -q "path $prefix/lib ("; then
                install_name_tool -delete_rpath "$prefix/lib" "$binary"
                changed=true
            fi
        done
        if $changed; then
            codesign --force --sign - "$binary"
        fi
    done
}

build_toolchain() {
    local archive key
    archive="$(fetch llvm-mingw)"
    key="$(field llvm-mingw sha256)"
    current toolchain "$key" && return
    echo "==> llvm-mingw"
    rm -rf "$TOOLCHAIN"
    mkdir -p "$TOOLCHAIN"
    tar -xJf "$archive" -C "$TOOLCHAIN" --strip-components 1
    stamp toolchain "$key"
}

# The CrossOver tarball provides the libraries Wine links. Wine itself is the
# submodule, built from its checkout: Wine changes are commits in voile-wine,
# never patches here.
build_sources() {
    local archive components=()
    [[ ! -d "$RUNTIME/patches/wine" ]] || fail "Commit Wine changes to voile-wine instead of patches/wine"
    archive="$(fetch crossover)"
    while read -r component; do
        components+=("$component")
    done < <(crossover_components)
    SOURCES_KEY="$(field crossover sha256)-$(patches_key ${components[@]+"${components[@]}"})"
    # The checkout's commit and uncommitted changes, so a local edit rebuilds.
    WINE_SOURCE_KEY="$(git -C "$WINE_SOURCES" rev-parse HEAD)-$(git -C "$WINE_SOURCES" diff HEAD |
        shasum -a 256 | cut -c1-16)"
    current sources "$SOURCES_KEY" && return
    echo "==> CrossOver sources"
    rm -rf "$SOURCES"
    mkdir -p "$SOURCES"
    tar -xzf "$archive" -C "$SOURCES" --strip-components 1 --exclude 'sources/wine'
    apply_patches "$SOURCES" ${components[@]+"${components[@]}"}
    stamp sources "$SOURCES_KEY"
}

build_proton_sources() {
    local archive
    archive="$(fetch proton)"
    PROTON_KEY="$(field proton sha256)-$(patches_key "${PROTON_COMPONENTS[@]}")"
    current proton-sources "$PROTON_KEY" && return
    echo "==> Proton sources"
    rm -rf "$PROTON_SOURCES"
    mkdir -p "$PROTON_SOURCES"
    tar -xzf "$archive" -C "$PROTON_SOURCES" --strip-components 1 \
        --include '*/lsteamclient/*' --include '*/steam_helper/*'
    apply_patches "$PROTON_SOURCES" "${PROTON_COMPONENTS[@]}"
    stamp proton-sources "$PROTON_KEY"
}

# Meson builds x86_64 libraries with arm64 build tools. Rosetta runs the x86_64
# programs a build runs, such as its compiler checks.
cross_file() {
    cat > "$WORK/x86_64-darwin.ini" <<'EOF'
[binaries]
c = ['clang', '-arch', 'x86_64']
cpp = ['clang++', '-arch', 'x86_64']
objc = ['clang', '-arch', 'x86_64']
objcpp = ['clang++', '-arch', 'x86_64']
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'

[properties]
needs_exe_wrapper = false

[host_machine]
system = 'darwin'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
}

build_freetype() {
    FREETYPE_KEY="$(field crossover sha256)-$(patches_key freetype) ${FREETYPE_OPTIONS[*]}"
    current freetype "$FREETYPE_KEY" && return
    echo "==> freetype"
    cross_file
    rm -rf "$OBJECTS/freetype" "$FREETYPE_PREFIX"
    meson setup "$OBJECTS/freetype" "$SOURCES/freetype" --cross-file "$WORK/x86_64-darwin.ini" \
        --prefix "$FREETYPE_PREFIX" --libdir lib --buildtype release --default-library shared \
        "${FREETYPE_OPTIONS[@]}"
    meson install -C "$OBJECTS/freetype"
    # Wine dlopens freetype by this install name. Its unix libraries resolve
    # @rpath to their own folder, where the runtime keeps a copy.
    install_name_tool -id @rpath/libfreetype.6.dylib "$FREETYPE_PREFIX/lib/libfreetype.6.dylib"
    codesign --force --sign - "$FREETYPE_PREFIX/lib/libfreetype.6.dylib"
    stamp freetype "$FREETYPE_KEY"
}

# GnuTLS backs Wine's schannel, so Windows HTTPS works. GMP and Nettle link
# statically into it, and the runtime ships gnutls alone, beside freetype.
# CrossOver's tarball lacks Nettle's Makefile.in, so Nettle comes from GNU.
build_gnutls() {
    local archive
    archive="$(fetch nettle)"
    GNUTLS_KEY="$(field crossover sha256)-$(field nettle sha256)-$(patches_key gnutls)"
    GNUTLS_KEY+=" ${GNUTLS_OPTIONS[*]}"
    current gnutls "$GNUTLS_KEY" && return
    echo "==> gnutls"
    local root="$SOURCES/gnutls" component
    local host=(--build=x86_64-apple-darwin --host=x86_64-apple-darwin --prefix="$GNUTLS_PREFIX")
    local flags=(CC="clang -arch x86_64" CPPFLAGS="-I$GNUTLS_PREFIX/include"
        LDFLAGS="-L$GNUTLS_PREFIX/lib")
    rm -rf "$GNUTLS_PREFIX"
    for component in gmp nettle gnutls; do
        rm -rf "$OBJECTS/$component"
        mkdir -p "$OBJECTS/$component"
    done
    tar -xzf "$archive" -C "$OBJECTS/nettle" --strip-components 1
    (
        cd "$OBJECTS/gmp"
        "$root/gmp/configure" "${host[@]}" --disable-shared --enable-static --with-pic \
            --disable-assembly "${flags[@]}"
        make -j"$JOBS"
        make install
    )
    (
        cd "$OBJECTS/nettle"
        ./configure "${host[@]}" --disable-shared --disable-assembler \
            --disable-documentation --disable-openssl "${flags[@]}"
        make -j"$JOBS"
        make install
    )
    (
        cd "$OBJECTS/gnutls"
        # Static hogweed needs nettle and gmp on every link, configure's checks included.
        "$root/gnutls/configure" "${host[@]}" "${GNUTLS_OPTIONS[@]}" "${flags[@]}" \
            LIBS="-lnettle -lgmp"
        make -j"$JOBS"
        make install
    )
    # Like freetype, Wine dlopens gnutls by its leaf name from its unix libraries.
    install_name_tool -id @rpath/libgnutls.30.dylib "$GNUTLS_PREFIX/lib/libgnutls.30.dylib"
    codesign --force --sign - "$GNUTLS_PREFIX/lib/libgnutls.30.dylib"
    stamp gnutls "$GNUTLS_KEY"
}

# GStreamer backs winegstreamer: Media Foundation, DirectShow and WMReader, so
# games play their videos. GStreamer comes from the CrossOver tarball. glib is
# GNOME's latest release of the series that tarball carries, which also holds
# its gvdb subproject, built with the pcre2 and proxy-libintl its wraps name.
# macOS provides libffi, zlib and iconv.
build_gstreamer() {
    local glib pcre2 pcre2_build proxy_libintl module words name
    glib="$(fetch glib)"
    pcre2="$(fetch pcre2)"
    pcre2_build="$(fetch pcre2-meson)"
    proxy_libintl="$(fetch proxy-libintl)"
    GSTREAMER_KEY="$(field crossover sha256)-$(field glib sha256)-$(field pcre2 sha256)"
    GSTREAMER_KEY+="-$(field pcre2-meson sha256)-$(field proxy-libintl sha256)"
    GSTREAMER_KEY+="-$(patches_key "${GNOME_COMPONENTS[@]}")"
    GSTREAMER_KEY+=" ${GLIB_OPTIONS[*]} ${GSTREAMER_MODULES[*]}"
    current gstreamer "$GSTREAMER_KEY" && return
    echo "==> GStreamer"
    cross_file
    rm -rf "$GSTREAMER_PREFIX" "$MACOS_PKGCONFIG"
    mkdir -p "$MACOS_PKGCONFIG"
    # macOS keeps libffi in /usr/lib, with its headers in the SDK, but no .pc file.
    cat > "$MACOS_PKGCONFIG/libffi.pc" <<EOF
Name: libffi
Description: macOS's libffi
Version: 3.4.0
Cflags: -I$(xcrun --show-sdk-path)/usr/include/ffi
Libs: -lffi
EOF
    # glib's wraps find their archives in its packagecache, under the names
    # pcre2.wrap gives them, and proxy-libintl in its folder, so meson
    # downloads nothing.
    local subprojects="$GLIB_SOURCES/subprojects"
    rm -rf "$GLIB_SOURCES"
    mkdir -p "$GLIB_SOURCES"
    tar -xJf "$glib" -C "$GLIB_SOURCES" --strip-components 1
    apply_patches "$GNOME_SOURCES" "${GNOME_COMPONENTS[@]}"
    mkdir -p "$subprojects/packagecache" "$subprojects/proxy-libintl"
    cp "$pcre2" "$subprojects/packagecache/pcre2-10.42.tar.bz2"
    cp "$pcre2_build" "$subprojects/packagecache/pcre2_10.42-2_patch.zip"
    tar -xzf "$proxy_libintl" -C "$subprojects/proxy-libintl" --strip-components 1
    rm -rf "$OBJECTS/glib"
    meson setup "$OBJECTS/glib" "$GLIB_SOURCES" --cross-file "$WORK/x86_64-darwin.ini" \
        --prefix "$GSTREAMER_PREFIX" --libdir lib --buildtype release --default-library shared \
        --wrap-mode nodownload --force-fallback-for libpcre2-8,intl "${GLIB_OPTIONS[@]}"
    meson install -C "$OBJECTS/glib"
    # The modules run glib's tools, such as glib-mkenums, from PATH.
    for module in "${GSTREAMER_MODULES[@]}"; do
        read -r -d '' -a words <<< "$module" || true
        name="${words[0]}"
        rm -rf "$OBJECTS/$name"
        PATH="$GSTREAMER_PREFIX/bin:$PATH" meson setup "$OBJECTS/$name" \
            "$SOURCES/gstreamer/subprojects/$name" --cross-file "$WORK/x86_64-darwin.ini" \
            --prefix "$GSTREAMER_PREFIX" --libdir lib --buildtype release --default-library shared \
            --wrap-mode nodownload -Dauto_features=disabled "${words[@]:1}"
        PATH="$GSTREAMER_PREFIX/bin:$PATH" meson install -C "$OBJECTS/$name"
    done
    stamp gstreamer "$GSTREAMER_KEY"
}

# Lays GStreamer beside Wine: the plugins in lib/gstreamer-1.0, which GStreamer
# finds from its own library, and the libraries winegstreamer and the plugins
# load in lib. Each finds the others through @rpath, never in this build tree.
# The stage is rebuilt with Wine, so GStreamer goes back in after each Wine build.
lay_gstreamer() {
    local key="$WINE_KEY ${GSTREAMER_PLUGINS[*]}"
    current gstreamer-stage "$key" && return
    echo "==> GStreamer in the runtime"
    local plugins="$STAGE/lib/gstreamer-1.0" plugin binary dependency leaf
    local pending=("$STAGE/lib/wine/x86_64-unix/winegstreamer.so") laid=()
    rm -rf "$plugins" "$STAGE"/lib/*.dylib
    mkdir -p "$plugins"
    for plugin in "${GSTREAMER_PLUGINS[@]}"; do
        cp "$GSTREAMER_PREFIX/lib/gstreamer-1.0/libgst$plugin.dylib" "$plugins/"
        pending+=("$plugins/libgst$plugin.dylib")
    done
    laid=("${pending[@]}")
    while ((${#pending[@]})); do
        binary="${pending[0]}"
        pending=("${pending[@]:1}")
        while read -r dependency; do
            leaf="${dependency##*/}"
            [[ -f "$STAGE/lib/$leaf" || -f "$STAGE/lib/wine/x86_64-unix/$leaf" ]] && continue
            [[ -f "$GSTREAMER_PREFIX/lib/$leaf" ]] ||
                fail "${binary##*/} links $dependency, which the GStreamer build lacks"
            cp "$GSTREAMER_PREFIX/lib/$leaf" "$STAGE/lib/$leaf"
            pending+=("$STAGE/lib/$leaf")
            laid+=("$STAGE/lib/$leaf")
        done < <(linked_libraries "$binary" | grep -v -E '^(/System/|/usr/lib/)')
    done
    for binary in "${laid[@]}"; do
        case "$binary" in
            */x86_64-unix/*) relink "$binary" @loader_path/../.. ;;
            "$plugins"/*) relink "$binary" @loader_path/.. ;;
            *) relink "$binary" @loader_path ;;
        esac
    done
    stamp gstreamer-stage "$key"
}

# The libraries a Mach-O file loads, as its load commands name them.
linked_libraries() {
    otool -l "$1" | awk '/cmd LC_(LOAD|LOAD_WEAK|REEXPORT)_DYLIB$/ { getline; getline; print $2 }'
}

# Makes one laid file name itself and the GStreamer libraries it links by
# @rpath, and find them from `rpath` instead of this build tree. The rpaths it
# had relative to itself stay, such as winegstreamer.so's to Wine's ntdll.so.
relink() {
    local binary="$1" rpath="$2" dependency path rpaths arguments=()
    if otool -l "$binary" | grep -q 'cmd LC_ID_DYLIB$'; then
        arguments+=(-id "@rpath/${binary##*/}")
    fi
    while read -r dependency; do
        if [[ "$dependency" == "$GSTREAMER_PREFIX"/* ]]; then
            arguments+=(-change "$dependency" "@rpath/${dependency##*/}")
        fi
    done < <(linked_libraries "$binary")
    rpaths="$(otool -l "$binary" | awk '/cmd LC_RPATH$/ { getline; getline; print $2 }')"
    while read -r path; do
        [[ "$path" == /* ]] && arguments+=(-delete_rpath "$path")
    done <<< "$rpaths"
    grep -q -x -F "$rpath" <<< "$rpaths" || arguments+=(-add_rpath "$rpath")
    ((${#arguments[@]})) && install_name_tool "${arguments[@]}" "$binary"
    codesign --force --sign - "$binary"
    if otool -l "$binary" | tail -n +2 | grep -q "$WORK"; then
        fail "${binary##*/} still points into the build tree"
    fi
}

build_wine() {
    WINE_KEY="$WINE_SOURCE_KEY $FREETYPE_KEY $GNUTLS_KEY $GSTREAMER_KEY ${WINE_OPTIONS[*]}"
    current wine "$WINE_KEY" && return
    echo "==> Wine $(git -C "$WINE_SOURCES" rev-parse --short=12 HEAD)"
    rm -rf "$OBJECTS/wine" "$STAGE"
    mkdir -p "$OBJECTS/wine"
    # Build and host are both x86_64: Wine's own build tools run under Rosetta
    # and share the architecture of every Mac library the runtime links.
    (
        cd "$OBJECTS/wine"
        "$WINE_SOURCES/configure" --build=x86_64-apple-darwin --host=x86_64-apple-darwin \
            --prefix="$STAGE" "${WINE_OPTIONS[@]}" \
            CC="clang -arch x86_64" CXX="clang++ -arch x86_64" \
            LDFLAGS="-Wl,-rpath,$FREETYPE_PREFIX/lib -Wl,-rpath,$GNUTLS_PREFIX/lib" \
            FREETYPE_CFLAGS="-I$FREETYPE_PREFIX/include/freetype2" \
            FREETYPE_LIBS="-L$FREETYPE_PREFIX/lib -lfreetype" \
            GNUTLS_CFLAGS="-I$GNUTLS_PREFIX/include" GNUTLS_LIBS="-L$GNUTLS_PREFIX/lib -lgnutls"
        make -j"$JOBS"
        make install-lib
    )
    strip_build_rpath
    cp "$FREETYPE_PREFIX/lib/libfreetype.6.dylib" "$GNUTLS_PREFIX/lib/libgnutls.30.dylib" \
        "$STAGE/lib/wine/x86_64-unix/"
    stamp wine "$WINE_KEY"
}

# Builds one of Proton's modules against this Wine the way Proton's
# make/rules-makedep.mk does: Wine's own Makefile variables, the module as the
# only subdirectory, and Wine's makedep for the rules. It installs into the stage.
# winebase.h turns strncpy and wcsncpy into errors, and minwindef.h defines min
# and max. macOS's libc++ declares them after Wine's headers, so the libc
# headers come first and NOMINMAX drops the macros.
build_proton_module() {
    local name="$1" objects="$OBJECTS/$1"
    echo "==> $name"
    rm -rf "$objects"
    mkdir -p "$objects"
    sed -e "1i\\
UNIX_LIBS = $OBJECTS/wine/dlls/ntdll/ntdll.so
" -e '/^all:$/,$c\
all:' -e "/^SUBDIRS/,/[^\\\\]\$/c\\
SUBDIRS = $PROTON_SOURCES/$name" -e "/^srcdir/a\\
objdir = $OBJECTS/wine" -e "/^toolsdir/c\\
toolsdir = $OBJECTS/wine" -e '/^TOP_INSTALL_LIB/c\
TOP_INSTALL_LIB =' -e '/^CXXFLAGS/s/$/ -std=c++17 -include string.h -include wchar.h -DNOMINMAX/' \
        "$OBJECTS/wine/Makefile" > "$objects/Makefile"
    touch "$objects/config.status"
    (
        cd "$objects"
        "$OBJECTS/wine/tools/makedep"
        make -j"$JOBS"
        make install-lib
    )
}

build_steam() {
    local key="$WINE_KEY $PROTON_KEY"
    current steam "$key" && return
    build_proton_module lsteamclient
    build_proton_module steam_helper
    strip_build_rpath
    stamp steam "$key"
}

# Valve's own Windows steamclient libraries. Games load them from the prefix,
# and the runtime's ntdll redirects their exports to lsteamclient.
build_steam_windows() {
    local archive key
    archive="$(fetch steam-windows)"
    key="$(field steam-windows sha256)"
    current steam-windows "$key" && return
    echo "==> Valve steamclient"
    rm -rf "$STEAM_WINDOWS"
    mkdir -p "$STEAM_WINDOWS"
    unzip -q -o "$archive" steamclient.dll steamclient64.dll -d "$STEAM_WINDOWS"
    stamp steam-windows "$key"
}

# Wine Mono runs .NET games. mscoree finds the version it expects in the
# runtime's data directory, so no prefix installs it. The stage is rebuilt with
# Wine, so Mono goes back in after each Wine build.
build_mono() {
    local archive key
    archive="$(fetch wine-mono)"
    fetch wine-mono-license >/dev/null
    key="$(field wine-mono sha256) $WINE_KEY"
    current wine-mono "$key" && return
    echo "==> Wine Mono"
    rm -rf "$STAGE/share/wine/mono"
    mkdir -p "$STAGE/share/wine/mono"
    tar -xJf "$archive" -C "$STAGE/share/wine/mono"
    stamp wine-mono "$key"
}

# D3DMetal stays out of the stage, which remains Wine's own: package.sh lays it
# over the runtime unmodified, and wine-dev.sh and install-dev.sh over theirs.
build_d3dmetal() {
    local archive key
    archive="$(fetch d3dmetal)"
    key="$(field d3dmetal sha256)"
    current d3dmetal "$key" && return
    echo "==> D3DMetal"
    rm -rf "$D3DMETAL"
    mkdir -p "$D3DMETAL"
    tar -xJf "$archive" -C "$D3DMETAL" --strip-components 1
    stamp d3dmetal "$key"
}

build_toolchain
build_sources
build_proton_sources
build_freetype
build_gnutls
build_gstreamer
build_wine
lay_gstreamer
build_steam
build_steam_windows
build_mono
build_d3dmetal
touch "$WORK/stamps"
echo "Wine runtime: $STAGE"
