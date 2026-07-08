#!/bin/bash
# Captures logcat markers produced by either instrumentation path:
#   DEADBEEF/CLODS — bm_instrument's offline dex2jar-patched bytecode (see element*/results/*.txt
#                    for the exact format this matches: "DEADBEEF: START/END <op> = <ts>",
#                    "W CLODS : <value>")
#   [Agent]/[BM]   — ARTTI_instrument's JVMTI live-breakpoint agent
# Usage: collect_log.sh <output_file> [duration_seconds]
set -euo pipefail
OUT="${1:?usage: collect_log.sh <output_file> [duration_seconds]}"
DURATION="${2:-30}"

adb logcat -c
timeout "$DURATION" adb logcat | grep -E 'DEADBEEF|CLODS|\[Agent\]|\[BM\]' | tee "$OUT" || true
echo "[collect_log] wrote $OUT"
