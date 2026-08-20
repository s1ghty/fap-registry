#!/usr/bin/env bash
# update.sh — check sources.toml against stable.json and open a PR for
# each package whose upstream release is newer than what's indexed.
#
# For each [[package]] in sources.toml:
#   1. Determine the latest version, one of two ways depending on which
#      source fields are set:
#        - "repo" (owner/repo): fetch its latest release via the GitHub
#          releases API.
#        - "version_url": fetch that URL and read the version from its
#          response body (the whole trimmed body, or a field extracted
#          via "version_jq" if set) — for anything not hosted on GitHub,
#          e.g. Mozilla's product-details API for Firefox. The download
#          URL itself comes from "url_template", a URL containing the
#          literal text "{version}", substituted with whatever version
#          was just determined.
#      Exactly one of "repo" / "version_url" must be set. A GitHub
#      build_from_source package can set "pin_tag" to check out a specific
#      tag instead of whatever's actually latest — e.g. a newer release
#      needs a dependency version the CI runner can't satisfy (see
#      sway's sources.toml entry). A pinned package's own version never
#      changes on its own; update.sh just reports it "up to date" forever
#      unless sources.toml's pin_tag itself is edited.
#   2. Compare that version against stable.json's current entry (missing
#      entries count as outdated, i.e. "add this package").
#   3. If newer, obtain the binary (or, if "tree" is set, the whole app
#      directory) one of three ways (see sources.toml's field docs for
#      which fields select which mode):
#        - direct binary asset: downloaded as-is (not valid with "tree")
#        - archive asset: downloaded and extracted; "bin_path" is either
#          the single binary's path inside it, or — with "tree" set — the
#          entry point's path inside it, with the rest of the extracted
#          tree preserved and packaged alongside it
#        - build_from_source: shallow-clone "repo" at the release tag, run
#          "build_cmd" (installing "build_deps" via apt first); "bin_path"
#          works the same as archive mode, relative to the clone root
#          instead — for projects like htop that don't publish a prebuilt
#          Linux binary at all. Only supported with "repo" (a GitHub
#          checkout) — not yet with "version_url".
#      Then repackage it with package.sh, upload the tarball as a release
#      asset on this repo, update stable.json on a fresh branch, and open
#      a PR.
#
# Usage:
#   ./update.sh [options]
#
# Options:
#   -n, --dry-run          Check for updates but don't download, build,
#                           package, push, or open anything.
#   -s, --sources FILE     Sources file (default: sources.toml).
#   -i, --index FILE       Index file to update (default: stable.json).
#   -f, --force NAME       Repackage NAME even if its upstream version
#                           isn't newer than what's indexed — for when
#                           packaging logic itself changed (e.g. package.sh
#                           learning to bundle shared libraries), not the
#                           upstream release.
#   -h, --help             Show this help.
#
# Requires: curl, jq, tar, zstd, git, gh (authenticated), awk. A
# build_from_source package additionally needs whatever its build_cmd
# needs (build_deps installs these via `apt-get`, so this only really
# works on a Debian/Ubuntu CI runner — which is exactly what the
# accompanying GitHub Actions workflow runs on).

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
FORCE_NAME=""

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run)  DRY_RUN=1; shift ;;
        -s|--sources)  SOURCES_FILE=$2; shift 2 ;;
        -i|--index)    INDEX_FILE=$2; shift 2 ;;
        -f|--force)    FORCE_NAME=$2; shift 2 ;;
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
    local build_from_source build_deps build_cmd bin_path tree
    local version_url version_jq url_template pin_tag
    name=$(jq -r '.name // empty' <<<"$pkg_json")
    repo=$(jq -r '.repo // empty' <<<"$pkg_json")
    asset=$(jq -r '.asset // empty' <<<"$pkg_json")
    bin=$(jq -r '.bin // empty' <<<"$pkg_json")
    platform=$(jq -r '.platform // empty' <<<"$pkg_json")
    description=$(jq -r '.description // empty' <<<"$pkg_json")
    version_prefix=$(jq -r '.version_prefix // empty' <<<"$pkg_json")
    build_from_source=$(jq -r '.build_from_source // empty' <<<"$pkg_json")
    build_deps=$(jq -r '.build_deps // empty' <<<"$pkg_json")
    build_cmd=$(jq -r '.build_cmd // empty' <<<"$pkg_json")
    bin_path=$(jq -r '.bin_path // empty' <<<"$pkg_json")
    tree=$(jq -r '.tree // empty' <<<"$pkg_json")
    version_url=$(jq -r '.version_url // empty' <<<"$pkg_json")
    version_jq=$(jq -r '.version_jq // empty' <<<"$pkg_json")
    url_template=$(jq -r '.url_template // empty' <<<"$pkg_json")
    pin_tag=$(jq -r '.pin_tag // empty' <<<"$pkg_json")

    [ -n "$name" ] || { echo "skip: sources.toml entry missing name: $pkg_json" >&2; return 1; }

    # Which upstream source: "repo" (GitHub releases API) or
    # "version_url" (fetch a URL, read the version out of it, build the
    # download URL from a template) — exactly one, not both, not neither.
    local source_mode
    if [ -n "$repo" ] && [ -n "$version_url" ]; then
        echo "skip: $name: sets both repo and version_url — pick one source" >&2
        return 1
    elif [ -n "$repo" ]; then
        source_mode="github"
    elif [ -n "$version_url" ]; then
        source_mode="url"
        if [ -z "$url_template" ]; then
            echo "skip: $name: version_url set but no url_template (how to build the download URL from a version)" >&2
            return 1
        fi
        if [ "$build_from_source" = "true" ]; then
            echo "skip: $name: build_from_source isn't supported with version_url yet — only GitHub-hosted (repo) cloning is" >&2
            return 1
        fi
    else
        echo "skip: $name: needs either repo (GitHub) or version_url (arbitrary URL): $pkg_json" >&2
        return 1
    fi

    if [ -n "$pin_tag" ] && [ "$build_from_source" != "true" ]; then
        echo "skip: $name: pin_tag only makes sense with build_from_source (a non-source release needs the real release's asset list, which a pinned tag skips fetching)" >&2
        return 1
    fi
    if [ "$build_from_source" = "true" ]; then
        if [ -z "$build_cmd" ] || [ -z "$bin_path" ]; then
            echo "skip: $name: build_from_source package missing build_cmd/bin_path: $pkg_json" >&2
            return 1
        fi
    elif [ "$source_mode" = "github" ] && [ -z "$asset" ]; then
        echo "skip: $name: GitHub-hosted package missing asset: $pkg_json" >&2
        return 1
    fi
    # "bin" is only meaningful outside tree mode (package.sh derives the
    # installed name from bin_path's basename when tree=true — see the
    # comment above this function's field docs).
    if [ "$tree" != "true" ] && [ -z "$bin" ]; then
        echo "skip: $name: missing bin (or set tree=true, which derives it from bin_path): $pkg_json" >&2
        return 1
    fi
    if [ "$tree" = "true" ] && [ -z "$bin_path" ]; then
        echo "skip: $name: has tree=true but no bin_path (entry point within the tree): $pkg_json" >&2
        return 1
    fi

    echo "== $name (upstream ${repo:-$version_url}) ==" >&2

    local auth=()
    [ -n "$gh_token" ] && auth=(-H "Authorization: Bearer $gh_token")

    local release_json="" tag_name="" latest_version
    if [ "$source_mode" = "github" ] && [ -n "$pin_tag" ]; then
        # Pinned to a specific tag instead of whatever's actually latest
        # upstream — e.g. a newer release needs a dependency version this
        # CI runner can't satisfy (see sway's sources.toml comment).
        # release_json stays empty: pinned packages are only meaningful
        # for build_from_source (no release-assets list needed), and
        # that's enforced below by the same validation asset-mode
        # packages already go through.
        tag_name="$pin_tag"
        latest_version=${tag_name#"$version_prefix"}
    elif [ "$source_mode" = "github" ]; then
        if ! release_json=$(curl -fsSL "${auth[@]}" -H "Accept: application/vnd.github+json" \
                "https://api.github.com/repos/$repo/releases/latest"); then
            echo "skip: $name: failed to fetch latest release for $repo" >&2
            return 1
        fi
        tag_name=$(jq -r '.tag_name' <<<"$release_json")
        latest_version=${tag_name#"$version_prefix"}
    else
        local version_resp
        if ! version_resp=$(curl -fsSL "$version_url"); then
            echo "skip: $name: failed to fetch $version_url" >&2
            return 1
        fi
        if [ -n "$version_jq" ]; then
            latest_version=$(jq -r "$version_jq" <<<"$version_resp" 2>/dev/null || true)
        else
            latest_version=$(printf '%s' "$version_resp" | tr -d '[:space:]')
        fi
        if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
            echo "skip: $name: could not extract a version from $version_url${version_jq:+ (via version_jq \"$version_jq\")}" >&2
            return 1
        fi
        latest_version=${latest_version#"$version_prefix"}
    fi

    local source_desc source_link_md
    if [ "$source_mode" = "github" ]; then
        source_desc="${repo}@${tag_name}"
        source_link_md="[$repo@$tag_name](https://github.com/$repo/releases/tag/$tag_name)"
    else
        source_desc="$version_url"
        source_link_md="[$version_url]($version_url)"
    fi

    local current_version
    current_version=$(jq -r --arg n "$name" '.packages[]? | select(.name==$n) | .version // empty' "$INDEX_FILE")

    if [ -n "$current_version" ] && [ "$name" != "$FORCE_NAME" ]; then
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
    elif [ "$name" = "$FORCE_NAME" ]; then
        echo "forced: $name $current_version -> repackaging $latest_version regardless" >&2
    fi

    echo "outdated: $name ${current_version:-<not indexed>} -> $latest_version" >&2

    local asset_url=""
    if [ "$build_from_source" != "true" ]; then
        if [ "$source_mode" = "github" ]; then
            asset_url=$(jq -r --arg a "$asset" '.assets[] | select(.name==$a) | .browser_download_url' <<<"$release_json")
            if [ -z "$asset_url" ]; then
                echo "skip: $name: release $tag_name has no asset named $asset" >&2
                return 1
            fi
        else
            asset_url=${url_template//\{version\}/$latest_version}
        fi
    fi

    if [ "$DRY_RUN" = "1" ]; then
        local mode_note=""
        [ "$tree" = "true" ] && mode_note=" (whole tree, entry point $bin_path)"
        if [ "$build_from_source" = "true" ]; then
            echo "dry-run: would clone $repo@$tag_name, run '$build_cmd', and open a PR updating $name to $latest_version$mode_note" >&2
        else
            echo "dry-run: would download $asset_url and open a PR updating $name to $latest_version$mode_note" >&2
        fi
        return 0
    fi

    local branch="update/${name}-${latest_version}"
    if [ -n "$(gh pr list --repo "$repo_slug" --head "$branch" --state open --json number --jq '.[0].number' 2>/dev/null)" ]; then
        echo "skip: $name: an open PR already exists for $branch" >&2
        return 0
    fi

    local work resolved_bin tree_root
    work=$(mktemp -d)
    trap 'rm -rf "$work"' RETURN
    resolved_bin=""
    tree_root=""

    if [ "$build_from_source" = "true" ]; then
        if [ -n "$build_deps" ]; then
            sudo apt-get update -qq && sudo apt-get install -y -qq $build_deps
        fi
        if ! git clone --quiet --depth 1 --branch "$tag_name" "https://github.com/$repo.git" "$work/src"; then
            echo "skip: $name: git clone of $repo@$tag_name failed" >&2
            return 1
        fi
        if ! ( cd "$work/src" && eval "$build_cmd" ); then
            echo "skip: $name: build command failed" >&2
            return 1
        fi
        if [ "$tree" = "true" ]; then
            tree_root="$work/src"
        else
            resolved_bin="$work/src/$bin_path"
        fi
    elif [ -n "$bin_path" ]; then
        # archive asset: download, extract — bin_path is either the one
        # binary to package (non-tree), or the entry point within the
        # whole tree to preserve (tree=true). $asset names the local temp
        # file for a GitHub release asset; url-mode has no "asset" (there's
        # no release-assets list to pick a filename from — the URL itself
        # is the one and only download), so fall back to its basename.
        local asset_filename="${asset:-$(basename "$asset_url")}"
        local downloaded="$work/$asset_filename"
        curl -fsSL -o "$downloaded" "$asset_url" || { echo "skip: $name: failed to download $asset_url" >&2; return 1; }
        mkdir -p "$work/extracted"
        tar -xf "$downloaded" -C "$work/extracted" || { echo "skip: $name: failed to extract $asset_filename" >&2; return 1; }
        if [ "$tree" = "true" ]; then
            tree_root="$work/extracted"
        else
            resolved_bin="$work/extracted/$bin_path"
        fi
    else
        # direct binary asset — the download itself is the binary
        resolved_bin="$work/${asset:-$(basename "$asset_url")}"
        curl -fsSL -o "$resolved_bin" "$asset_url" || { echo "skip: $name: failed to download $asset_url" >&2; return 1; }
    fi

    local dist entry_json
    dist="$work/dist"
    if [ -n "$tree_root" ]; then
        [ -f "$tree_root/$bin_path" ] || { echo "skip: $name: expected entry point not found at $tree_root/$bin_path" >&2; return 1; }
        entry_json=$("$SCRIPT_DIR/package.sh" --tree "$tree_root" "$name" "$latest_version" \
            --entry "$bin_path" \
            ${platform:+--platform "$platform"} \
            ${description:+--description "$description"} \
            --out "$dist") || { echo "skip: $name: package.sh failed" >&2; return 1; }
    else
        [ -f "$resolved_bin" ] || { echo "skip: $name: expected binary not found at $resolved_bin" >&2; return 1; }
        chmod +x "$resolved_bin"
        entry_json=$("$SCRIPT_DIR/package.sh" "$resolved_bin" "$name" "$latest_version" \
            --bin-name "$bin" \
            ${platform:+--platform "$platform"} \
            ${description:+--description "$description"} \
            --out "$dist") || { echo "skip: $name: package.sh failed" >&2; return 1; }
    fi

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
            --notes "Automated update via update.sh from ${source_desc}."
    fi || { echo "skip: $name: gh release create/upload failed" >&2; return 1; }

    git push -q -u origin "$branch" || { echo "skip: $name: git push failed" >&2; return 1; }
    gh pr create --repo "$repo_slug" --base main --head "$branch" \
        --title "Update $name to $latest_version" \
        --body "Automated update: \`$name\` ${current_version:-<not indexed>} -> $latest_version, built from ${source_link_md}." \
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
