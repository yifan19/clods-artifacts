#!/bin/bash
# Start (or stop, or check) the Synapse instance for one specific bug, using the tagged
# images from PER_BUG_BUILD_GUIDE.md (clods-synapse:516/6782/5132/7643/7516) against the
# same persistent ./data/ this folder's setup.sh already configured (real server_name,
# postgres or sqlite, whatever setup.sh set up) -- so switching bugs only swaps which
# Synapse binary is running, accounts/config/domain setup carry over.
#
# Only one bug's server runs at a time (single fixed container name, port 8008) -- this
# is NOT the same thing as build_and_test_all_bugs.sh, which spins up disposable
# throwaway-config instances one at a time purely to smoke-test that each image starts.
#
# Usage:
#   ./run_bug.sh <bug>     # e.g. ./run_bug.sh 516 -- stops whatever's running, starts this one
#   ./run_bug.sh stop      # stop, don't start anything else
#   ./run_bug.sh status    # which bug (if any) is currently running

set -euo pipefail
cd "$(dirname "$0")"

NAME="clods-synapse-active"
VALID_BUGS=(516 6782 5132 7643 7516)

case "${1:-}" in
    ""|-h|--help)
        echo "Usage: $0 <${VALID_BUGS[*]// /|}>  |  $0 stop  |  $0 status" >&2
        exit 1
        ;;
    stop)
        docker rm -f "$NAME" >/dev/null 2>&1 && echo "stopped." || echo "not running."
        exit 0
        ;;
    status)
        RUNNING="$(docker inspect "$NAME" --format='{{.State.Running}}' 2>/dev/null || echo false)"
        if [ "$RUNNING" = "true" ]; then
            TAG="$(docker inspect "$NAME" --format='{{.Config.Image}}')"
            echo "running: $TAG"
            curl -fsS http://127.0.0.1:8008/health >/dev/null 2>&1 && echo "health: OK" || echo "health: not responding"
        else
            echo "nothing running."
        fi
        exit 0
        ;;
esac

BUG="$1"
FOUND=0
for b in "${VALID_BUGS[@]}"; do [ "$b" = "$BUG" ] && FOUND=1; done
if [ "$FOUND" != 1 ]; then
    echo "Unknown bug '$BUG'. Valid: ${VALID_BUGS[*]}" >&2
    exit 1
fi

if ! docker image inspect "clods-synapse:$BUG" >/dev/null 2>&1; then
    echo "clods-synapse:$BUG doesn't exist locally -- build it first, see PER_BUG_BUILD_GUIDE.md" >&2
    echo "(or run ./build_and_test_all_bugs.sh, which builds all 5)" >&2
    exit 1
fi
if [ ! -f data/homeserver.yaml ]; then
    echo "./data/homeserver.yaml not found -- run ./setup.sh <public-ip> first." >&2
    exit 1
fi

echo "== stopping whatever's currently running =="
docker rm -f "$NAME" >/dev/null 2>&1 || true

echo "== starting clods-synapse:$BUG =="
docker run -d --name "$NAME" -p 127.0.0.1:8008:8008 -v "$(pwd)/data:/data" "clods-synapse:$BUG" >/dev/null

for i in $(seq 1 20); do
    if curl -fsS http://127.0.0.1:8008/health >/dev/null 2>&1; then
        echo "$BUG: OK, responding on :8008"
        exit 0
    fi
    sleep 2
done

echo "$BUG: no response after 40s -- check: docker logs $NAME" >&2
exit 1
