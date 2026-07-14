#!/bin/bash
# Pushes this checkout's vendored/gitignored data (see DATA.md) up to S3, refreshing whatever's
# changed since the last fetch_data.sh. The mirror image of fetch_data.sh — see DATA.md's own
# closing note: "aws s3 sync binaries/ s3://clods-artifacts/final_artifact-data/binaries/" is
# exactly the manual step this script automates across every category in that file's table.
#
# Deliberately narrow in scope: only the canonical categories DATA.md documents (dex2jar, prebuilt
# jars, agent binaries, APKs, offline Maven cache, source bundles, experimental_results, binaries/
# tarballs) — never this session's throwaway build/test output (unpacked APK trees, Maven target/
# dirs, dex2jar decompile caches, etc.), which has no business in a bucket other checkouts pull
# canonical data from. `aws s3 sync`/`cp` only transfers what actually differs, so re-running this
# with nothing changed is cheap regardless of how large binaries/ or the APKs are.
#
# Usage:
#   ./push_data.sh              push everything present in this checkout
#   ./push_data.sh --bug <id>   push only one bug's APK/experimental_results
#   ./push_data.sh --source     also rebuild+push the three source git bundles (bm_instrument,
#                                dex2jar, ARTTI_instrument) from their real checkouts (default
#                                ~/artifacts/<name>, override with $UPSTREAM_DIR — see
#                                fetch_upstream_repos.sh)
#   ./push_data.sh --dry-run    show what would be pushed without uploading
set -euo pipefail
cd "$(dirname "$0")"
S3=s3://clods-artifacts/final_artifact-data

need_cmd() { command -v "$1" >/dev/null || { echo "missing required command: $1" >&2; exit 1; }; }
need_cmd aws

PUSH_SOURCE=0
ONLY_BUG=""
DRY_RUN=""
while [ $# -gt 0 ]; do
    case "$1" in
        --source) PUSH_SOURCE=1; shift ;;
        --bug) ONLY_BUG="$2"; shift 2 ;;
        --dry-run) DRY_RUN="--dryrun"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# aws s3 cp always uploads regardless of whether the content changed (unlike sync, which compares
# size+mtime) — for individual files that's wasteful re-transfer of unchanged multi-hundred-MB
# APKs/jars on every run. Skip the upload if the remote object is already the same size.
push_if_changed() {
    local local_file="$1" s3_key="$2"
    local local_size remote_size
    local_size=$(stat -c%s "$local_file")
    remote_size=$(aws s3api head-object --bucket clods-artifacts \
        --key "final_artifact-data/$s3_key" --query ContentLength --output text 2>/dev/null || true)
    if [ "$remote_size" = "$local_size" ]; then
        echo "  unchanged (size match, skipping): $s3_key"
        return 0
    fi
    aws s3 cp "$local_file" "$S3/$s3_key" --no-progress $DRY_RUN
}

push_binaries() {
    [ -d binaries ] || return 0
    echo "== binaries/ (vendored Hadoop/HBase/ZooKeeper/Cassandra/YCSB/HiBench tarballs) =="
    # --size-only: default sync compares size+mtime, and a file just re-downloaded by fetch_data.sh
    # gets a fresh local mtime that's newer than S3's LastModified even when content is identical —
    # that would re-upload every binary on every run for no reason.
    aws s3 sync binaries/ "$S3/binaries/" --no-progress --size-only --exclude ".gitkeep" $DRY_RUN
}

push_experimental_results() {
    local bug="$1"
    [ -d "$bug/experimental_results" ] || return 0
    echo "== $bug/experimental_results/ =="
    tar czf "$TMPDIR/${bug}.tar.gz" -C "$bug" experimental_results
    push_if_changed "$TMPDIR/${bug}.tar.gz" "experimental_results/${bug}.tar.gz"
    rm -f "$TMPDIR/${bug}.tar.gz"
}

push_apk() {
    local bug="$1"
    [ -f "$bug/apk/vector-gplay-arm64-v8a-debug.apk" ] || return 0
    echo "== $bug/apk/ =="
    push_if_changed "$bug/apk/vector-gplay-arm64-v8a-debug.apk" "android/apks/${bug}.apk"
}

push_common() {
    echo "== common/ (instrumentation jar + offline Maven cache) =="
    if [ -f common/blameMasterInstrument.jar ]; then
        push_if_changed common/blameMasterInstrument.jar "common/blameMasterInstrument.jar"
    fi
    if [ -d common/m2-repo ]; then
        tar czf "$TMPDIR/m2-repo.tar.gz" -C common m2-repo
        push_if_changed "$TMPDIR/m2-repo.tar.gz" "common/m2-repo.tar.gz"
        rm -f "$TMPDIR/m2-repo.tar.gz"
    fi
}

push_android_common() {
    echo "== android-common/ (dex2jar + instrumentation jar + prebuilt agent) =="
    if [ -f android-common/blameMasterInstrument-android.jar ]; then
        push_if_changed android-common/blameMasterInstrument-android.jar \
            "android-common/blameMasterInstrument-android.jar"
    fi
    if [ -d android-common/dex2jar ]; then
        tar czf "$TMPDIR/dex2jar.tar.gz" -C android-common dex2jar
        push_if_changed "$TMPDIR/dex2jar.tar.gz" "android-common/dex2jar.tar.gz"
        rm -f "$TMPDIR/dex2jar.tar.gz"
    fi
    if [ -f android-common/agent-src/libagent.so.prebuilt-generic ]; then
        push_if_changed android-common/agent-src/libagent.so.prebuilt-generic \
            "android-common/libagent.so.prebuilt-generic"
    fi
}

push_source_bundles() {
    echo "== source-bundles/ (bm_instrument + dex2jar + ARTTI_instrument, full git history) =="
    local upstream="${UPSTREAM_DIR:-$HOME/artifacts}"
    for name in bm_instrument dex2jar ARTTI_instrument; do
        if [ -d "$upstream/$name/.git" ]; then
            git -C "$upstream/$name" bundle create "$TMPDIR/${name}.bundle" --all
            push_if_changed "$TMPDIR/${name}.bundle" "source-bundles/${name}.bundle"
            rm -f "$TMPDIR/${name}.bundle"
        else
            echo "  skipping $name — not found at $upstream/$name (see fetch_upstream_repos.sh)" >&2
        fi
    done
}

if [ -n "$ONLY_BUG" ]; then
    push_experimental_results "$ONLY_BUG"
    push_apk "$ONLY_BUG"
    [ -d "$ONLY_BUG" ] && case "$ONLY_BUG" in element-*) push_android_common ;; *) push_common ;; esac
else
    push_binaries
    for bug_dir in */; do
        bug="${bug_dir%/}"
        [ -f "$bug/run_experiment.sh" ] || continue
        push_experimental_results "$bug"
        push_apk "$bug"
    done
    push_common
    push_android_common
fi

[ "$PUSH_SOURCE" = "1" ] && push_source_bundles

echo "== done =="
