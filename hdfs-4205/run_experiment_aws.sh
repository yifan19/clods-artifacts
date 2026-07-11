#!/bin/bash
# HDFS-4205 — Fsck fails with symlinks — real 4-node AWS cluster variant of ./run_experiment.sh.
#
# ./run_experiment.sh runs all 4 nodes (master + slave1/2/3) as docker-compose containers sharing
# one host's kernel/network namespace. This script instead drives 4 real, separate EC2 instances
# over SSH — to test whether genuine host/network isolation (as the original historical
# reproduction actually had — see experimental_results/'s 4 real AWS IPs) changes whether
# HDFS-4205's symptom reproduces, versus this artifact's docker-compose simplification.
#
# It deliberately reuses every orchestration script under ../common/lib/ UNCHANGED (cluster_ctl.sh,
# node_prepare.sh, run_workload.sh, run_n.sh, render_config.py) — they already do everything purely
# via hostnames + env vars over SSH, with no docker-specific assumptions. Only the bootstrap (OS
# packages, directory layout, SSH trust, env propagation) that ../common/Dockerfile normally bakes
# into the image is redone here against real hosts.
#
# Setup:
#   1. Launch 4 EC2 instances (plain Ubuntu — 20.04 or 24.04, both confirmed below), all in one
#      security group that allows all TCP traffic between its own members (HDFS/HBase/ZooKeeper use
#      several ports; easiest to just open them all to each other rather than enumerate every one).
#   2. cp hosts.env.example hosts.env, fill in your 4 real hosts + SSH key (same key on all 4 is
#      simplest — see hosts.env.example's comment on why).
#   3. ./run_experiment_aws.sh
#
# OS note: ../common/Dockerfile's base image gets python2 from apt (ubuntu:20.04 still packages
# it) and symlinks /usr/bin/python2 + /usr/bin/python to it. 24.04 dropped python2 packaging
# entirely (confirmed: no apt candidate), so this instead deploys a vendored, from-source Python
# 2.7.18 build (see ./build_python2.sh, ../binaries/python-2.7.18-ubuntu24.04-x86_64.tar.gz) and
# symlinks the same two paths to it — same end state on every OS version, not dependent on whatever
# a given distro still happens to carry. Nothing this script actually runs calls python2 itself
# (node_prepare.sh invokes render_config.py via `python3` explicitly; the vendored tarballs' own
# `.py` files, e.g. zookeeper-3.4.6's src/contrib/, are unused source-only extras) — this is purely
# defensive parity with the Docker image, in case some vendored old script silently expects a bare
# `python`/`python2` to resolve to Python 2 semantics. openjdk-8-jdk, by contrast, IS confirmed
# available via apt on both 20.04 and 24.04 (universe repo) — no vendoring needed there.
#
# Results land in ./results_aws/ (kept separate from run_experiment.sh's ./results/). Cluster
# daemons are stopped at the end (pass --keep to leave them running for manual inspection); the EC2
# instances themselves are never touched (started/stopped/terminated) by this script — that's yours
# to manage.
set -euo pipefail
cd "$(dirname "$0")"

[ -f hosts.env ] || {
    echo "hosts.env not found. cp hosts.env.example hosts.env and fill in your 4 real hosts first." >&2
    exit 1
}
# shellcheck disable=SC1091
source hosts.env
: "${MASTER_HOST:?set in hosts.env}"
: "${SLAVE_HOSTS:?set in hosts.env}"
: "${SSH_KEY:?set in hosts.env}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY/#\~/$HOME}"
ALL_HOSTS="$MASTER_HOST $SLAVE_HOSTS"

MISSING=0
[ -f ../binaries/hadoop-0.23.9-SNAPSHOT.tar.gz ] || { echo "[MISSING] binaries/hadoop-0.23.9-SNAPSHOT.tar.gz" >&2; MISSING=1; }
[ -f ../binaries/hbase-1.0.0.tar.gz ] || { echo "[MISSING] binaries/hbase-1.0.0.tar.gz" >&2; MISSING=1; }
[ -f ../binaries/zookeeper-3.4.6.tar.gz ] || { echo "[MISSING] binaries/zookeeper-3.4.6.tar.gz" >&2; MISSING=1; }
[ -f ../binaries/ycsb-0.12.0.tar.gz ] || { echo "[MISSING] binaries/ycsb-0.12.0.tar.gz" >&2; MISSING=1; }
[ -f ../binaries/python-2.7.18-ubuntu24.04-x86_64.tar.gz ] || { echo "[MISSING] binaries/python-2.7.18-ubuntu24.04-x86_64.tar.gz (run ./build_python2.sh)" >&2; MISSING=1; }
if [ "$MISSING" = "1" ]; then
    echo "Refusing to start: see the [MISSING] lines above. Fetch the listed file(s) into" >&2
    echo "final_artifact/binaries/ (see ../MISSING_ARTIFACTS.md), then re-run this script." >&2
    exit 42
