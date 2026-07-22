#!/usr/bin/env bash
# update.sh — check sources.toml against stable.json and open a PR for
# each package whose upstream GitHub release is newer than what's indexed.
#
# For each [[package]] in sources.toml:
#   1. Fetch the latest release of its upstream "repo" via the GitHub API.
#   2. Compare that release's version against stable.json's current entry
#      (missing entries count as outdated, i.e. "add this package").
#   3. If newer: download the release asset, repackage it with package.sh,
#      upload the tarball as a release asset on this repo, update
#      stable.json on a fresh branch, and open a PR.
#
# Usage:
#   ./update.sh [options]
#
# Options:
#   -n, --dry-run          Check for updates but don't download, package,
#                           push, or open anything.
#   -s, --sources FILE     Sources file (default: sources.toml).
#   -i, --index FILE       Index file to update (default: stable.json).
#   -h, --help             Show this help.
#
# Requires: curl, jq, tar, zstd, git, gh (authenticated), awk.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

usage() {
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
}

err() {
    echo "update.sh: $*" >&2
    exit 1
}

DRY_RUN=0
SOURCES_FILE="sources.toml"
INDEX_FILE="stable.json"

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run)  DRY_RUN=1; shift ;;
        -s|--sources)  SOURCES_FILE=$2; shift 2 ;;
        -i|--index)    INDEX_FILE=$2; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *) usage; err "unknown argument: $1" ;;
    esac
done

for cmd in curl jq tar zstd git gh awk; do
    command -v "$cmd" >/dev/null || err "$cmd not found"
done
[ -f "$SOURCES_FILE" ] || err "no such file: $SOURCES_FILE"
[ -f "$INDEX_FILE" ] || err "no such file: $INDEX_FILE"

if [ "$DRY_RUN" = "0" ]; then
    [ -z "$(git status --porcelain)" ] || err "working tree is dirty; commit or stash before running"
fi

gh_token=$(gh auth token 2>/dev/null || true)

