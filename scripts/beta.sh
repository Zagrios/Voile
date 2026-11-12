#!/bin/bash
# Decides Voile's automatic beta, which the Beta workflow builds every two hours: whether main, or the main of a
# submodule, changed since the highest version published, release or beta, beyond what a build never reads; and the
# version it takes: the next beta of that beta's revision, else of the next revision, such as v26.3.0-26.beta3 after
# the release v26.3.0-25 and its betas 1 and 2 (scripts/version.jq says how they order). A beta whose build failed is
# built again only once something changed, or when the workflow is run by hand ($GITHUB_EVENT_NAME
# workflow_dispatch). Prints `due`, `version` and `since` (that highest version's tag) as KEY=VALUE lines for
# $GITHUB_OUTPUT.
#
# With --notes SINCE, prints the beta's notes instead: the subject of each commit since the tag SINCE, Voile's own
# then each submodule's, up to what HEAD pins; the Release workflow writes them once it has moved the submodules.
#
# Needs gh, jq and git, and this checkout with its history and tags.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
REPOSITORY="${GITHUB_REPOSITORY:-Zagrios/Voile}"
MODULES=(wine voile-lkd neptune dxmt)
# What makes no beta: files a build never reads, and the scripts that only publish or set up a development runtime.
IGNORED=(
    ':(exclude)*.md'
    ':(exclude)voile-feed.json'
    ':(exclude)voile-feed.json.sig'
    ':(exclude).github'
    ':(exclude)scripts/beta.sh'
    ':(exclude)scripts/feed.sh'
    ':(exclude)scripts/feed-key.sh'
    ':(exclude)scripts/publish.sh'
    ':(exclude)scripts/install-dev.sh'
    ':(exclude)scripts/wine-dev.sh'
    ':(exclude)scripts/import-d3dmetal.sh'
    ':(exclude)scripts/import-debian-root.sh'
)
# The commits in which the Release workflow moves the submodules it builds: no change of their own.
BUILD_COMMITS=(--invert-grep "--grep=^Build v.* from the submodules' main$")

fail() {
    echo "$*" >&2
    exit 1
}

# The GitHub repository of submodule $1, as owner/name.
module_repository() {
    local url
    url="$(git -C "$HERE" config -f .gitmodules "submodule.$1.url")"
    url="${url%.git}"
    echo "${url#https://github.com/}"
}

# The subjects of the commits of submodule $1 from $2 to $3, as Markdown list items.
module_commits() {
    gh api "repos/$(module_repository "$1")/compare/$2...$3" \
        --jq '.commits[] | "- " + (.commit.message | split("\n")[0]) + " (" + .sha[0:7] + ")"'
}

notes() {
    local since="$1" commits module old new
    echo "Automatic beta, built from main at $(git -C "$HERE" rev-parse --short HEAD). Changes since $since:"
    commits="$(git -C "$HERE" log --no-merges "${BUILD_COMMITS[@]}" --format='- %s (%h)' "$since..HEAD" -- . \
        "${IGNORED[@]}")"
    [[ -z "$commits" ]] || printf '\n### Voile\n\n%s\n' "$commits"
    for module in "${MODULES[@]}"; do
        old="$(git -C "$HERE" rev-parse "$since:$module")" new="$(git -C "$HERE" rev-parse "HEAD:$module")"
        [[ "$old" != "$new" ]] || continue
        printf '\n### %s\n\n%s\n' "$(module_repository "$module")" "$(module_commits "$module" "$old" "$new")"
    done
}

if [[ "${1:-}" == --notes ]]; then
    notes "${2:?usage: beta.sh --notes SINCE}"
    exit 0
fi

# Every release, drafts too, through GitHub's GraphQL API, which sends only these fields.
releases="$(gh release list -R "$REPOSITORY" --limit 10000 --json tagName,isDraft,publishedAt)"
# The highest version players can have: the beta's notes and changes start there.
since="$(jq -L "$HERE/scripts" -r 'include "version"; [.[] | select((.isDraft | not) and (.tagName | order) != null)]
    | sort_by(.tagName | order) | last | .tagName // empty' <<<"$releases")"
[[ -n "$since" ]] || fail "No runtime release to start from."
git -C "$HERE" rev-parse --quiet --verify "refs/tags/$since^{commit}" > /dev/null ||
    fail "Tag $since is not in this checkout: fetch it with its history."