fi

ssh_opts=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
remote() { local host="$1"; shift; ssh "${ssh_opts[@]}" "${SSH_USER}@${host}" "$@"; }

# Same values as ../manifest.py's hdfs-4205 entry / ./docker-compose.yml — kept in one place there,
# duplicated here since there's no docker-compose to source them from on real hosts.
APP_NAME="${APP_NAME_OVERRIDE:-DataNode}"
APP_TARGET="${APP_TARGET_OVERRIDE:-slaves}"
bug_env_lines() {  # $1 = this host's ZK_MYID, or "" for master
    cat <<EOF
HADOOP_NAME=hadoop-0.23.9-SNAPSHOT
HBASE_NAME=hbase-1.0.0
ZOOKEEPER_NAME=zookeeper-3.4.6
CASSANDRA_NAME=
YCSB_NAME=ycsb-0.12.0
YCSB_BINDING=hbase10
YCSB_TABLE=ycsb
YCSB_CF=cf
HIBENCH_NAME=
HIBENCH_WORKLOAD=
ZK_NODE_CMD=
WORKLOAD=ycsb_hbase
APP_NAME=$APP_NAME
APP_TARGET=$APP_TARGET
NUM=1000000
ROUNDS=baseline 1 2
ENABLE_YARN=0
MASTER_HOST=$MASTER_HOST
SLAVE_HOSTS=$SLAVE_HOSTS
RESULTS_DIR=/results
JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
EOF
    [ -n "${1:-}" ] && echo "ZK_MYID=$1"
    return 0
}

echo "== [1/6] bootstrapping OS packages + directory layout on all 4 hosts =="
for host in $ALL_HOSTS; do
    echo "-- $host --"
    remote "$host" '
        set -e
        # NEEDRESTART_SUSPEND: Ubuntu 22.04+/24.04'"'"'s stock AMIs ship needrestart, which by
        # default pauses apt-get with an interactive "which services should be restarted?" prompt —
        # fatal here since this whole block runs over a non-interactive `ssh host "..."` with no
        # tty to answer it. DEBIAN_FRONTEND=noninteractive alone does not suppress this (needrestart
        # is a separate dpkg hook, not a debconf frontend). Harmless on 20.04, which lacks the
        # package entirely.
        export NEEDRESTART_SUSPEND=1
        sudo -E apt-get update -qq
        sudo -E DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
            openjdk-8-jdk openssh-server python3 net-tools iproute2 procps psmisc curl >/dev/null
        sudo mkdir -p /opt/lib /binaries /plans /data /results
        sudo chown -R "$(whoami)":"$(whoami)" /opt/lib /binaries /plans /data /results
        sudo sed -i "s/#\?PermitUserEnvironment.*/PermitUserEnvironment yes/" /etc/ssh/sshd_config
        grep -q "^PermitUserEnvironment yes" /etc/ssh/sshd_config || \
            echo "PermitUserEnvironment yes" | sudo tee -a /etc/ssh/sshd_config >/dev/null
        sudo systemctl restart ssh
        printf "Host *\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n  LogLevel ERROR\n" > ~/.ssh/config
        chmod 600 ~/.ssh/config
    '
done

echo "== [2/6] setting up master -> slave SSH trust =="
# Master needs to SSH into every slave with no -i/-l flags (cluster_ctl.sh/run_workload.sh call
# plain `ssh "$host" ...`, matching the original bare-metal cluster scripts) — give it the same key
# used to reach all 4 hosts from here, and make sure that key's pubkey is trusted everywhere.
PUBKEY=$(ssh-keygen -y -f "$SSH_KEY")
for host in $ALL_HOSTS; do
    remote "$host" "grep -qxF '$PUBKEY' ~/.ssh/authorized_keys 2>/dev/null || echo '$PUBKEY' >> ~/.ssh/authorized_keys"