# sources.toml -> JSON array of package tables. Deliberately not a general
# TOML parser: sources.toml only ever has flat string key = "value" pairs
# grouped under repeated [[package]] headers, so a small awk pass covers it
# without pulling in a TOML library or a specific Python/tomllib version.
sources_json=$(awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function jesc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    BEGIN { printf "[" }
    {
        line = $0
        sub(/#.*/, "", line)
        line = trim(line)
        if (line == "") next
        if (line == "[[package]]") {
            if (npkg > 0) printf "},"
            printf "{"
            npkg++
            nfield = 0
            next
        }
        if (npkg == 0) next
        eq = index(line, "=")
        if (eq == 0) next
        key = trim(substr(line, 1, eq - 1))
        val = trim(substr(line, eq + 1))
        gsub(/^"/, "", val)
        gsub(/"$/, "", val)
        if (nfield > 0) printf ","
        printf "\"%s\":\"%s\"", jesc(key), jesc(val)
        nfield++
    }
    END { if (npkg > 0) printf "}"; printf "]" }
' "$SOURCES_FILE")
echo "$sources_json" | jq empty || err "failed to parse $SOURCES_FILE (see sources.toml's format comment)"

repo_slug=$(git config --get remote.origin.url | sed -E 's#(git@github\.com:|https://github\.com/)##; s#\.git$##')
[ -n "$repo_slug" ] || err "could not determine this repo's owner/name from git remote 'origin'"

start_ref=$(git rev-parse --abbrev-ref HEAD)
[ "$start_ref" = "HEAD" ] && start_ref=$(git rev-parse HEAD)

updated=0
skipped=0

process_package() {
    local pkg_json=$1
    local name repo asset bin platform description version_prefix
    name=$(jq -r '.name // empty' <<<"$pkg_json")
    repo=$(jq -r '.repo // empty' <<<"$pkg_json")
    asset=$(jq -r '.asset // empty' <<<"$pkg_json")
    bin=$(jq -r '.bin // empty' <<<"$pkg_json")
    platform=$(jq -r '.platform // empty' <<<"$pkg_json")
    description=$(jq -r '.description // empty' <<<"$pkg_json")
    version_prefix=$(jq -r '.version_prefix // empty' <<<"$pkg_json")

    if [ -z "$name" ] || [ -z "$repo" ] || [ -z "$asset" ] || [ -z "$bin" ]; then
        echo "skip: sources.toml entry missing name/repo/asset/bin: $pkg_json" >&2
        return 1
    fi

    echo "== $name (upstream $repo) ==" >&2

    local auth=()
    [ -n "$gh_token" ] && auth=(-H "Authorization: Bearer $gh_token")

    local release_json
    if ! release_json=$(curl -fsSL "${auth[@]}" -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/$repo/releases/latest"); then
        echo "skip: $name: failed to fetch latest release for $repo" >&2
        return 1
    fi

    local tag_name latest_version
    tag_name=$(jq -r '.tag_name' <<<"$release_json")
    latest_version=${tag_name#"$version_prefix"}

    local current_version
    current_version=$(jq -r --arg n "$name" '.packages[]? | select(.name==$n) | .version // empty' "$INDEX_FILE")

    if [ -n "$current_version" ]; then
        if [ "$current_version" = "$latest_version" ]; then
            echo "up to date: $name $current_version" >&2
            return 0
        fi
        local newest
        newest=$(printf '%s\n%s\n' "$current_version" "$latest_version" | sort -V | tail -1)
        if [ "$newest" != "$latest_version" ]; then
            echo "skip: $name: upstream latest ($latest_version) is not newer than indexed ($current_version)" >&2
            return 0
        fi
    fi

    echo "outdated: $name ${current_version:-<not indexed>} -> $latest_version" >&2

    local asset_url
    asset_url=$(jq -r --arg a "$asset" '.assets[] | select(.name==$a) | .browser_download_url' <<<"$release_json")
    if [ -z "$asset_url" ]; then
        echo "skip: $name: release $tag_name has no asset named $asset" >&2
        return 1
    fi

    if [ "$DRY_RUN" = "1" ]; then
        echo "dry-run: would download $asset_url and open a PR updating $name to $latest_version" >&2
        return 0
    fi

    local branch="update/${name}-${latest_version}"
    if [ -n "$(gh pr list --repo "$repo_slug" --head "$branch" --state open --json number --jq '.[0].number' 2>/dev/null)" ]; then
        echo "skip: $name: an open PR already exists for $branch" >&2
        return 0
    fi

    local work bin_path
    work=$(mktemp -d)
    trap 'rm -rf "$work"' RETURN
    bin_path="$work/$asset"
    curl -fsSL -o "$bin_path" "$asset_url" || { echo "skip: $name: failed to download $asset_url" >&2; return 1; }
    chmod +x "$bin_path"

    local dist entry_json
    dist="$work/dist"
    entry_json=$("$SCRIPT_DIR/package.sh" "$bin_path" "$name" "$latest_version" \
        --bin-name "$bin" \
        ${platform:+--platform "$platform"} \
        ${description:+--description "$description"} \
        --out "$dist") || { echo "skip: $name: package.sh failed" >&2; return 1; }

    local archives=("$dist"/*.tar.zst)
    local archive="${archives[0]}"
    [ -f "$archive" ] || { echo "skip: $name: package.sh produced no tarball" >&2; return 1; }
    local tag
    tag=$(basename "$archive" .tar.zst)

    git fetch -q origin main || { echo "skip: $name: git fetch origin main failed" >&2; return 1; }
    git push -q origin --delete "$branch" >/dev/null 2>&1 || true
    git checkout -q -B "$branch" origin/main || { echo "skip: $name: git checkout -B $branch failed" >&2; return 1; }

    if jq --argjson entry "$entry_json" '
        (.packages | map(.name) | index($entry.name)) as $i
        | if $i != null then .packages[$i] = $entry else .packages += [$entry] end
    ' "$INDEX_FILE" > "$INDEX_FILE.tmp"; then
        mv "$INDEX_FILE.tmp" "$INDEX_FILE"
    else
        echo "skip: $name: failed to update $INDEX_FILE" >&2
        rm -f "$INDEX_FILE.tmp"
        return 1
    fi

    git add "$INDEX_FILE"
    git commit -q -m "Update $name to $latest_version" || { echo "skip: $name: git commit failed" >&2; return 1; }

    if gh release view "$tag" --repo "$repo_slug" >/dev/null 2>&1; then
        gh release upload "$tag" "$archive" --repo "$repo_slug" --clobber
    else
        gh release create "$tag" "$archive" --repo "$repo_slug" \
            --title "$name $latest_version${platform:+ ($platform)}" \
            --notes "Automated update via update.sh from ${repo}@${tag_name}."
    fi || { echo "skip: $name: gh release create/upload failed" >&2; return 1; }

    git push -q -u origin "$branch" || { echo "skip: $name: git push failed" >&2; return 1; }
    gh pr create --repo "$repo_slug" --base main --head "$branch" \
        --title "Update $name to $latest_version" \
        --body "Automated update: \`$name\` ${current_version:-<not indexed>} -> $latest_version, built from [$repo@$tag_name](https://github.com/$repo/releases/tag/$tag_name)." \
        || { echo "skip: $name: gh pr create failed" >&2; return 1; }

    updated=$((updated + 1))
}

while IFS= read -r pkg_json; do
    if ! process_package "$pkg_json"; then
        skipped=$((skipped + 1))
    fi
done < <(jq -c '.[]' <<<"$sources_json")

git checkout -q "$start_ref" 2>/dev/null || true

echo >&2
echo "done: $updated update(s) opened, $skipped skipped due to errors" >&2
