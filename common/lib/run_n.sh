#!/bin/bash
# Adapted from ../../../bm_instrument/script_archive/run_n.sh (the original per-node instrumentation
# driver). Two changes from the original, both flagged here rather than silently carried over:
#
#  1. BUG FIX: the checked-in original's `inject` branch always searched `jps` for the literal
#     string " namenode" (`jps | grep -i ' namenode'`), ignoring the `$2` app-name argument that
#     every caller in benchmark_scripts/*.sh actually passes (e.g. `run_n.sh inject HRegionServer`).
#     As checked in, it would only ever have worked for NameNode-hosted bugs. This copy uses `$2`
#     for the jps filter, which is clearly the original intent (every call site passes it).
#  2. Paths repointed at this artifact's layout: the jar is vendored at /opt/blameMasterInstrument.jar
#     (no per-node build needed) and instrumentation plans are bind-mounted read-only at /plans.
#
# Usage (run locally on the node hosting the target JVM):
#   run_n.sh inject <AppNameSubstring>      # attach the agent to the matching running JVM
#   run_n.sh add <round-number>             # apply every /plans/round<N>/*.properties (skips .disabled)
#   run_n.sh collect                        # dump everything logged by active probes so far
#
# Plan layout: /plans/round<N>/<id>.properties[.disabled] — same layout used by the Android bugs
# (see final_artifact/README.md's "Instrumentation plan layout" section), not the flat
# r<N>_<id>.properties layout bm_instrument's own server-bugs/ folders use on disk.
set -uo pipefail

INSTRUMENTATION_JAR=/opt/blameMasterInstrument.jar
PLAN_DIR=${INST_DIR:-/plans}

case "${1:-}" in
inject)
    appname="${2:?usage: run_n.sh inject <AppNameSubstring>}"
    testpid=$(jps | grep -i "$appname" | awk '{print $1}' | head -n1)
    if [ -z "$testpid" ]; then
        echo "[run_n] no running JVM matching '$appname' found in: $(jps)" >&2
        exit 1
    fi
    echo "[run_n] attaching to pid $testpid ($appname)"
    java -cp "$JAVA_HOME/lib/tools.jar:$INSTRUMENTATION_JAR" \
        ca.uoft.drsg.bminstrument.Launcher "$INSTRUMENTATION_JAR" "$testpid"
    ;;
add)
    round="${2:?usage: run_n.sh add <round-number>}"
    shopt -s nullglob
    plans=("$PLAN_DIR"/round"${round}"/*.properties)
    shopt -u nullglob
    if [ ${#plans[@]} -eq 0 ]; then
        echo "[run_n] no plans matched $PLAN_DIR/round${round}/*.properties" >&2
        exit 1
    fi
    for plan in "${plans[@]}"; do
        case "$plan" in *.disabled) continue ;; esac
        echo "[run_n] add $plan"
        java -cp "$JAVA_HOME/lib/tools.jar:$INSTRUMENTATION_JAR" \
            ca.uoft.drsg.bminstrument.PseudoClient "add $plan"
    done
    ;;
collect)
    java -cp "$JAVA_HOME/lib/tools.jar:$INSTRUMENTATION_JAR" \
        ca.uoft.drsg.bminstrument.PseudoClient "collect all"
    ;;
*)
    echo "usage: $0 {inject <AppNameSubstring>|add <round>|collect}" >&2
    exit 1
    ;;
esac
