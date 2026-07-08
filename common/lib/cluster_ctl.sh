#!/bin/bash
# Cluster lifecycle controller — run from the `master` container. Equivalent of the original
# script_archive/old_setup.sh's gen/clean/start/stop targets, adapted for docker-compose (no key
# distribution needed, that's baked into the shared base image; no SCP needed, /binaries and
# /plans are bind-mounted identically into every node).
#
# Usage: cluster_ctl.sh {prepare|format|start|stop|clean|status}
#
# Required env (set by docker-compose.yml / bug.env): HADOOP_NAME, HBASE_NAME (optional),
# ZOOKEEPER_NAME (optional), CASSANDRA_NAME (optional), YCSB_NAME (optional), HIBENCH_NAME
# (optional), ENABLE_YARN (0/1), SLAVE_HOSTS (space-separated hostnames), MASTER_HOST.
set -euo pipefail
cd /home/ubuntu
HADOOP_DIR="/home/ubuntu/${HADOOP_NAME:?HADOOP_NAME not set}"
hadoop_sbin() { [ -d "$HADOOP_DIR/sbin" ] && echo "$HADOOP_DIR/sbin" || echo "$HADOOP_DIR/bin"; }

cmd_prepare() {
    echo "== prepare: extracting + configuring every node =="
    # Each node's own docker-compose `environment:` (HADOOP_NAME, ZK_MYID, etc.) reaches its SSH
    # sessions via ~/.ssh/environment, populated by entrypoint.sh at container start — see the
    # PermitUserEnvironment note in ../Dockerfile. So node_prepare.sh on the remote end picks up
    # its own correct values (e.g. each slave's own ZK_MYID) without us threading them through here.
    /opt/lib/node_prepare.sh
    for host in $SLAVE_HOSTS; do
        ssh "$host" "/opt/lib/node_prepare.sh"
    done
}

cmd_format() {
    echo "== format: namenode =="
    rm -rf /tmp/hadoop-ubuntu

    "$HADOOP_DIR/bin/hadoop" namenode -format -force
    for host in $SLAVE_HOSTS; do
        ssh "$host" "rm -rf /tmp/hadoop-ubuntu"
    done
}

cmd_start() {
    echo "== start: HDFS =="
    "$(hadoop_sbin)/start-dfs.sh"
    sleep 5

    if [ -n "${ZOOKEEPER_NAME:-}" ]; then
        echo "== start: ZooKeeper ensemble (on slaves) =="
        for host in $SLAVE_HOSTS; do
            ssh "$host" "cd ~/$ZOOKEEPER_NAME && ./bin/zkServer.sh start"
        done
        sleep 5
    fi

    if [ -n "${HBASE_NAME:-}" ]; then
        echo "== start: HBase =="
        "/home/ubuntu/${HBASE_NAME}/bin/start-hbase.sh"
        sleep 5
    fi

    if [ "${ENABLE_YARN:-0}" = "1" ]; then
        echo "== start: YARN =="
        "$(hadoop_sbin)/start-yarn.sh"
        sleep 5
    fi

    if [ -n "${CASSANDRA_NAME:-}" ]; then
        echo "== start: Cassandra (single seed on master) =="
        "/home/ubuntu/${CASSANDRA_NAME}/bin/cassandra" -p /tmp/cassandra.pid
        sleep 15
    fi
    echo "== cluster up =="
}

cmd_stop() {
    [ -n "${CASSANDRA_NAME:-}" ] && [ -f /tmp/cassandra.pid ] && kill "$(cat /tmp/cassandra.pid)" 2>/dev/null || true
    [ "${ENABLE_YARN:-0}" = "1" ] && "$(hadoop_sbin)/stop-yarn.sh" || true
    [ -n "${HBASE_NAME:-}" ] && "/home/ubuntu/${HBASE_NAME}/bin/stop-hbase.sh" || true
    if [ -n "${ZOOKEEPER_NAME:-}" ]; then
        for host in $SLAVE_HOSTS; do
            ssh "$host" "cd ~/$ZOOKEEPER_NAME && ./bin/zkServer.sh stop" || true
        done
    fi
    "$(hadoop_sbin)/stop-dfs.sh" || true
}

cmd_clean() {
    cmd_stop || true
    # /tmp/hbase-ubuntu is HBase's default hbase.tmp.dir, which is also where HBase's embedded
    # ZooKeeper (HBASE_MANAGES_ZK=true, see render_config.py) keeps its data. Without wiping it
    # here, a "reformat" leaves stale table/region metadata behind in ZK even though the
    # underlying HDFS data is gone — "Table already exists" on recreate, then
    # TableNotFoundException once the workload actually tries to use it.
    for host in $SLAVE_HOSTS master; do
        [ "$host" = "master" ] && continue
        ssh "$host" 'killall -q -9 java 2>/dev/null; rm -rf /tmp/hadoop-ubuntu* /tmp/hbase-ubuntu* /home/ubuntu/zk_storage' || true
    done
    killall -q -9 java 2>/dev/null || true
    rm -rf /tmp/hadoop-ubuntu* /tmp/hbase-ubuntu* /home/ubuntu/zk_storage
}

cmd_status() {
    echo "master: $(jps || true)"
    for host in $SLAVE_HOSTS; do
        echo "$host: $(ssh "$host" jps || true)"
    done
}

case "${1:-}" in
    prepare) cmd_prepare ;;
    format)  cmd_format ;;
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    clean)   cmd_clean ;;
    status)  cmd_status ;;
    *) echo "usage: $0 {prepare|format|start|stop|clean|status}" >&2; exit 1 ;;
esac
