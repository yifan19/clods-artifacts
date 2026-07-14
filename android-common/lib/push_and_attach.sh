#!/bin/bash
# Pushes this round's offline-patched classfile(s) (from patch_round.py's patch_manifest.json)
# into the running app's private storage and live-attaches libagent_retransform.so, which uses
# JVMTI's ClassFileLoadHook + RetransformClasses to swap in the patched bytecode of the
# already-running process — the same technique as the real production agent_element.cpp (see
# ROUND_DEX_MAP.md and ANDROID_README.md for provenance).
#
# Usage: push_and_attach.sh <round_workdir> <package> <path-to-libagent_retransform.so>
# No-ops (with a clear message) if the app isn't running or this round produced no patched class —
# offline patching (out/*.dex under round_workdir) still succeeded regardless.
set -euo pipefail
WORKDIR="${1:?usage: push_and_attach.sh <round_workdir> <package> <agent.so>}"
PACKAGE="${2:?usage: push_and_attach.sh <round_workdir> <package> <agent.so>}"
AGENT_SO="${3:?usage: push_and_attach.sh <round_workdir> <package> <agent.so>}"
MANIFEST="$WORKDIR/patch_manifest.json"

if [ ! -s "$MANIFEST" ]; then
    echo "[push_and_attach] no patch_manifest.json at $MANIFEST — nothing to attach" >&2
    exit 0
fi

PID=$(adb shell pidof "$PACKAGE" | tr -d '\r')
if [ -z "$PID" ]; then
    echo "[push_and_attach] $PACKAGE not running — skipping live attach" >&2
    exit 0
fi

adb push "$AGENT_SO" /data/local/tmp/libagent_retransform.so
adb shell run-as "$PACKAGE" cp /data/local/tmp/libagent_retransform.so ./libagent_retransform.so
adb shell run-as "$PACKAGE" mkdir -p files

python3 -c "
import json
for e in json.load(open('$MANIFEST')):
    print(e['class'] + '\t' + e['patched_class'])
" | while IFS=$'\t' read -r CLASS PATCHED_CLASS; do
    [ -z "$CLASS" ] && continue
    BASENAME=$(basename "$PATCHED_CLASS")
    adb push "$PATCHED_CLASS" "/data/local/tmp/$BASENAME"
    adb shell run-as "$PACKAGE" cp "/data/local/tmp/$BASENAME" "./files/$BASENAME"
    echo "[push_and_attach] attaching for class=$CLASS file=$BASENAME"
    adb shell cmd activity attach-agent "$PID" \
        "/data/user/0/$PACKAGE/libagent_retransform.so=class=$CLASS,file=/data/data/$PACKAGE/files/$BASENAME" || \
        echo "[push_and_attach] attach-agent failed for $CLASS — see ../ANDROID_README.md" >&2
done