done
scp -q "${ssh_opts[@]}" "$SSH_KEY" "${SSH_USER}@${MASTER_HOST}:.ssh/id_rsa"
remote "$MASTER_HOST" "chmod 600 ~/.ssh/id_rsa"

echo "== [3/6] deploying orchestration scripts + instrumentation jar + binaries + plans =="
# Individual-file scp (not `scp -r somedir/.`) throughout: /opt/lib, /binaries and /plans already
# exist from bootstrap above, and `scp -r srcdir host:existingdir/` nests srcdir itself one level
# deeper instead of copying its contents into it — glob the sources locally instead so each file
# lands directly where the orchestration scripts under ../common/lib/ expect it.
for host in $ALL_HOSTS; do
    echo "-- $host --"
    scp -q "${ssh_opts[@]}" ../common/lib/*.sh ../common/lib/render_config.py \
        "${SSH_USER}@${host}:/opt/lib/"
    remote "$host" "chmod +x /opt/lib/*.sh"
    scp -q "${ssh_opts[@]}" ../common/blameMasterInstrument.jar \
        "${SSH_USER}@${host}:/opt/blameMasterInstrument.jar"
    scp -q "${ssh_opts[@]}" \
        ../binaries/hadoop-0.23.9-SNAPSHOT.tar.gz ../binaries/hbase-1.0.0.tar.gz \
        ../binaries/zookeeper-3.4.6.tar.gz ../binaries/ycsb-0.12.0.tar.gz \
        ../binaries/python-2.7.18-ubuntu24.04-x86_64.tar.gz \
        "${SSH_USER}@${host}:/binaries/"
    scp -rq "${ssh_opts[@]}" ./plans/* "${SSH_USER}@${host}:/plans/"
    # See the "OS note" above: gives every host the same /usr/bin/python2 + /usr/bin/python as
    # ../common/Dockerfile's image, regardless of what (if anything) that OS version's apt carries.
    remote "$host" '
        sudo tar xzf /binaries/python-2.7.18-ubuntu24.04-x86_64.tar.gz -C /opt/
        sudo ln -sf /opt/python2.7.18/bin/python2.7 /usr/bin/python2
        sudo ln -sf /opt/python2.7.18/bin/python2.7 /usr/bin/python
    '
done

echo "== [4/6] writing per-host environment (../common/entrypoint.sh's trick, for real sshd) =="
bug_env_lines "" | remote "$MASTER_HOST" "cat > ~/.ssh/environment && chmod 600 ~/.ssh/environment"
i=1
for host in $SLAVE_HOSTS; do
    bug_env_lines "$i" | remote "$host" "cat > ~/.ssh/environment && chmod 600 ~/.ssh/environment"
    i=$((i + 1))
done

echo "== [5/6] preparing, formatting, starting the cluster, then running the workload =="
echo "-- waiting for slaves over ssh (from master) --"
remote "$MASTER_HOST" "/opt/lib/wait_for_ssh.sh"
echo "-- prepare (extract vendored tarballs + render config on every node) --"
remote "$MASTER_HOST" "/opt/lib/cluster_ctl.sh prepare"
echo "-- format + start --"
remote "$MASTER_HOST" "/opt/lib/cluster_ctl.sh format"
remote "$MASTER_HOST" "/opt/lib/cluster_ctl.sh start"
echo "-- running baseline + rounds [1 2] --"
remote "$MASTER_HOST" "/opt/lib/run_workload.sh"

echo "== [6/6] stopping cluster daemons + pulling results =="
if [ "${1:-}" != "--keep" ]; then
    remote "$MASTER_HOST" "/opt/lib/cluster_ctl.sh stop" || true
else
    echo "--keep passed: daemons left running. ssh -i $SSH_KEY $SSH_USER@$MASTER_HOST to poke around."
fi
mkdir -p results_aws
# Remote-side glob (expanded by the remote shell scp invokes), not `scp -r host:/results/. dest/` —
# same nested-directory trap as the push helper above, avoided the same way.
scp -rq "${ssh_opts[@]}" "${SSH_USER}@${MASTER_HOST}:/results/*" results_aws/

echo "== done. Results in ./results_aws/ (diff against ./experimental_results/ for the real historical run) =="
