#!/bin/bash
# Tars+gzips every file this repo's git doesn't track — both genuinely untracked stray files and
# everything .gitignore excludes (vendored binaries/jars/APKs/source checkouts, see DATA.md). This
# is a portable alternative/supplement to fetch_data.sh's S3 pull: instead of fetching from S3, it
# snapshots whatever is *already sitting in this checkout* into one archive you can copy anywhere
# and restore with unbundle_untracked.sh — useful for handing off a fully-populated checkout
# without S3 access, or for backing up before a risky operation.
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
trap 'rm -f "$MANIFEST"' EXIT

# --ignored + --untracked-files=all: every path git doesn't track, files listed individually
# (not collapsed to their parent dir) so the manifest is actually useful. .claude/ is excluded:
# it's this harness's own worktree-management directory (which may itself contain full nested
# checkouts of this repo) and settings, not project data.
git status --porcelain --ignored --untracked-files=all \
    | awk '{ $1=""; sub(/^ /, ""); print }' \
    | grep -v -e '^\.claude/' -e '^__pycache__/' -e '\.pyc$' \
    > "$MANIFEST"

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
