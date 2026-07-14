#!/bin/bash
# Extracts an archive made by bundle_untracked.sh back into a checkout of this repo. Safe to run
# against a fresh `git clone` of final_artifact — everything in the archive is, by construction,
# stuff git doesn't track, so nothing here should ever collide with a tracked file. Checked anyway,
# since a hand-edited or foreign archive could violate that.
#
# Usage: ./unbundle_untracked.sh <archive.tar.gz> [target-repo-root]
#   target-repo-root defaults to the directory this script is run from.
set -euo pipefail
ARCHIVE="${1:?usage: unbundle_untracked.sh <archive.tar.gz> [target-repo-root]}"
TARGET="${2:-$(pwd)}"

[ -f "$ARCHIVE" ] || { echo "no such archive: $ARCHIVE" >&2; exit 1; }
if [ ! -d "$TARGET/.git" ]; then
    echo "warning: $TARGET doesn't look like a git repo root (no .git) — continuing anyway" >&2
fi

cd "$TARGET"

# Safety check: if any tracked file appears inside the archive, refuse — bundle_untracked.sh never
# produces that, so it means this archive doesn't match this checkout (wrong repo, wrong commit
# with different .gitignore history, or hand-edited).
if [ -d .git ]; then
    CONFLICTS=$(comm -12 \
        <(tar tzf "$ARCHIVE" | sed 's#/$##' | sort -u) \
        <(git ls-files | sort -u))
    if [ -n "$CONFLICTS" ]; then
        echo "refusing to extract: archive contains paths git tracks in $TARGET:" >&2
        echo "$CONFLICTS" >&2
        exit 1
    fi
fi

echo "== extracting $(tar tzf "$ARCHIVE" | wc -l) path(s) from $ARCHIVE into $TARGET =="
tar xzf "$ARCHIVE" -C "$TARGET"
echo "== done =="
