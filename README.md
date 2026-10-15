# Voile

**The Windows runtime of [Obelisk](https://github.com/Zagrios/obelisk).** Voile runs Windows games on Apple silicon Macs, as Proton runs them for Steam on Linux.

This repository holds the recipe that builds the runtime from its pinned sources, and publishes it as releases. Obelisk downloads the release it pins with the first Windows game: players never need anything from here.

## Contents

- [What is inside](#what-is-inside)
- [Building](#building)
- [Using a development build](#using-a-development-build)
- [The Linux engine](#the-linux-engine)
- [How Obelisk runs a game](#how-obelisk-runs-a-game)
- [Releases](#releases)
- [Sources and pinning](#sources-and-pinning)
- [D3DMetal](#d3dmetal)
- [Tests](#tests)
- [License](#license)
- [Related repositories](#related-repositories)

## What is inside

Voile has two engines, and one release carries both.

| | macOS engine | Linux engine |
|---|---|---|
| **Runs** | Every Windows game by default | Games whose anti-cheat supports Linux, such as Easy Anti-Cheat in Rocket League and ELDEN RING |
| **Wine** | [voile-wine](https://github.com/Zagrios/voile-wine) built for macOS x86_64, under Rosetta | voile-wine built for Linux x86-64, run by [voile-lkd](https://github.com/Zagrios/voile-lkd) in native arm64 processes, with no virtual machine |
| **Direct3D** | Apple's D3DMetal (10, 11, 12) | [Neptune](https://github.com/Zagrios/neptune), rendering with DXMT (11) or D3DMetal (11, 12) |
| **Steam** | Proton's `lsteamclient` and `steam.exe`, with Valve's `steamclient` libraries | The same, with Valve's Linux `steamclient.so` |
| **Built by** | `scripts/build.sh` | `scripts/build-linux.sh` |

The macOS engine also ships FreeType and GnuTLS, which backs Windows HTTPS, built for x86_64 beside Wine's unix libraries, and Wine Mono for .NET games. Both engines share `obelisk-input`, voile-lkd's gamepad service, which voile-wine's `winebus.sys` reads.

## Building

You need a Mac with Apple silicon, Rosetta and Xcode.

```sh
git clone --recursive https://github.com/Zagrios/voile.git
cd voile
brew install bison cmake meson ninja pkgconf
brew install llvm@15 zstd            # for DXMT, in the Linux engine
python3 -m pip install mako pyyaml packaging   # for Neptune, in the Linux engine
./scripts/build.sh                   # the macOS engine, in build/stage
```

The build downloads the llvm-mingw cross compiler itself. Wine is built for x86_64 and runs under Rosetta, since it executes the game's x86 code in its own process. Each step reruns only when its inputs change.

## Using a development build

Run a program against a development prefix in `build/prefix`:

```sh
./scripts/wine-dev.sh winecfg
```

To launch Windows games from a development build of Obelisk, install the runtime where Obelisk looks for it, then run Obelisk from its own checkout:

```sh
./scripts/install-dev.sh             # into Obelisk's <library>/Voile/current
```

`Voile/current` takes precedence over the release Obelisk pins. A `winedebug` file at the root of an installed runtime replaces Obelisk's default Wine debug channels, for example `err+all,+steamclient`. Obelisk writes Wine's output to `~/Library/Logs/Obelisk/<store>/`, such as `Steam/wine-<appid>.log`.

## The Linux engine

Games whose anti-cheat supports Linux run through voile-wine built for x86-64 **Linux**, which voile-lkd runs in native macOS arm64 processes: FEXCore translates the x86-64 code and LKD serves the Linux system calls, with no virtual machine. The anti-cheat loads its Linux module. Obelisk picks this engine for the games it knows need it.

### Building it

```sh
./scripts/build.sh                   # first: its Wine tools and llvm-mingw build the Linux Wine
./scripts/build-linux.sh             # result in build/linux/stage
```

voile-lkd, Neptune and DXMT build from their submodules like Wine, in their own checkouts, and lose their debug information on the way into the stage. DXMT links LLVM 15 from Homebrew's `llvm@15`, with zstd and libunwind, statically: its library needs only macOS, and the build stops if it links anything else. Its Metal shaders need Xcode's Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`). `package.sh` lays the Linux engine in the release's `linux` folder, so one download holds both engines. `install-dev.sh` installs a development build in `<library>/Voile/current/linux` when it is built.

### What it holds

| Folder | Contents |
|---|---|
| `wine/` | voile-wine (the `wine` submodule) cross-built for Linux by `build-linux.sh`, with zig and llvm-mingw. Its Linux-only drivers talk to wsd: `wineobelisk.drv` (display, input), `wineobeliskaudio.drv` (audio), `nptunix` (Direct3D frames). Proton's `lsteamclient` (`lsteamclient.dll` and `lsteamclient.so`) and `steam.exe` are built into it like the macOS runtime's. |
| `engine/` | `fexdarwin-run`, `wsd`, `wsdctl`, `obelisk-input` and `run-with-timeout.sh` from the `voile-lkd` submodule, built by `build-linux.sh`. |
| `graphics/` | Neptune's render server (`virgl_test_server`, `virgl_render_server`) for arm64, built from the `neptune` submodule, and DXMT's `dxmt-native.framework`, built from the `dxmt` submodule. |
| `graphics/x86_64/` | The same render server for x86_64, which runs under Rosetta, and UTM's [d3dmetal-native](https://github.com/utmapp/d3dmetal-native) (`lib/libd3dmetal-native.dylib`, MIT, the pinned `d3dmetal-native` source with `patches/d3dmetal-native`), which hosts Apple's D3DMetal in it. D3DMetal is x86_64 only. The backend loads the runtime's own `lib/external/D3DMetal.framework`, unmodified: the Linux engine has no copy. |
| `steam/` | Valve's Linux `steamclient.so` and `crashhandler.so` in `linux64/`, from the `steam-linux` package of Valve's client CDN (`bins_sdk_ubuntu12`, the build of Obelisk's macOS `steamclient.dylib`), unmodified. `steamclient.dll` and `steamclient64.dll` are links to the release's `steam/` folder. |
| `guest/` | `steam-hostpid.so`, from voile-lkd, built with zig. Preloaded in the guest, it makes Valve's `steamclient.so` report the macOS pid of its process, which Obelisk's Steam host checks. |
| `windows/` | Neptune's `d3d11.dll`, `dxgi.dll` and `d3d12.dll`, built from the `neptune` submodule, which a launch copies into the prefix (`WINEDLLOVERRIDES=d3d11,dxgi,d3d12=n`). |
| `root/` | The Debian trixie amd64 root the guest runs on, the `debian-root` archive (`linux/root`, `import-debian-root.sh`), plus `/etc/ld.so.preload`, which names `/opt/obelisk/steam-hostpid.so`. |

### How a launch assembles it

In what follows, `RUNTIME` is the Linux engine's runtime, the release's `linux` folder.

A launch starts wsd and the render server under a supervisor, with `RENDER_SERVER_EXEC_PATH=graphics/libexec/virgl_render_server`, `NPT_BACKEND=dxmt` and the DXMT library paths. It then starts `engine/fexdarwin-run` with `FEXDARWIN_LKD=1`, `FEXDARWIN_ROOT=root` read-only, and binds for `/opt/wine`, the home with the prefix, the game and `/run/obelisk` (wsd's socket folder). voile-lkd's `tools/dev/eac-run.py` and `docs/V1.md` describe a whole session.

**Direct3D 12** needs the D3DMetal backend, since DXMT has no Direct3D 12. The launch then starts `RUNTIME/graphics/x86_64/bin/virgl_test_server` with the same arguments instead of the arm64 one, and with:

```sh
RENDER_SERVER_EXEC_PATH="$RUNTIME/graphics/x86_64/libexec/virgl_render_server"
NPT_BACKEND=d3dmetal
NPT_D3D11_LIBRARY_PATH="$RUNTIME/graphics/x86_64/lib/libd3dmetal-native.dylib"   # and NPT_DXGI_, NPT_D3D12_
D3DMETAL_FRAMEWORK_PATH="$RUNTIME/../lib/external/D3DMetal.framework"
```

**Steam games** reach Obelisk's Steam host the way the macOS engine's do, through `steam.exe` and lsteamclient, whose Linux side loads `$HOME/.steam/sdk64/steamclient.so` in the guest.

- The launch binds `RUNTIME/steam` read-only (for example at `/opt/steam`) and points the guest home's `.steam/sdk64` at its `linux64` folder.
- The prefix gets `RUNTIME/steam/steamclient.dll` and `steamclient64.dll` in `C:\Program Files (x86)\Steam`, where the runtime's ntdll redirects them to lsteamclient.
- The launch binds `RUNTIME/guest` read-only at `/opt/obelisk`, or the host drops the game's connection. The root's `/etc/ld.so.preload` has glibc's loader preload `/opt/obelisk/steam-hostpid.so` in every guest process, even in a game that Easy Anti-Cheat starts without the launch's `LD_PRELOAD`. A launch without that bind still runs: the loader writes one `cannot be preloaded ... ignored` line for each process and goes on.

## How Obelisk runs a game

Each Windows installation gets its own prefix in Obelisk's `<library>/Prefixes`, named after the installation folder. Obelisk creates it on the first launch and copies Valve's `steamclient.dll` and `steamclient64.dll` into `C:\Program Files (x86)\Steam`.

The game starts behind Proton's `steam.exe`, and lsteamclient connects it to Obelisk's Steam host. The prefix's user folders stay inside it instead of linking to the Mac home, and Steam Auto-Cloud maps its Windows roots, such as `%WinAppDataLocalLow%`, into the prefix's `crossover` profile. Files a game writes through the SDK's RemoteStorage never enter the prefix: lsteamclient hands them to the macOS Steam engine, whose storage Obelisk syncs as for a macOS game.

## Releases

A release is a tag `v<CrossOver version>-<revision>`, such as `v26.3.0-1`. The revision counts the releases built on one CrossOver version.

```sh
./scripts/package.sh v26.3.0-1       # build/release/voile-v26.3.0-1.tar.xz and its .sha256
./scripts/publish.sh v26.3.0-1       # the GitHub release, tagged on the packaged commit
```

`package.sh` refuses uncommitted changes, builds both engines, and drops the debug information, which takes the runtime from about 1 GB to 400 MB. Before it finishes, it extracts the archive, runs the 64-bit and 32-bit `cmd.exe` in a new prefix, and runs `cmd` through the Linux engine. The archive holds one folder with:

- the runtime, with Valve's steamclient libraries in `steam/` and Wine Mono in `share/wine/mono`,
- D3DMetal, laid in after stripping so it stays unmodified, with Apple's notices in `licenses/d3dmetal`,
- the Linux engine in `linux/`, with its licenses in `licenses/linux`,
- the licenses of everything it ships, in `licenses/`,
- `runtime.json`, which names its CrossOver version, its voile, voile-wine and Proton commits, and in `linux` the Linux engine's parts.

A `-dev` suffix, such as `v26.3.0-13-dev`, packages a local build to try before a release; `publish.sh` refuses it. `publish.sh` needs the packaged commit pushed. It creates the tag when it is missing and refuses one on another commit. With `--draft`, the release stays a draft, and GitHub creates the tag when it is published.

The Release workflow does both on GitHub, from a clean checkout of `main` on an Apple silicon runner with macOS 27. Start it from the Actions tab with **Run workflow** and the version. It refuses a version that isn't `v<CrossOver version>-<revision>` or that already has a release, runs `package.sh`, and drafts the release with `publish.sh --draft`. Its notes name the components, then GitHub's generated notes since the previous runtime release follow. Check the draft, then publish it.

Obelisk pins the release it installs in its `crates/game-runtime/voile-release.json`, with the archive's size and SHA-256.

## Sources and pinning

- **Submodules**, pinned by commit, for the components that are git repositories and build from source:
  - `wine` is [voile-wine](https://github.com/Zagrios/voile-wine): CrossOver's open-source Wine on its `crossover` branch, Obelisk's changes as commits on `main`. Wine builds straight from this checkout, so a local edit rebuilds it. Its changes are commits there, never patches here.
  - `voile-lkd` is [voile-lkd](https://github.com/Zagrios/voile-lkd), the Linux engine's host programs, with FEX as its own submodule.
  - `neptune` is [Neptune](https://github.com/Zagrios/neptune), the Direct3D driver of the Linux engine and its render server.
  - `dxmt` is [Zagrios/dxmt](https://github.com/Zagrios/dxmt), Direct3D 11 on Metal for the render server: upstream DXMT, the commits of UTM's native backend it needs, and a Windows-layout `WCHAR`.
- **Archives**, pinned by URL and SHA-256 in `sources.json`: the CrossOver tarball for FreeType, GnuTLS and GMP, Nettle, Proton, Valve's steamclient libraries for Windows and Linux, Wine Mono and its license, D3DMetal, d3dmetal-native and llvm-mingw, and the Linux engine's zig, Debian root and Debian headers. A mismatch stops the build.
- **Patches**, `patches/<component>/NNNN-name.patch`, applied in order onto the sources of an archived component, today Proton's `lsteamclient` and UTM's `d3dmetal-native`. A patch that no longer applies stops the build.

Proton's `lsteamclient` and `steam_helper` keep their own licenses. They are downloaded at build time and never copied into this repository.

The `debian-root` archive, which this repository does not build, is imported like D3DMetal: its import script packs it into `build/downloads` and prints the release to publish and the checksum for `sources.json`.

## D3DMetal

D3DMetal translates Direct3D 10, 11 and 12 to Metal, for 64-bit games. The Game Porting Toolkit's license lets anyone distribute its Redistributables, the toolkit's `redist` folder, on their own: unmodified, for non-commercial purposes and with Apple's notices. Obelisk is free, so the runtime ships them that way.

Downloading the toolkit takes an Apple developer account, so this repository publishes the Redistributables as they are in a `d3dmetal-<version>` release, which `sources.json` pins. A new toolkit version becomes a new release:

```sh
./scripts/import-d3dmetal.sh ~/Downloads/Game_Porting_Toolkit_4.0_beta_2.dmg
```

The script packs `build/downloads/d3dmetal-4.0-beta2.tar.xz` and prints the command that publishes it, with the checksum `sources.json` then needs.

The build extracts D3DMetal into `build/d3dmetal`, apart from `build/stage`, which stays Wine's own. To run it locally:

```sh
OBELISK_GRAPHICS=d3dmetal ./scripts/wine-dev.sh game.exe
```

Wine searches its own `lib/wine` before `WINEDLLPATH`, so `wine-dev.sh` clones the runtime and lays D3DMetal's DLLs over Wine's. `CX_APPLEGPTK_LIBD3DSHARED_PATH` makes CrossOver's Wine preload `libd3dshared.dylib`, which D3DMetal's unix libraries need. `install-dev.sh` lays the same DLLs over the installed runtime.

## Tests

- `tests/d3d11-smoke.c` presents 120 frames and prints the adapter and feature level it got. wined3d stops at 10_1; D3DMetal reports "AMD Compatibility Mode" at 11_0.
- `tests/wow64-force-exec.c` is a 32-bit program that forces exec permission, as Wine's loader does for a module without NX_COMPAT, then makes a few syscalls and exits 0. A runtime that loses the syscall dispatcher page at that point dies with "stack overflow" instead.

## License

Everything in this repository is licensed under the GNU General Public License v3.0 (see `LICENSE`), except the patches in `patches/`, which keep the license of the code they patch. D3DMetal, which the runtime downloads and ships unmodified, keeps Apple's license. Every other component keeps its own license, shipped in the release's `licenses/` folder.

## Related repositories

| Repository | Role |
|---|---|
| [Obelisk](https://github.com/Zagrios/obelisk) | The Mac app: Steam, Epic Games and GOG libraries, downloads and launches |
| **Voile** | The Windows runtime Obelisk installs |
| [voile-wine](https://github.com/Zagrios/voile-wine) | The Wine inside Voile, for both engines |
| [voile-lkd](https://github.com/Zagrios/voile-lkd) | The Linux engine: x86-64 Linux programs in native macOS processes |
| [Neptune](https://github.com/Zagrios/neptune) | Direct3D for the Linux engine |
| [FEX](https://github.com/Zagrios/FEX) | FEX-Emu with its macOS port, which voile-lkd translates x86-64 code with |
| [dxmt](https://github.com/Zagrios/dxmt) | DXMT, Direct3D 11 on Metal, which Neptune's render server renders with |
