#!/bin/bash
# Writes the entry of the published release VERSION into voile-feed.json, the list of releases Obelisk picks its
# runtime from: the archive's URL, size and SHA-256, the date it was published, the contract its commit's CONTRACT
# names (1 for a release older than that file), and its notes, which Obelisk shows players before they take it; run it
# again once they change. A non-empty WITHDRAWN keeps the entry with that reason, which makes Obelisk leave the
# release; an empty one puts it back. Entries stay sorted, newest first. Needs gh, jq and git, and the release's tag in
# this checkout.
set -euo pipefail

VERSION="${1:?usage: feed.sh VERSION [WITHDRAWN]}"
WITHDRAWN="${2-}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
FEED="${FEED:-$HERE/voile-feed.json}"
REPOSITORY="${GITHUB_REPOSITORY:-Zagrios/Voile}"
ARCHIVE="voile-$VERSION.tar.xz"

fail() {
    echo "$*" >&2
    exit 1
}

[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]] || fail "$VERSION is not v<CrossOver version>-<revision>."

release="$(gh release view "$VERSION" -R "$REPOSITORY" --json isDraft,publishedAt,assets,body)"
[[ "$(jq -r .isDraft <<<"$release")" == false ]] || fail "$VERSION is still a draft: publish it first."
asset="$(jq -c --arg name "$ARCHIVE" '.assets[] | select(.name == $name)' <<<"$release")"
[[ -n "$asset" ]] || fail "$VERSION has no $ARCHIVE."
sha256="$(gh release download "$VERSION" -R "$REPOSITORY" -p "$ARCHIVE.sha256" -O - | awk '{print $1}')"
[[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || fail "$ARCHIVE.sha256 holds no SHA-256."
contract="$(git -C "$HERE" show "refs/tags/$VERSION:CONTRACT" 2>/dev/null | tr -d '[:space:]' || true)"
contract="${contract:-1}"
[[ "$contract" =~ ^[0-9]+$ ]] || fail "CONTRACT at $VERSION is not a number."

entry="$(jq -n \
    --arg version "$VERSION" \
    --argjson contract "$contract" \
    --arg published "$(jq -r '.publishedAt[0:10]' <<<"$release")" \
    --arg url "$(jq -r .url <<<"$asset")" \
    --argjson size "$(jq .size <<<"$asset")" \
    --arg sha256 "$sha256" \
    --arg notes "$(jq -r '.body | gsub("\r"; "")' <<<"$release")" \
    --arg withdrawn "$WITHDRAWN" \
    '{version: $version, contract: $contract, published: $published, url: $url, size: $size, sha256: $sha256,
      notes: $notes}
     + (if $withdrawn == "" then {} else {withdrawn: $withdrawn} end)')"

[[ -f "$FEED" ]] || echo '{"format": 1, "releases": []}' > "$FEED"
updated="$(jq --arg version "$VERSION" --argjson entry "$entry" '
    .releases = ([.releases[] | select(.version != $version)] + [$entry]
        | sort_by(.version | ltrimstr("v") | [splits("[.-]")] | map(tonumber)) | reverse)' "$FEED")"
printf '%s\n' "$updated" > "$FEED"
jq -c --arg version "$VERSION" '.releases[] | select(.version == $version) | del(.notes)' "$FEED"
