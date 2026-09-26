#!/bin/bash
# Publishes the archive package.sh made as the GitHub release of its version,
# tagged on the commit it was built from.
set -euo pipefail
RUNTIME="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$RUNTIME/build"
VERSION="${1:-}"
NAME="voile-$VERSION"
MANIFEST="$WORK/package/$NAME/runtime.json"
ARCHIVE="$WORK/release/$NAME.tar.xz"

fail() {
    echo "$*" >&2
    exit 1
}

value() {
    plutil -extract "$1" raw -o - "$MANIFEST"
}

[[ -n "$VERSION" ]] || fail "Usage: publish.sh v<CrossOver version>-<revision>"
[[ -f "$MANIFEST" && -f "$ARCHIVE" ]] || fail "Package it first: ./scripts/package.sh $VERSION"
(cd "$WORK/release" && shasum -a 256 -c -s "$NAME.tar.xz.sha256") ||
    fail "$ARCHIVE does not match its checksum"
cd "$RUNTIME"
commit="$(value voile)"
gh api "repos/{owner}/{repo}/commits/$commit" --silent 2>/dev/null ||
    fail "Push $commit before publishing it"
# A tag that already exists, like the one that starts the Release workflow,
# must name the packaged commit.
if tagged="$(gh api "repos/{owner}/{repo}/commits/$VERSION" --jq .sha 2>/dev/null)"; then
    [[ "$tagged" == "$commit" ]] || fail "$VERSION is on $tagged, not on the packaged $commit"
fi
notes="CrossOver $(value crossover), Zagrios/voile-wine@$(value voile-wine),"
notes+=" ValveSoftware/Proton@$(value proton), D3DMetal from $(value d3dmetal)."
gh release create "$VERSION" "$ARCHIVE" "$ARCHIVE.sha256" --target "$commit" \
    --title "$VERSION" --notes "$notes"
