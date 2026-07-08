#!/bin/bash
# Blocks until every host in SLAVE_HOSTS (space-separated) accepts SSH. Run from the master.
set -euo pipefail
for host in $SLAVE_HOSTS; do
    echo "[wait_for_ssh] waiting for $host..."
    tries=0
    until ssh -o ConnectTimeout=3 "$host" true 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -gt 60 ]; then
            echo "[wait_for_ssh] gave up waiting for $host after 60 tries" >&2
            exit 1
        fi
        sleep 2
    done
    echo "[wait_for_ssh] $host is up"
done
