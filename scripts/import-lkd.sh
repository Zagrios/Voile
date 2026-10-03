#!/bin/bash
# Builds voile-lkd (private) and packs its host programs into the archive sources.json pins as "lkd": the engine
# (fexdarwin-run: FEXCore and LKD), the window server (wsd, wsdctl) and the supervisor wrapper. The archive lands in
# build/downloads, where build-linux.sh finds it once sources.json names its checksum.
set -euo pipefail
RUNTIME="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$RUNTIME/build"
LKD="$(cd "${1:?Usage: $0 <voile-lkd checkout>}" && pwd)"
[[ -z "$(git -C "$LKD" status --porcelain)" ]] || { echo "$LKD has uncommitted changes" >&2; exit 1; }
COMMIT="$(git -C "$LKD" rev-parse HEAD)"
NAME="lkd-${COMMIT:0:12}"
"$LKD/build.sh"
STAGING="$WORK/lkd-import"
rm -rf "$STAGING"
mkdir -p "$STAGING/$NAME/bin" "$STAGING/$NAME/licenses" "$WORK/downloads"
cp "$LKD/fexdarwin/build/host/fexdarwin-run" "$LKD/wsd/bin/wsd" "$LKD/wsd/bin/wsdctl" \
    "$LKD/fexdarwin/scripts/run-with-timeout.sh" "$STAGING/$NAME/bin/"
# Debug information points into the build tree; the release keeps symbols out of the archive.
for binary in fexdarwin-run wsd wsdctl; do
    codesign --remove-signature "$STAGING/$NAME/bin/$binary" 2>/dev/null || true
    strip -S "$STAGING/$NAME/bin/$binary"
    codesign --sign - "$STAGING/$NAME/bin/$binary"
done
cp "$LKD/LICENSE" "$STAGING/$NAME/licenses/voile-lkd.txt"
{
    cat "$LKD/NOTICE"
    for notice in "$LKD"/lkd/NOTICE "$LKD"/lkd/src/*/NOTICE; do
        [[ -f "$notice" ]] && printf '\n----- %s\n' "${notice#"$LKD"/}" && cat "$notice"
    done
} > "$STAGING/$NAME/licenses/voile-lkd-notices.txt"
cp "$LKD/fex/LICENSE" "$STAGING/$NAME/licenses/fex.txt"
printf '{\n  "voile-lkd": "%s",\n  "fex": "%s"\n}\n' "$COMMIT" "$(git -C "$LKD/fex" rev-parse HEAD)" \
    > "$STAGING/$NAME/VERSION.json"
ARCHIVE="$WORK/downloads/$NAME.tar.xz"
COPYFILE_DISABLE=1 tar --create --xz --options xz:compression-level=9,xz:threads=0 \
    --no-mac-metadata --no-xattrs --uid 0 --gid 0 --numeric-owner \
    --file "$ARCHIVE" -C "$STAGING" "$NAME"
rm -rf "$STAGING"
cat <<OUT
voile-lkd: $COMMIT
Archive: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))
SHA-256: $(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)

Publish it, then point sources.json's "lkd" at it with this checksum:
  gh release create $NAME "$ARCHIVE" --title "voile-lkd ${COMMIT:0:12}" --notes "Linux engine host programs."
  https://github.com/Zagrios/voile/releases/download/$NAME/$NAME.tar.xz
OUT