# The revision whose betas come next: that of the newest beta, else the one after the newest release. The revision
# counts the releases of one CrossOver version, so a CrossOver that sources.json moved starts again at 1.
crossover="$(basename "$(jq -r .crossover.url "$HERE/sources.json")" .tar.gz)"
crossover="${crossover#crossover-sources-}"
if [[ "$since" == *.beta* ]]; then
    next="${since%.beta*}"
else
    next="${since%-*}-$(( ${since##*-} + 1 ))"
fi
[[ "$next" == "v$crossover-"* ]] || next="v$crossover-1"
# A deleted release leaves its tag: its number is never used again.
beta="$( { jq -r '.[].tagName' <<<"$releases"; git -C "$HERE" tag -l "$next.beta*"; } |
    sed -n "s/^${next//./\\.}\\.beta\\([0-9][0-9]*\\)$/\\1/p" | sort -n | tail -n 1)"
version="$next.beta$(( ${beta:-0} + 1 ))"

# The newest change in the history between $1 and HEAD that a build reads.
changed_since() {
    git -C "$HERE" log -1 "${BUILD_COMMITS[@]}" --format=%H "$1..HEAD" -- . "${IGNORED[@]}"
}

# Sets HEAD_<module> to the commit the main of submodule $1 is at, asked of GitHub once.
module_head() {
    local name="HEAD_${1//-/_}" branch
    [[ -z "${!name:-}" ]] || return 0
    branch="$(git -C "$HERE" config -f .gitmodules "submodule.$1.branch" || echo main)"
    printf -v "$name" '%s' "$(gh api "repos/$(module_repository "$1")/commits/$branch" --jq .sha)"
}

# Whether the main of a submodule moved, in what a build reads, from the commit the revision $1 pins.
any_module_moved() {
    local module old head new files
    for module in "${MODULES[@]}"; do
        old="$(git -C "$HERE" rev-parse "$1:$module")"
        module_head "$module"
        head="HEAD_${module//-/_}"
        new="${!head}"
        [[ "$old" != "$new" ]] || continue
        # A comparison GitHub cannot make counts as a move.
        files="$(gh api "repos/$(module_repository "$module")/compare/$old...$new" --jq '.files[].filename')" ||
            return 0
        grep -qv '\.md$' <<<"$files" && return 0
    done
    return 1
}

# The newest Beta run on main after $1 whose build failed, or ran out of time, which GitHub calls cancelled, as JSON,
# if any. A run that failed before building, such as on a GitHub error, holds nothing back.
last_failed_build() {
    local runs id
    runs="$(gh run list -R "$REPOSITORY" --workflow beta.yml --branch main --limit 30 \
        --json databaseId,headSha,createdAt,conclusion \
        --jq ".[] | select((.conclusion == \"failure\" or .conclusion == \"cancelled\") and .createdAt > \"$1\")
            | @json")" || return 0
    while IFS= read -r run; do
        [[ -n "$run" ]] || continue
        id="$(jq -r .databaseId <<<"$run")"
        if [[ "$(gh api "repos/$REPOSITORY/actions/runs/$id/jobs" --jq '[.jobs[] | select(.name | startswith("build"))
            | .conclusion] | any(. == "failure" or . == "cancelled")' 2>/dev/null)" == true ]]; then
            echo "$run"
            return 0
        fi
    done <<<"$runs"
}

due=false
if [[ -n "$(changed_since "$since")" ]] || any_module_moved "$since"; then
    due=true
fi

# A beta that failed is not built again on the same code: only a change since that run started, in main or in a
# submodule's main, or a run started by hand builds again. The failed build committed the submodules it built before
# building, so a submodule's main moved beyond what main pins now is a change.
if [[ "$due" == true && "${GITHUB_EVENT_NAME:-}" != workflow_dispatch ]]; then
    published="$(jq -r --arg tag "$since" '.[] | select(.tagName == $tag) | .publishedAt' <<<"$releases")"
    failed="$(last_failed_build "$published")"
    if [[ -n "$failed" ]]; then
        head="$(jq -r .headSha <<<"$failed")"
        if git -C "$HERE" cat-file -e "$head^{commit}" 2>/dev/null && [[ -z "$(changed_since "$head")" ]] &&
            ! any_module_moved HEAD; then
            echo "The beta built from $head failed, and nothing changed since: run Beta by hand to try again." >&2
            due=false
        fi
    fi
fi
printf 'due=%s\nversion=%s\nsince=%s\n' "$due" "$version" "$since"
