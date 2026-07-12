#!/bin/bash
# Run Synapse *through* the Python-Instrumentation driver, so whatever hooks
# are currently listed in Python-Instrumentation/constants/hooks.py's
# USER_CALLABLES_TO_HOOK get bytecode-patched into Synapse at import time.
#
# This replaces the normal `python -m synapse.app.homeserver ...` invocation
# for a testing session — it is NOT what synapse-clods.service runs, so stop
# that first (same port 8008, they'll conflict):
#   systemctl stop synapse-clods
#
# Prereq: setup_instrumented_synapse.sh has already rebuilt
# /opt/synapse-clods/venv on Python 3.10 with `bytecode`/`setuptools` installed.
#
# Usage:
#   ./run_instrumented_synapse.sh              # foreground, Ctrl-C to stop
#   ./run_instrumented_synapse.sh -d            # background, logs to run.log
#   ./run_instrumented_synapse.sh -d stop       # stop the backgrounded run

set -euo pipefail

BASE=/opt/synapse-clods
VENV="$BASE/venv"
PI_DIR="${PI_DIR:-$BASE/Python-Instrumentation}"
PIDFILE="$BASE/instrumented_synapse.pid"
LOGFILE="$BASE/instrumented_synapse.log"

if [ "${1:-}" = "-d" ] && [ "${2:-}" = "stop" ]; then
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        kill "$(cat "$PIDFILE")"
        rm -f "$PIDFILE"
        echo "stopped."
    else
        echo "not running (no valid $PIDFILE)."
    fi
    exit 0
fi

if [ ! -x "$VENV/bin/python" ] || [ ! -f "$PI_DIR/driver.py" ]; then
    echo "Missing $VENV or $PI_DIR/driver.py — run setup_instrumented_synapse.sh first." >&2
    exit 1
fi

if systemctl is-active --quiet synapse-clods 2>/dev/null; then
    echo "synapse-clods.service is running and would fight over port 8008." >&2
    echo "Run: systemctl stop synapse-clods" >&2
    exit 1
fi

cd "$PI_DIR"

CMD=("$VENV/bin/python" driver.py -m synapse.app.homeserver "--config-path=$BASE/homeserver.yaml")

if [ "${1:-}" = "-d" ]; then
    nohup "${CMD[@]}" > "$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    echo "started in background, pid $(cat "$PIDFILE"), logs: $LOGFILE"
    echo "stop with: $0 -d stop"
else
    echo "== running in foreground (Ctrl-C to stop) =="
    echo "== watch for 'Hooked API'/'Hooked method' lines below to confirm hooks armed =="
    exec "${CMD[@]}"
fi
