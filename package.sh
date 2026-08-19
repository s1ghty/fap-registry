#!/usr/bin/env bash
# package.sh — turn a prebuilt binary (or a whole app directory) into a
# fap package tarball + stable.json entry.
#
# Reproduces the packaging steps fap's package.c expects: a zstd-compressed,
# plain ustar tarball (no GNU/PAX extensions — fap's tar reader is hand-rolled
# and only understands classic ustar headers).
#
# Two modes:
#
#   Single binary (original mode):
#     ./package.sh <binary> <name> <version> [options]
#   Packages one file at bin/<bin-name>.
#
#   Whole tree (for apps that ship a resource directory alongside their
#   binary — neovim's share/nvim/runtime/, Firefox's bundled locale/
#   plugin files — not just a single self-contained binary):
#     ./package.sh --tree <dir> <name> <version> --entry <path> [options]
#   Packages <dir>'s entire contents as-is, preserving structure, and
#   declares <path> (relative to <dir>) as the installed entry point.
#   fap resolves a bin entry containing '/' as that exact path rather
#   than assuming bin/<name> — see install.c's resolve_pkg_entry(). A
#   binary sitting at the tree's own root with no subdirectory (e.g.
#   Firefox's flat layout) still needs a '/' in the declared path to
#   avoid being misread as a bare name, so this script normalizes a
#   slash-free --entry to "./<entry>" before writing it out.
#
# Positional:
#   binary               (single-binary mode) Path to the binary to package.
#   name                  Package name as it will appear in the index.
#   version               Package version.
#
# Options:
#   -b, --bin-name NAME    Installed binary name (single-binary mode only;
#                           default: basename of <binary>). Has no effect
#                           with --tree — the installed name there is
#                           always the basename of --entry.
#   -T, --tree DIR          Package DIR's entire contents, not just one file.
#   -e, --entry PATH        (--tree only) Path to the executable, relative
#                           to DIR. Required with --tree.
#   -p, --platform TAG     Platform suffix, e.g. macos-arm64, linux-x86_64.
#                         Appended to the artifact filename and release tag.
#   -d, --description STR Description field for the index entry.
#   -r, --repo OWNER/REPO GitHub repo the asset will be hosted on
#                         (default: parsed from `git remote get-url origin`).
#   -t, --tag TAG          Release tag used in the download URL
#                         (default: <name>-<version>[-<platform>]).
#   -o, --out DIR          Output directory for the tarball (default: ./dist).
#   -h, --help             Show this help.
#
# Both modes bundle any shared library dependencies of the entry binary
# beyond the base glibc set (via ldd, Linux only — see the ldd block below).
#
# Examples:
#   ./package.sh ~/Downloads/jq-linux-amd64 jq-linux-x86_64 1.8.2 \
#       --bin-name jq --platform linux-x86_64 \
#       --description "Command-line JSON processor (Linux x86_64 static binary)"
#
#   ./package.sh --tree ~/Downloads/nvim-linux-x86_64 neovim 0.12.4 \
#       --entry bin/nvim --platform linux-x86_64 \
#       --description "Hyperextensible Vim-based text editor"

set -euo pipefail

usage() {
    sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'
}

err() {
    echo "package.sh: $*" >&2
    exit 1
}

bin_name=""
tree_dir=""
entry=""
platform=""
description=""
repo=""
tag=""
out_dir="./dist"

positional=()
while [ $# -gt 0 ]; do
    case "$1" in
        -b|--bin-name)    bin_name=$2; shift 2 ;;
        -T|--tree)        tree_dir=$2; shift 2 ;;
        -e|--entry)       entry=$2; shift 2 ;;
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

if [ -n "$tree_dir" ]; then
    [ -z "$bin_name" ] || err "--bin-name has no effect with --tree — the installed name is always the basename of --entry"
    [ -n "$entry" ] || err "--tree requires --entry <path-to-executable-within-the-tree>"
    [ -d "$tree_dir" ] || err "no such directory: $tree_dir"
    [ "${#positional[@]}" -eq 2 ] || { usage; err "expected 2 positional args (name, version) with --tree, got ${#positional[@]}"; }
    name=${positional[0]}
    version=${positional[1]}
else
    [ "${#positional[@]}" -eq 3 ] || { usage; err "expected 3 positional args (binary, name, version), got ${#positional[@]}"; }
    binary=${positional[0]}
    name=${positional[1]}
    version=${positional[2]}
    [ -f "$binary" ] || err "no such file: $binary"
fi

command -v tar  >/dev/null || err "tar not found"
command -v zstd >/dev/null || err "zstd not found (install via your package manager, e.g. brew install zstd)"

if command -v shasum >/dev/null; then
    sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
elif command -v sha256sum >/dev/null; then
    sha256() { sha256sum "$1" | awk '{print $1}'; }
else
    err "neither shasum nor sha256sum found"
fi

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

