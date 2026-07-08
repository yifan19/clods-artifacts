#!/bin/bash
# Container entrypoint: propagates docker-compose's per-bug env vars into SSH sessions (see the
# PermitUserEnvironment note in ../Dockerfile), then starts sshd in the foreground (PID 1).
# All actual experiment orchestration happens via `docker compose exec master ...`
# (which itself reaches into slave1/slave2/slave3 over ssh, matching the original cluster scripts).
set -e

ENV_WHITELIST="HADOOP_NAME HBASE_NAME ZOOKEEPER_NAME CASSANDRA_NAME YCSB_NAME YCSB_BINDING \
YCSB_TABLE YCSB_CF HIBENCH_NAME HIBENCH_WORKLOAD ZK_NODE_CMD WORKLOAD APP_NAME APP_TARGET NUM \
ROUNDS ENABLE_YARN MASTER_HOST SLAVE_HOSTS ZK_MYID DFS_REPLICATION RESULTS_DIR JAVA_HOME"

: > /home/ubuntu/.ssh/environment
for var in $ENV_WHITELIST; do
    # Forward the var whenever docker-compose set it, even to "" — bugs that don't use e.g.
    # Zookeeper/Cassandra leave that NAME var as "" in environment:, which `docker compose exec`
    # on master sees as set-but-empty; a fresh `ssh slaveN` login only gets what's in this file, so
    # dropping empty values here left the var fully unset there, tripping node_prepare.sh's
    # `set -u`. But some whitelisted vars (e.g. DFS_REPLICATION) are never set by any bug's
    # docker-compose.yml at all, and their consumers rely on that true absence to fall back to a
    # computed default — so presence (${!var+x}), not non-emptiness, is the right test here.
    if [ -n "${!var+x}" ]; then
        echo "${var}=${!var}" >> /home/ubuntu/.ssh/environment
    fi
done
chown ubuntu:ubuntu /home/ubuntu/.ssh/environment
chmod 600 /home/ubuntu/.ssh/environment

exec /usr/sbin/sshd -D
