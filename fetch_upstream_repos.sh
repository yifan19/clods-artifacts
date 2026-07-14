#!/bin/bash
# Clones (or updates) every upstream GitHub repo this artifact is built around/from — see
# README.md's "Upstream repos" section and DATA.md's "Vendored source repos". This is the git-clone
# alternative to DATA.md's git-bundle-from-S3 approach: use it when you want a live, updatable
# checkout of the actual sources (e.g. to send a PR upstream, like the bm_instrument fix in this
# repo's own history) rather than a frozen bundle snapshot.
#
# Usage: ./fetch_upstream_repos.sh [--with-origins] [target-dir]
#   target-dir defaults to $UPSTREAM_DIR or ~/artifacts (matches this project's own layout).
#   --with-origins also adds each canonical upstream (pre-fork) repo as a remote named
#   "origin-upstream", for diffing against or sending a PR to the non-fork project.
# Idempotent: re-running `git pull`s any repo already cloned instead of re-cloning.
set -euo pipefail
WITH_ORIGINS=0
TARGET_DIR=""
for arg in "$@"; do
    if [ "$arg" = "--with-origins" ]; then
        WITH_ORIGINS=1
    else
        TARGET_DIR="$arg"
    fi
done
TARGET_DIR="${TARGET_DIR:-${UPSTREAM_DIR:-$HOME/artifacts}}"
mkdir -p "$TARGET_DIR"

# name : clone-url (the fork/branch this project actually vendors from) : origin-url (canonical
# upstream, for reference — not added as a remote automatically, see --with-origins)
REPOS='
bm_instrument           git@github.com:yifan19/clods-instrumenter.git           https://gitlab.dsrg.utoronto.ca/yuyi20/bm_instrument
Python-Instrumentation  git@github.com:yifan19/Python-Instrumentation.git       https://github.com/harshitandro/Python-Instrumentation
synapse                 git@github.com:yifan19/synapse.git                     https://github.com/element-hq/synapse
element-android         git@github.com:yifan19/element-android.git             https://github.com/element-hq/element-android
dex2jar                 https://github.com/Kyson/dex2jar/                      https://github.com/pxb1988/dex2jar
ARTTI_instrument        https://github.com/Latimaria/ARTTI_instrument/         (same repo, no separate upstream)
'

echo "$REPOS" | while read -r name url origin_url; do
    [ -z "$name" ] && continue
    dest="$TARGET_DIR/$name"
    if [ -d "$dest/.git" ]; then
        echo "== $name: already cloned at $dest, pulling =="
        git -C "$dest" pull --ff-only || echo "  (pull failed/diverged — leaving as-is)" >&2
    else
        echo "== $name: cloning $url -> $dest =="
        git clone "$url" "$dest"
    fi
    if [ "$WITH_ORIGINS" = "1" ] && [ "$origin_url" != "(same repo, no separate upstream)" ]; then
        git -C "$dest" remote add origin-upstream "$origin_url" 2>/dev/null || true
    fi
done

echo "== done. Repos are in $TARGET_DIR =="
echo "== note: bm_instrument's real content lives on its 'android_final' branch"
echo "==   (git -C $TARGET_DIR/bm_instrument checkout android_final) — see ANDROID_README.md =="
