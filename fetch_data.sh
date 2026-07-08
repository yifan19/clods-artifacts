#!/bin/bash
# Pulls everything .gitignore excludes from this repo (vendored binaries, historical run data,
# Android APKs, prebuilt jars, offline Maven cache) from S3 into place. Run once after cloning,
# before any bug's ./run_experiment.sh. See DATA.md for exactly what lives where and why.
#
# Usage:
#   ./fetch_data.sh              fetch everything needed to run every bug
#   ./fetch_data.sh --bug <id>   fetch only one bug's binaries/APK/experimental_results
#   ./fetch_data.sh --source     also fetch the vendored source repos as git bundles (not needed
#                                 to just run experiments — only if you want to read/modify e.g.
#                                 blameMasterInstrument's own source with full git history)
set -euo pipefail
cd "$(dirname "$0")"
S3=s3://clods-artifacts/final_artifact-data

need_cmd() { command -v "$1" >/dev/null || { echo "missing required command: $1" >&2; exit 1; }; }
need_cmd aws

FETCH_SOURCE=0
ONLY_BUG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --source) FETCH_SOURCE=1; shift ;;
        --bug) ONLY_BUG="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

fetch_binaries() {
    echo "== binaries/ (vendored Hadoop/HBase/ZooKeeper/Cassandra/YCSB/HiBench tarballs) =="
    aws s3 sync "$S3/binaries/" binaries/ --no-progress
}

fetch_experimental_results() {
    local bug="$1"
    [ -d "$bug" ] || return 0
    echo "== $bug/experimental_results/ =="
    if aws s3 cp "$S3/experimental_results/${bug}.tar.gz" "/tmp/${bug}.tar.gz" --no-progress 2>/dev/null; then
        tar xzf "/tmp/${bug}.tar.gz" -C "$bug"
        rm "/tmp/${bug}.tar.gz"
    fi
}

fetch_apk() {
    local bug="$1"
    [ -d "$bug/apk" ] || return 0
    echo "== $bug/apk/ =="
    aws s3 cp "$S3/android/apks/${bug}.apk" "$bug/apk/vector-gplay-arm64-v8a-debug.apk" --no-progress
}

fetch_common() {
    echo "== common/ (instrumentation jar + offline Maven cache + source) =="
    aws s3 cp "$S3/common/blameMasterInstrument.jar" common/blameMasterInstrument.jar --no-progress
    aws s3 cp "$S3/common/m2-repo.tar.gz" /tmp/m2-repo.tar.gz --no-progress
    tar xzf /tmp/m2-repo.tar.gz -C common && rm /tmp/m2-repo.tar.gz

    # common/Dockerfile builds from source at image-build time (not just the prebuilt jar above),
    # so bm_instrument-src/ is a required input here, not an optional extra — clone it from the
    # full-history bundle (source-bundles/bm_instrument.bundle, see DATA.md) rather than a flat
    # copy, same content `main` branch would give you.
    if [ ! -d common/bm_instrument-src ]; then
        aws s3 cp "$S3/source-bundles/bm_instrument.bundle" /tmp/bm_instrument.bundle --no-progress
        git clone -q /tmp/bm_instrument.bundle common/bm_instrument-src
        rm /tmp/bm_instrument.bundle
    fi
}

fetch_android_common() {
    echo "== android-common/ (dex2jar + instrumentation jar + prebuilt agent) =="
    aws s3 cp "$S3/android-common/blameMasterInstrument-android.jar" \
        android-common/blameMasterInstrument-android.jar --no-progress
    aws s3 cp "$S3/android-common/dex2jar.tar.gz" /tmp/dex2jar.tar.gz --no-progress
    tar xzf /tmp/dex2jar.tar.gz -C android-common && rm /tmp/dex2jar.tar.gz
    aws s3 cp "$S3/android-common/libagent.so.prebuilt-generic" \
        android-common/agent-src/libagent.so.prebuilt-generic --no-progress
}

fetch_source_bundles() {
    # bm_instrument.bundle is already cloned into common/bm_instrument-src by fetch_common() (the
    # Dockerfile needs it to build) — this is for the two that are genuinely optional: dex2jar's
    # and ARTTI_instrument's full source, only needed if you want to read/modify those with
    # history, not to run any bug.
    echo "== source-bundles/ (dex2jar + ARTTI_instrument full git history — optional) =="
    mkdir -p source-bundles
    for name in dex2jar ARTTI_instrument; do
        aws s3 cp "$S3/source-bundles/${name}.bundle" "source-bundles/${name}.bundle" --no-progress
    done
    echo "-- to check one out: git clone source-bundles/dex2jar.bundle android-common/dex2jar-src"
}

if [ -n "$ONLY_BUG" ]; then
    fetch_binaries   # cheap to sync everything; bugs share tarballs so per-bug filtering saves little
    fetch_experimental_results "$ONLY_BUG"
    fetch_apk "$ONLY_BUG"
    [ -d "$ONLY_BUG" ] && case "$ONLY_BUG" in element-*) fetch_android_common ;; *) fetch_common ;; esac
else
    fetch_binaries
    for bug_dir in */; do
        bug="${bug_dir%/}"
        [ -f "$bug/run_experiment.sh" ] || continue
        fetch_experimental_results "$bug"
        fetch_apk "$bug"
    done
    fetch_common
    fetch_android_common
fi

[ "$FETCH_SOURCE" = "1" ] && fetch_source_bundles

echo "== done =="
