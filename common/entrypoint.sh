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
    val="${!var:-}"
    [ -n "$val" ] && echo "${var}=${val}" >> /home/ubuntu/.ssh/environment
done
chown ubuntu:ubuntu /home/ubuntu/.ssh/environment
chmod 600 /home/ubuntu/.ssh/environment

exec /usr/sbin/sshd -D
