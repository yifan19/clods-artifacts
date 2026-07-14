#!/bin/bash
# Tars+gzips every file this repo's git doesn't track — both genuinely untracked stray files and
# everything .gitignore excludes (vendored binaries/jars/APKs/source checkouts, see DATA.md). This
# is a portable alternative/supplement to fetch_data.sh's S3 pull: instead of fetching from S3, it
# snapshots whatever is *already sitting in this checkout* into one archive you can copy anywhere
# and restore with unbundle_untracked.sh — useful for handing off a fully-populated checkout
# without S3 access, or for backing up before a risky operation.
#
# Only ever includes untracked/ignored content (git status codes ?? / !!) — never a tracked file's
# uncommitted local changes (M/D/etc against the index), and never a dotfile/dot-directory or a
# directory that's itself a git repo (see below — those are for fetch_upstream_repos.sh instead).
#
# Usage: ./bundle_untracked.sh [--dereference] [output.tar.gz]
#   output.tar.gz defaults to ../final_artifact-untracked-<date>.tar.gz (outside the repo, so a
#   second run doesn't try to include the first run's archive).
#
#   Each element-<bug>/apk/*.apk is a symlink to a path outside this repo (see DATA.md) — by
#   default tar archives the symlink itself, which only resolves on a machine where that absolute
#   path also exists (fine for backing up/restoring on this same box, not for handing the archive
#   to someone else). Pass --dereference to instead copy the real APK bytes into the archive
#   (~400 MB heavier across all 5 bugs, but then the archive is fully self-contained).
set -euo pipefail
cd "$(dirname "$0")"
REPO_ROOT="$(pwd)"

DEREF=""
ARGS=()
for arg in "$@"; do
    if [ "$arg" = "--dereference" ]; then
        DEREF="-h"
    else
        ARGS+=("$arg")
    fi
done
OUT="${ARGS[0]:-../final_artifact-untracked-$(date +%Y%m%d).tar.gz}"
MANIFEST="$(mktemp)"

# --ignored + --untracked-files=all: every path git doesn't track, files listed individually (not
# collapsed to their parent dir) so the manifest is actually useful — except embedded git repos
# (e.g. the Python-Instrumentation checkout vendored at this repo's root), which git always
# collapses to one directory line regardless of --untracked-files=all.
#
# Two things get filtered out below:
#  - any path with a dot-prefixed segment (.claude/, .git, hidden config/cache files, etc.) —
#    not project data.
#  - directories that are themselves git repos — re-tarring a repo as flat files throws away its
#    history and duplicates what fetch_upstream_repos.sh already clones properly; skip it here and
#    use that script for these instead.
RAW_MANIFEST="$(mktemp)"
trap 'rm -f "$MANIFEST" "$RAW_MANIFEST"' EXIT

git status --porcelain --ignored --untracked-files=all \
    | awk '{ code = substr($0, 1, 2); if (code == "??" || code == "!!") print substr($0, 4) }' \
    | awk -F'/' '{ skip=0; for (i=1; i<=NF; i++) if (substr($i,1,1) == ".") skip=1; if (!skip) print }' \
    | grep -v -e '^__pycache__/' -e '\.pyc$' \
    > "$RAW_MANIFEST"

: > "$MANIFEST"
while IFS= read -r p; do
    if [ -e "$REPO_ROOT/${p%/}/.git" ]; then
        echo "  skipping nested git repo: $p (use fetch_upstream_repos.sh instead)" >&2
        continue
    fi
    echo "$p" >> "$MANIFEST"
done < "$RAW_MANIFEST"

count=$(wc -l < "$MANIFEST")
if [ "$count" -eq 0 ]; then
    echo "nothing untracked to bundle (clean checkout, or already bundled)" >&2
    exit 0
fi

echo "== bundling $count untracked path(s) =="
STAT_FLAG=""
[ -n "$DEREF" ] && STAT_FLAG="-L"  # match tar -h: size of what a symlink points to, not the link itself
total_size=$(while read -r f; do stat $STAT_FLAG -c%s "$f" 2>/dev/null; done < "$MANIFEST" | awk '{sum+=$1} END{print sum+0}')
echo "== total size before compression: $(numfmt --to=iec "$total_size") =="

tar czf "$OUT" $DEREF -C "$REPO_ROOT" -T "$MANIFEST"

echo "== wrote $OUT ($(du -h "$OUT" | awk '{print $1}')) =="
echo "== restore with: ./unbundle_untracked.sh $OUT [target-repo-root] =="
