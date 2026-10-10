# Voile

Voile is the runtime [Obelisk](https://github.com/Zagrios/obelisk) runs Windows games with, as Steam runs them with Proton: [voile-wine](https://github.com/Zagrios/voile-wine), plus the pieces that ship beside it, GnuTLS, Proton's Steam bridge, Valve's steamclient libraries and Apple's D3DMetal. This repository holds the recipe. Its builds are the runtime Obelisk installs.

Everything in this repository is licensed under the LGPL-2.1-or-later (see `LICENSE`). D3DMetal, which the runtime downloads and ships unmodified, keeps Apple's license.

## Building

```sh
git clone --recursive https://github.com/Zagrios/voile.git
brew install bison cmake meson ninja pkgconf
python3 -m pip install mako pyyaml   # Neptune's build (the Linux engine)
./scripts/build.sh              # result in build/stage
./scripts/wine-dev.sh winecfg   # runs it against build/prefix
```

The build needs Apple silicon with Rosetta and Xcode. It downloads the llvm-mingw cross compiler itself. Wine is built for x86_64 and runs under Rosetta, since it executes the game's x86 code in its own process. FreeType and GnuTLS, which backs Windows HTTPS, are built for x86_64 too and ship beside Wine's unix libraries. Each step reruns only when its inputs change.

To launch Windows Steam games from a development build of Obelisk, install the runtime where Obelisk looks for it, then run Obelisk from its own checkout:

```sh
./scripts/install-dev.sh        # into Obelisk's <library>/Voile/current
```

A `winedebug` file at the root of an installed runtime replaces Obelisk's default Wine debug channels, for example `err+all,+steamclient`. Obelisk writes Wine's output to `~/Library/Logs/Obelisk/Steam/wine-<appid>.log`.

## The Linux engine

Games whose anti-cheat supports Linux (Easy Anti-Cheat on Rocket League) run through voile-wine built for x86-64
**Linux**, which voile-lkd's engine runs in native macOS arm64 processes: FEXCore translates the x86-64 code and
LKD serves the Linux system calls, with no virtual machine. The anti-cheat loads its Linux module. This runtime is
built and published apart from the macOS one.

| Part | Where it comes from |
|---|---|
| `wine/` | voile-wine (the `wine` submodule) cross-built for Linux by `build-linux.sh`, with zig and llvm-mingw. Its Linux-only drivers talk to wsd: `wineobelisk.drv` (display, input), `wineobeliskaudio.drv` (audio), `nptunix` (Direct3D frames). Proton's `lsteamclient` (`lsteamclient.dll` and `lsteamclient.so`) and `steam.exe` are built into it like the macOS runtime's. |
| `engine/` | `fexdarwin-run`, `wsd`, `wsdctl`, `run-with-timeout.sh` from voile-lkd (the private `voile-lkd` submodule), built by `build-linux.sh`. |
| `graphics/` | Neptune's render server (`virgl_test_server`, `virgl_render_server`) for arm64, built from the private `neptune` submodule, and DXMT, the `dxmt` archive (`import-dxmt.sh`). |
| `graphics/x86_64/` | The same render server for x86_64, which runs under Rosetta, and UTM's [d3dmetal-native](https://github.com/utmapp/d3dmetal-native) (`lib/libd3dmetal-native.dylib`, MIT, the pinned `d3dmetal-native` source), which hosts Apple's D3DMetal in it. D3DMetal is x86_64 only. The backend loads the runtime's own `lib/external/D3DMetal.framework`, unmodified: the Linux engine has no copy. |
| `steam/` | Valve's Linux `steamclient.so` and `crashhandler.so` in `linux64/`, from the `steam-linux` package of Valve's client CDN (`bins_sdk_ubuntu12`, the build of Obelisk's macOS `steamclient.dylib`), unmodified. `steamclient.dll` and `steamclient64.dll` are links to the release's `steam/` folder. |
| `guest/` | `steam-hostpid.so`, from voile-lkd, built with zig: preloaded in the guest (`LD_PRELOAD`), it makes Valve's `steamclient.so` report the macOS pid of its process, which Obelisk's Steam host checks. |
| `windows/` | Neptune's `d3d11.dll`, `dxgi.dll`, `d3d12.dll`, built from the `neptune` submodule, which a launch copies into the prefix (`WINEDLLOVERRIDES=d3d11,dxgi,d3d12=n`). |
| `root/` | The Debian trixie amd64 root the guest runs on, the `debian-root` archive (`linux/root`, `import-debian-root.sh`). |

```sh
./scripts/build.sh                       # first: its Wine tools and llvm-mingw build the Linux Wine
./scripts/build-linux.sh                 # result in build/linux/stage
```

It ships inside the release's archive, in its `linux` folder: `package.sh` builds it and lays it in, so one download
holds both runtimes. `install-dev.sh` installs a development build in
`<library>/Voile/current/linux` when it is built. A launch starts wsd and
the render server (`RENDER_SERVER_EXEC_PATH=graphics/libexec/virgl_render_server`, `NPT_BACKEND=dxmt` and the DXMT
library paths) under a supervisor, then `engine/fexdarwin-run` with `FEXDARWIN_LKD=1`, `FEXDARWIN_ROOT=root`
read-only and binds for `/opt/wine`, the home with the prefix, the game and `/run/obelisk` (wsd's socket folder).
voile-lkd's `tools/dev/eac-run.py` and `docs/V1.md` describe a whole session.

A Direct3D 12 game needs the D3DMetal backend: DXMT has no Direct3D 12. With `RUNTIME` the Linux engine's runtime
(the release's `linux` folder), the launch then starts `RUNTIME/graphics/x86_64/bin/virgl_test_server` with the same
arguments instead of the arm64 one, and with:

```sh
RENDER_SERVER_EXEC_PATH="$RUNTIME/graphics/x86_64/libexec/virgl_render_server"
NPT_BACKEND=d3dmetal
NPT_D3D11_LIBRARY_PATH="$RUNTIME/graphics/x86_64/lib/libd3dmetal-native.dylib"   # and NPT_DXGI_, NPT_D3D12_
D3DMETAL_FRAMEWORK_PATH="$RUNTIME/../lib/external/D3DMetal.framework"
```

A Steam game reaches Obelisk's Steam host the way the macOS runtime's do, through `steam.exe` and lsteamclient,
whose Linux side loads `$HOME/.steam/sdk64/steamclient.so` in the guest. The launch binds `RUNTIME/steam` read-only
(for example at `/opt/steam`) and points the guest home's `.steam/sdk64` at its `linux64` folder; the prefix gets
`RUNTIME/steam/steamclient.dll` and `steamclient64.dll` in `C:\Program Files (x86)\Steam`, where the runtime's ntdll
redirects them to lsteamclient. The guest also preloads `RUNTIME/guest/steam-hostpid.so` (bound read-only, for example at
`/opt/obelisk`, with `LD_PRELOAD=/opt/obelisk/steam-hostpid.so`), or the host drops the game's connection.

voile-lkd and Neptune build from their submodules like Wine, in their own checkouts, and lose their debug
information on the way into the stage. The `dxmt` and `debian-root` archives, which this repository does not build, are imported like
D3DMetal: each import script packs its part into build/downloads and prints the release to publish and the checksum
for `sources.json`.

## Releases

A release is a tag `v<CrossOver version>-<revision>`, such as `v26.3.0-1`. The revision counts the releases built on one CrossOver version.

```sh
./scripts/package.sh v26.3.0-1        # build/release/voile-v26.3.0-1.tar.xz and its .sha256
./scripts/publish.sh v26.3.0-1        # the GitHub release, tagged on the packaged commit
```

`package.sh` refuses uncommitted changes, builds, and drops the debug information, which takes the runtime from about 1 GB to 400 MB. The archive holds one folder with the runtime, Valve's steamclient libraries in `steam/`, Wine Mono for .NET games in `share/wine/mono`, the licenses of what it ships in `licenses/`, and `runtime.json`, which names its CrossOver version and its voile, voile-wine and Proton commits. It also holds D3DMetal, laid in after stripping so it stays unmodified, with Apple's notices in `licenses/d3dmetal`, and the Linux engine's runtime in `linux/`, with its licenses in `licenses/linux` and its parts in `runtime.json`'s `linux`. Before it finishes, the script extracts the archive, runs the 64-bit and 32-bit `cmd.exe` in a new prefix, and runs `cmd` through the Linux engine.

A `-dev` suffix, such as `v26.3.0-13-dev`, packages a local build to try before a release; `publish.sh` refuses it.

`publish.sh` needs the packaged commit pushed. It creates the tag when it is missing and refuses one on another commit.

Once the repositories are public, pushing a tag runs `package.sh` and `publish.sh` in the Release workflow, on GitHub's `macos-26` runners, from a clean checkout. While they are private, the workflow skips itself: private repositories pay macOS minutes at ten times the Linux rate, and a full build outlasts the free ones.

## Inputs

- A component that is a git repository and builds from source is a submodule, pinned by commit:
  - `wine` is [voile-wine](https://github.com/Zagrios/voile-wine): CrossOver's open-source Wine on its `crossover` branch, Obelisk's changes as commits on `main`. Wine builds straight from this checkout, so a local edit rebuilds it. Its changes are commits there, never patches here.
  - `voile-lkd` is [voile-lkd](https://github.com/Zagrios/voile-lkd), the Linux engine's host programs, with FEX as its own submodule.
  - `neptune` is [Neptune](https://github.com/Zagrios/neptune), the Direct3D driver of the Linux engine and its render server.
- `sources.json` pins every archive by URL and SHA-256: the CrossOver tarball for FreeType, GnuTLS and GMP, Nettle, Proton, Valve's steamclient libraries for Windows and Linux, Wine Mono and its license, D3DMetal, d3dmetal-native and llvm-mingw, and the Linux engine's zig, Debian root, Debian headers and DXMT. A mismatch stops the build.
- `patches/<component>/NNNN-name.patch` files are applied in order onto the sources of an archived component, today Proton's `lsteamclient`. A patch that no longer applies stops the build.
- Proton's `lsteamclient` and `steam_helper` keep their own licenses. They are downloaded at build time and never copied into this repository.

## How Obelisk runs a game

Each Windows installation gets its own prefix in Obelisk's `<library>/Prefixes`, named after the installation folder. Obelisk creates it on the first launch and copies Valve's `steamclient.dll` and `steamclient64.dll` into `C:\Program Files (x86)\Steam`. The game starts behind Proton's `steam.exe`, and lsteamclient connects it to Obelisk's Steam host. The prefix's user folders stay inside it instead of linking to the Mac home, and Steam Auto-Cloud maps its Windows roots, such as `%WinAppDataLocalLow%`, into the prefix's `crossover` profile. Files a game writes through the SDK's RemoteStorage never enter the prefix: lsteamclient hands them to the macOS Steam engine, whose storage Obelisk syncs as for a macOS game.

## D3DMetal

D3DMetal translates Direct3D 10, 11 and 12 to Metal, for 64-bit games. The Game Porting Toolkit's license lets anyone distribute its Redistributables, the toolkit's `redist` folder, on their own: unmodified, for non-commercial purposes and with Apple's notices. Obelisk is free, so the runtime ships them that way.

Downloading the toolkit takes an Apple developer account, so this repository publishes the Redistributables as they are in a `d3dmetal-<version>` release, and `sources.json` pins it. A new toolkit version becomes a new release:

```sh
./scripts/import-d3dmetal.sh ~/Downloads/Game_Porting_Toolkit_4.0_beta_2.dmg
```

The script packs `build/downloads/d3dmetal-4.0-beta2.tar.xz` and prints the command that publishes it, with the checksum `sources.json` then needs. While this repository is private, its releases need a signed-in download: `gh release download d3dmetal-4.0-beta2 -D build/downloads` fetches the archive before a build.

The build extracts D3DMetal into `build/d3dmetal`, apart from `build/stage`, which stays Wine's own. To run it locally:

```sh
OBELISK_GRAPHICS=d3dmetal ./scripts/wine-dev.sh game.exe
```

Wine searches its own `lib/wine` before `WINEDLLPATH`, so `wine-dev.sh` clones the runtime and lays D3DMetal's DLLs over Wine's. `CX_APPLEGPTK_LIBD3DSHARED_PATH` makes CrossOver's Wine preload `libd3dshared.dylib`, which D3DMetal's unix libraries need. `install-dev.sh` lays the same DLLs over the installed runtime.

`tests/d3d11-smoke.c` presents 120 frames and prints the adapter and feature level it got. wined3d stops at 10_1; D3DMetal reports "AMD Compatibility Mode" at 11_0.
