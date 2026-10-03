#!/bin/bash
# Packs the Debian root of the Linux engine (see linux/root) into the archive sources.json pins as "debian-root".
# The archive lands in build/downloads, where build-linux.sh finds it once sources.json names its checksum.
set -euo pipefail
RUNTIME="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$RUNTIME/build"
ROOT="${1:?Usage: $0 <Debian root folder> [name]}"
NAME="${2:-debian-root-trixie-$(date -r "$ROOT" +%Y%m%d)}"
[[ -x "$ROOT/lib64/ld-linux-x86-64.so.2" || -L "$ROOT/lib64/ld-linux-x86-64.so.2" ]] ||
    { echo "$ROOT is not an x86-64 Debian root" >&2; exit 1; }
mkdir -p "$WORK/downloads"
ARCHIVE="$WORK/downloads/$NAME.tar.xz"
STAGING="$WORK/debian-root-import"
rm -rf "$STAGING"
mkdir -p "$STAGING/$NAME"
cp -cR "$ROOT" "$STAGING/$NAME/root"
cp "$RUNTIME"/linux/root/lock*.json "$STAGING/$NAME/"
COPYFILE_DISABLE=1 tar --create --xz --options xz:compression-level=9,xz:threads=0 \
    --no-mac-metadata --no-xattrs --uid 0 --gid 0 --numeric-owner \
    --file "$ARCHIVE" -C "$STAGING" "$NAME"
rm -rf "$STAGING"
cat <<OUT
Debian root: $NAME
Archive: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))
SHA-256: $(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)

Publish it, then point sources.json's "debian-root" at it with this checksum:
  gh release create $NAME "$ARCHIVE" --title "$NAME" \\
    --notes "Debian trixie amd64 root of the Linux engine, extracted from the packages of linux/root/lock*.json."
  https://github.com/Zagrios/voile/releases/download/$NAME/$NAME.tar.xz
OUT
