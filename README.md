# Voile

Voile is the runtime [SailOver](https://github.com/Zagrios/sailover) runs Windows games with, as Steam runs them with Proton: [voile-wine](https://github.com/Zagrios/voile-wine), plus the pieces that ship beside it, GnuTLS, Proton's Steam bridge, Valve's steamclient libraries and Apple's D3DMetal. This repository holds the recipe. Its builds are the runtime SailOver installs.

Everything in this repository is licensed under the LGPL-2.1-or-later (see `LICENSE`). D3DMetal, which the runtime downloads and ships unmodified, keeps Apple's license.

## Building

```sh
git clone --recursive https://github.com/Zagrios/voile.git
brew install bison meson ninja pkgconf
./scripts/build.sh              # result in build/stage
./scripts/wine-dev.sh winecfg   # runs it against build/prefix
```

The build needs Apple silicon with Rosetta and Xcode. It downloads the llvm-mingw cross compiler itself. Wine is built for x86_64 and runs under Rosetta, since it executes the game's x86 code in its own process. FreeType and GnuTLS, which backs Windows HTTPS, are built for x86_64 too and ship beside Wine's unix libraries. Each step reruns only when its inputs change.

To launch Windows Steam games from a development build of SailOver, install the runtime where SailOver looks for it, then run SailOver from its own checkout:

```sh
./scripts/install-dev.sh        # into SailOver's <library>/Voile/current
```

A `winedebug` file at the root of an installed runtime replaces SailOver's default Wine debug channels, for example `err+all,+steamclient`. SailOver writes Wine's output to `~/Library/Logs/SailOver/Steam/wine-<appid>.log`.

## Releases

A release is a tag `v<CrossOver version>-<revision>`, such as `v26.3.0-1`. The revision counts the releases built on one CrossOver version.

```sh
./scripts/package.sh v26.3.0-1  # build/release/voile-v26.3.0-1.tar.xz and its .sha256
./scripts/publish.sh v26.3.0-1  # the GitHub release, tagged on the packaged commit
```

`package.sh` refuses uncommitted changes, builds, and drops the debug information, which takes the runtime from about 1 GB to 400 MB. The archive holds one folder with the runtime, Valve's steamclient libraries in `steam/`, the licenses of what it ships in `licenses/`, and `runtime.json`, which names its CrossOver version and its voile, voile-wine and Proton commits. It also holds D3DMetal, laid in after stripping so it stays unmodified, with Apple's notices in `licenses/d3dmetal`. Before it finishes, the script extracts the archive and runs the 64-bit and 32-bit `cmd.exe` in a new prefix.

`publish.sh` needs the packaged commit pushed. It creates the tag when it is missing and refuses one on another commit.

Once the repositories are public, pushing a tag runs both scripts in the Release workflow, on GitHub's `macos-26` runners, from a clean checkout. While they are private, the workflow skips itself: private repositories pay macOS minutes at ten times the Linux rate, and a full build outlasts the free ones.

## Inputs

- A component that is a git repository and builds from source is a submodule, pinned by commit:
  - `wine` is [voile-wine](https://github.com/Zagrios/voile-wine): CrossOver's open-source Wine on its `crossover` branch, SailOver's changes as commits on `main`. Wine builds straight from this checkout, so a local edit rebuilds it. Its changes are commits there, never patches here.
- `sources.json` pins every archive by URL and SHA-256: the CrossOver tarball for FreeType, GnuTLS and GMP, Nettle, Proton, Valve's steamclient libraries, D3DMetal and llvm-mingw. A mismatch stops the build.
- `patches/<component>/NNNN-name.patch` files are applied in order onto the sources of an archived component, today Proton's `lsteamclient`. A patch that no longer applies stops the build.
- Proton's `lsteamclient` and `steam_helper` keep their own licenses. They are downloaded at build time and never copied into this repository.

## How SailOver runs a game

Each Windows installation gets its own prefix in SailOver's `<library>/Prefixes`, named after the installation folder. SailOver creates it on the first launch and copies Valve's `steamclient.dll` and `steamclient64.dll` into `C:\Program Files (x86)\Steam`. The game starts behind Proton's `steam.exe`, and lsteamclient connects it to SailOver's Steam host. The prefix's user folders stay inside it instead of linking to the Mac home, and Steam Auto-Cloud maps its Windows roots, such as `%WinAppDataLocalLow%`, into the prefix's `crossover` profile. Files a game writes through the SDK's RemoteStorage never enter the prefix: lsteamclient hands them to the macOS Steam engine, whose storage SailOver syncs as for a macOS game.

## D3DMetal

D3DMetal translates Direct3D 10, 11 and 12 to Metal, for 64-bit games. The Game Porting Toolkit's license lets anyone distribute its Redistributables, the toolkit's `redist` folder, on their own: unmodified, for non-commercial purposes and with Apple's notices. SailOver is free, so the runtime ships them that way.

Downloading the toolkit takes an Apple developer account, so this repository publishes the Redistributables as they are in a `d3dmetal-<version>` release, and `sources.json` pins it. A new toolkit version becomes a new release:

```sh
./scripts/import-d3dmetal.sh ~/Downloads/Game_Porting_Toolkit_4.0_beta_2.dmg
```

The script packs `build/downloads/d3dmetal-4.0-beta2.tar.xz` and prints the command that publishes it, with the checksum `sources.json` then needs. While this repository is private, its releases need a signed-in download: `gh release download d3dmetal-4.0-beta2 -D build/downloads` fetches the archive before a build.

The build extracts D3DMetal into `build/d3dmetal`, apart from `build/stage`, which stays Wine's own. To run it locally:

```sh
SAILOVER_GRAPHICS=d3dmetal ./scripts/wine-dev.sh game.exe
```

Wine searches its own `lib/wine` before `WINEDLLPATH`, so `wine-dev.sh` clones the runtime and lays D3DMetal's DLLs over Wine's. `CX_APPLEGPTK_LIBD3DSHARED_PATH` makes CrossOver's Wine preload `libd3dshared.dylib`, which D3DMetal's unix libraries need. `install-dev.sh` lays the same DLLs over the installed runtime.

`tests/d3d11-smoke.c` presents 120 frames and prints the adapter and feature level it got. wined3d stops at 10_1; D3DMetal reports "AMD Compatibility Mode" at 11_0.
