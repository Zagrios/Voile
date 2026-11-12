#!/bin/bash
# Writes the entry of the published release VERSION into voile-feed.json, the list of releases Obelisk picks its
# runtime from: the archive's URL, size and SHA-256, the date it was published, the contract its commit's CONTRACT
# names (1 for a release older than that file), and its notes, which Obelisk shows players before they take it; run it
# again once they change. A non-empty WITHDRAWN keeps the entry with that reason, which makes Obelisk leave the
# release; an empty one puts it back. A GitHub pre-release goes in `prereleases` rather than `releases`: only players
# who take beta releases run one, and an Obelisk older than that list never reads it. Run it again once the release
# becomes a pre-release or stops being one, and the entry moves. Entries stay sorted, newest first. Needs gh, jq and
# git, and the release's tag in this checkout.
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

[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-[0-9]+(\.beta[0-9]+)?$ ]] ||
    fail "$VERSION is not v<CrossOver version>-<revision>[.beta<n>]."

release="$(gh release view "$VERSION" -R "$REPOSITORY" --json isDraft,isPrerelease,publishedAt,assets,body)"
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

if [[ "$(jq -r .isPrerelease <<<"$release")" == true ]]; then
    list=prereleases
else
    list=releases
fi

[[ -f "$FEED" ]] || echo '{"format": 1, "releases": []}' > "$FEED"
# The entry leaves both lists, then joins its own; an empty pre-release list goes.
updated="$(jq -L "$HERE/scripts" --arg version "$VERSION" --arg list "$list" --argjson entry "$entry" '
    include "version";
    def newest_first: sort_by(.version | order) | reverse;
    .releases = [.releases[] | select(.version != $version)]
    | .prereleases = [(.prereleases // [])[] | select(.version != $version)]
    | .[$list] += [$entry]
    | .releases |= newest_first
    # A beta older than the newest release left is one no player is offered any more: Obelisk leaves a beta it
    # does not find in the feed by its name, as it leaves one the feed lists. A withdrawn one stays, so its players
    # leave it, and so does a pre-release with no beta name, which Obelisk could not tell from a release.
    | ([.releases[] | select(.withdrawn | not) | .version | order] | max) as $newest
    | .prereleases |= (map(select($newest == null or (.version | order) > $newest or .withdrawn != null
        or (.version | test("\\.beta[0-9]+$") | not))) | newest_first)
    | if .prereleases == [] then del(.prereleases) else . end' "$FEED")"
printf '%s\n' "$updated" > "$FEED"
jq -c --arg version "$VERSION" --arg list "$list" \
    '[(.[$list] // [])[] | select(.version == $version) | del(.notes) | {list: $list} + .] | first
        // {version: $version, list: $list, dropped: "older than the newest release"}' "$FEED"