if [ -n "$tree_dir" ]; then
    # Preserve the whole tree exactly as given — cp -R DIR/. STAGING/
    # copies DIR's *contents* into staging's root, not DIR itself as a
    # subdirectory, keeping every file's relative position (this is
    # what lets a binary find its sibling resources at runtime — see
    # install.c's file header comment on $ORIGIN/readlink resolution).
    cp -R "$tree_dir"/. "$staging"/
    entry_rel="$entry"
    case "$entry_rel" in
        */*) ;;
        *) entry_rel="./$entry_rel" ;;
    esac
    entry_path="$staging/$entry_rel"
    [ -f "$entry_path" ] || err "entry \"$entry\" not found in tree (looked for $entry_path)"
    chmod +x "$entry_path"
    installed_name=$(basename "$entry_rel")
    bin_field_value="$entry_rel"
else
    [ -n "$bin_name" ] || bin_name=$(basename "$binary")
    mkdir -p "$staging/bin"
    cp "$binary" "$staging/bin/$bin_name"
    chmod +x "$staging/bin/$bin_name"
    entry_path="$staging/bin/$bin_name"
    installed_name="$bin_name"
    bin_field_value="$bin_name"
fi

# Bundle any shared library dependencies of the entry binary beyond the
# base set every glibc system already has. A binary built on one
# distro's libraries and installed on another can pull in something
# (ncurses is the classic case) whose ABI doesn't actually match the
# target system's own copy, even at the same soname version — fap's
# "libs" mechanism (bundled .so + wrapper script, see fap.h) exists
# exactly for this. Applies the same way in --tree mode, aimed at the
# entry binary specifically — deliberately NOT an attempt to bundle an
# entire desktop dependency stack (GTK, X11, ...) for something like
# Firefox; those are assumed already present on any real desktop
# system, same as Firefox's own official tarball assumes. ldd only
# exists on Linux, so on macOS this is a no-op with a note — same as
# it's always effectively been until now.
lib_names=()
if command -v ldd >/dev/null 2>&1 && ldd "$entry_path" >/dev/null 2>&1; then
    mkdir -p "$staging/lib"
    staging_real=$(cd "$staging" && pwd -P)
    while read -r line; do
        libpath=$(echo "$line" | awk '{ if ($2 == "=>") print $3 }')
        [ -n "$libpath" ] && [ -f "$libpath" ] || continue
        libname=$(basename "$libpath")
        case "$libname" in
            ld-linux*.so*|libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|libresolv.so.*|libgcc_s.so.*)
                continue ;;
        esac
        # Already self-satisfied via the package's own directory (e.g. a
        # --tree package that bundles its own libs, resolved via $ORIGIN
        # rather than a system path) — copying it again into lib/ would
        # just duplicate data already present, for zero benefit.
        libdir_real=$(cd "$(dirname "$libpath")" && pwd -P)
        case "$libdir_real" in
            "$staging_real"|"$staging_real"/*) continue ;;
        esac
        cp "$libpath" "$staging/lib/$libname"
        lib_names+=("$libname")
    done < <(ldd "$entry_path" 2>/dev/null)
    [ "${#lib_names[@]}" -gt 0 ] || rmdir "$staging/lib" 2>/dev/null || true
elif ! command -v ldd >/dev/null 2>&1; then
    echo "package.sh: note: ldd not found (expected on macOS) — not checking for shared library dependencies to bundle. If $installed_name is dynamically linked against anything beyond glibc itself, package it on Linux instead so this can be detected." >&2
fi

tarball="$out_dir/${artifact_base}.tar"
archive="$out_dir/${artifact_base}.tar.zst"

# Whatever ended up at staging's top level — bin/ (+ lib/ if bundling
# found anything) in single-binary mode, or the full preserved tree
# (+ lib/ folded into whatever the tree already had, if any) in --tree
# mode. Globbing staging itself instead of hardcoding the entry list
# means a pre-existing lib/ inside a packaged tree and a freshly
# bundled one are both picked up the same way, with no special-casing.
tar_items=()
for f in "$staging"/*; do
    [ -e "$f" ] && tar_items+=("$(basename "$f")")
done
tar --format ustar -cf "$tarball" -C "$staging" "${tar_items[@]}"
zstd -19 -f -q "$tarball" -o "$archive"
rm -f "$tarball"

sha=$(sha256 "$archive")
url="https://github.com/${repo}/releases/download/${tag}/${artifact_base}.tar.zst"

libs_field=""
if [ "${#lib_names[@]}" -gt 0 ]; then
    joined=""
    for l in "${lib_names[@]}"; do
        if [ -z "$joined" ]; then joined="\"$l\""; else joined="$joined, \"$l\""; fi
    done
    libs_field=",
      \"libs\": [$joined]"
fi

echo "Package:     $name $version" >&2
echo "Bin:         $installed_name" >&2
[ "${#lib_names[@]}" -gt 0 ] && echo "Libs:        ${lib_names[*]}" >&2
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
      "bin": ["$bin_field_value"]$libs_field
    }
JSON
