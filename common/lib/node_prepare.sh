#!/bin/bash
# Runs on EVERY node (master + each slave) before daemons start. Idempotent: safe to re-run.
# Extracts whichever vendored tarballs this bug needs from the read-only /binaries mount into
# this node's $HOME, then renders that node's local config via render_config.py.
set -euo pipefail
cd /home/ubuntu

extract_once() {
    local name="$1" tarball="$2"
    if [ -z "$name" ]; then return 0; fi
    if [ -d "/home/ubuntu/$name" ]; then
        echo "[node_prepare] $name already extracted, skipping"
        return 0
    fi
    if [ ! -f "/binaries/$tarball" ]; then
        echo "[node_prepare] MISSING ARTIFACT: /binaries/$tarball not found." >&2
        echo "[node_prepare] See MISSING_ARTIFACTS.md at the repo root — fetch it and re-run." >&2
        exit 42
    fi
    echo "[node_prepare] extracting $tarball"
    tar xzf "/binaries/$tarball" -C /home/ubuntu/
    # Some older tarballs (e.g. hadoop-1.0.0) lose the executable bit on their bin/sbin
    # scripts in transit, causing "Permission denied" the first time cluster_ctl.sh runs them.
    # Re-set it defensively after every extraction rather than special-casing one version.
    for d in "/home/ubuntu/$name/bin" "/home/ubuntu/$name/sbin"; do
        if [ -d "$d" ]; then
            chmod +x "$d"/* 2>/dev/null || true
        fi
    done
    return 0
}

extract_once "$HADOOP_NAME"     "${HADOOP_NAME}.tar.gz"
extract_once "$HBASE_NAME"      "${HBASE_NAME}.tar.gz"
extract_once "$ZOOKEEPER_NAME"  "${ZOOKEEPER_NAME}.tar.gz"
extract_once "$CASSANDRA_NAME"  "${CASSANDRA_NAME}-bin.tar.gz"
extract_once "$YCSB_NAME"       "${YCSB_NAME}.tar.gz"
extract_once "$HIBENCH_NAME"    "${HIBENCH_NAME}.tar.gz"


if [ -n "${HADOOP_NAME:-}" ]; then
    python3 /opt/lib/render_config.py
fi
echo "[node_prepare] done on $(hostname)"
