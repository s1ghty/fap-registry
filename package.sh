#!/usr/bin/env bash
# package.sh — turn a prebuilt binary into a fap package tarball + stable.json entry.
#
# Reproduces the packaging steps fap's package.c expects: a zstd-compressed,
# plain ustar tarball (no GNU/PAX extensions — fap's tar reader is hand-rolled
# and only understands classic ustar headers) containing bin/<bin-name>.
#
# Usage:
#   ./package.sh <binary> <name> <version> [options]
#
# Positional:
#   binary              Path to the binary to package.
#   name                Package name as it will appear in the index.
#   version             Package version.
#
# Options:
#   -b, --bin-name NAME   Installed binary name (default: basename of <binary>).
#   -p, --platform TAG    Platform suffix, e.g. macos-arm64, linux-x86_64.
#                         Appended to the artifact filename and release tag.
#   -d, --description STR Description field for the index entry.
#   -r, --repo OWNER/REPO GitHub repo the asset will be hosted on
#                         (default: parsed from `git remote get-url origin`).
#   -t, --tag TAG          Release tag used in the download URL
#                         (default: <name>-<version>[-<platform>]).
#   -o, --out DIR          Output directory for the tarball (default: ./dist).
#   -h, --help             Show this help.
#
# Example:
#   ./package.sh ~/Downloads/jq-linux-amd64 jq-linux-x86_64 1.8.2 \
#       --bin-name jq --platform linux-x86_64 \
#       --description "Command-line JSON processor (Linux x86_64 static binary)"

set -euo pipefail

usage() {
    sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
}

err() {
    echo "package.sh: $*" >&2
    exit 1
}

bin_name=""
platform=""
description=""
repo=""
tag=""
out_dir="./dist"

positional=()
while [ $# -gt 0 ]; do
    case "$1" in
        -b|--bin-name)    bin_name=$2; shift 2 ;;
        -p|--platform)    platform=$2; shift 2 ;;
        -d|--description) description=$2; shift 2 ;;
        -r|--repo)        repo=$2; shift 2 ;;
        -t|--tag)         tag=$2; shift 2 ;;
        -o|--out)         out_dir=$2; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        --) shift; while [ $# -gt 0 ]; do positional+=("$1"); shift; done ;;
        -*) err "unknown option: $1" ;;
        *)  positional+=("$1"); shift ;;
    esac
done

[ "${#positional[@]}" -eq 3 ] || { usage; err "expected 3 positional args (binary, name, version), got ${#positional[@]}"; }
binary=${positional[0]}
name=${positional[1]}
version=${positional[2]}

[ -f "$binary" ] || err "no such file: $binary"
command -v tar  >/dev/null || err "tar not found"
command -v zstd >/dev/null || err "zstd not found (install via your package manager, e.g. brew install zstd)"

if command -v shasum >/dev/null; then
    sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
elif command -v sha256sum >/dev/null; then
    sha256() { sha256sum "$1" | awk '{print $1}'; }
else
    err "neither shasum nor sha256sum found"
fi

[ -n "$bin_name" ] || bin_name=$(basename "$binary")

suffix=""
[ -n "$platform" ] && suffix="-$platform"
artifact_base="${name}-${version}${suffix}"
[ -n "$tag" ] || tag="$artifact_base"

if [ -z "$repo" ]; then
    origin_url=$(git config --get remote.origin.url 2>/dev/null || true)
    repo=$(echo "$origin_url" | sed -E 's#(git@github\.com:|https://github\.com/)##; s#\.git$##')
fi
[ -n "$repo" ] || err "could not determine GitHub repo; pass --repo OWNER/REPO"

mkdir -p "$out_dir"
out_dir=$(cd "$out_dir" && pwd)
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT

mkdir -p "$staging/bin"
cp "$binary" "$staging/bin/$bin_name"
chmod +x "$staging/bin/$bin_name"

tarball="$out_dir/${artifact_base}.tar"
archive="$out_dir/${artifact_base}.tar.zst"

tar --format ustar -cf "$tarball" -C "$staging" bin/"$bin_name"
zstd -19 -f -q "$tarball" -o "$archive"
rm -f "$tarball"

sha=$(sha256 "$archive")
url="https://github.com/${repo}/releases/download/${tag}/${artifact_base}.tar.zst"

echo "Package:     $name $version" >&2
echo "Bin:         $bin_name" >&2
echo "Artifact:    $archive" >&2
echo "SHA256:      $sha" >&2
echo "Release tag: $tag" >&2
echo >&2
echo "Upload with:" >&2
echo "  gh release create $tag $archive --repo $repo --title \"$name $version${platform:+ ($platform)}\"" >&2
echo >&2
echo "stable.json entry:" >&2

cat <<JSON
    {
      "name": "$name",
      "version": "$version",
      "url": "$url",
      "sha256": "$sha",
      "description": "$description",
      "bin": ["$bin_name"]
    }
JSON
