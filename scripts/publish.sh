#!/bin/bash
# Publishes the archives package.sh and package-linux.sh made as the GitHub
# release of their version, tagged on the commit they were built from: the
# Windows runtime and the Linux engine's runtime, which SailOver downloads only
# for the games that need it.
set -euo pipefail
RUNTIME="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$RUNTIME/build"
VERSION="${1:-}"
NAME="voile-$VERSION"
MANIFEST="$WORK/package/$NAME/runtime.json"
ARCHIVE="$WORK/release/$NAME.tar.xz"
LINUX_NAME="voile-linux-$VERSION"
LINUX_MANIFEST="$WORK/package-linux/$LINUX_NAME/runtime.json"
LINUX_ARCHIVE="$WORK/release/$LINUX_NAME.tar.xz"

fail() {
    echo "$*" >&2
    exit 1
}

value() {
    plutil -extract "$1" raw -o - "${2:-$MANIFEST}"
}

[[ -n "$VERSION" ]] || fail "Usage: publish.sh v<CrossOver version>-<revision>"
[[ -f "$MANIFEST" && -f "$ARCHIVE" ]] || fail "Package it first: ./scripts/package.sh $VERSION"
(cd "$WORK/release" && shasum -a 256 -c -s "$NAME.tar.xz.sha256") ||
    fail "$ARCHIVE does not match its checksum"
[[ -f "$LINUX_MANIFEST" && -f "$LINUX_ARCHIVE" ]] ||
    fail "Package the Linux engine's runtime too: ./scripts/package-linux.sh $VERSION"
(cd "$WORK/release" && shasum -a 256 -c -s "$LINUX_NAME.tar.xz.sha256") ||
    fail "$LINUX_ARCHIVE does not match its checksum"
cd "$RUNTIME"
commit="$(value voile)"
[[ "$(value voile "$LINUX_MANIFEST")" == "$commit" ]] ||
    fail "The two archives were not packaged from the same commit"
gh api "repos/{owner}/{repo}/commits/$commit" --silent 2>/dev/null ||
    fail "Push $commit before publishing it"
# A tag that already exists, like the one that starts the Release workflow,
# must name the packaged commit.
if tagged="$(gh api "repos/{owner}/{repo}/commits/$VERSION" --jq .sha 2>/dev/null)"; then
    [[ "$tagged" == "$commit" ]] || fail "$VERSION is on $tagged, not on the packaged $commit"
fi
notes="CrossOver $(value crossover), Zagrios/voile-wine@$(value voile-wine),"
notes+=" ValveSoftware/Proton@$(value proton), D3DMetal from $(value d3dmetal)."
notes+=" Linux engine: voile-lkd@$(value voile-lkd "$LINUX_MANIFEST"), neptune@$(value neptune "$LINUX_MANIFEST"),"
notes+=" $(value dxmt "$LINUX_MANIFEST"), $(value debian-root "$LINUX_MANIFEST")."
gh release create "$VERSION" "$ARCHIVE" "$ARCHIVE.sha256" "$LINUX_ARCHIVE" "$LINUX_ARCHIVE.sha256" \
    --target "$commit" --title "$VERSION" --notes "$notes"
