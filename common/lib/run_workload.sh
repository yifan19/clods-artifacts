#!/bin/bash
# Generic workload driver, run from the `master` container. Reads its parameters entirely from
# environment (set by each bug's bug.env, sourced by that bug's run_experiment.sh) so this one
# file is shared by every server-side bug rather than re-implementing the same baseline/round/
# collect loop 13 times. The actual load/run commands per workload are lifted close to verbatim
# from benchmark_scripts/benchmark_ycsb_hbase.sh, benchmark_ycsb_hbase_old.sh, benchmark_ycsb_zk.sh,
# benchmark_ycsb_cass.sh, and benchmark_yarn.sh.
#
# Required env: WORKLOAD, NUM, APP_NAME, APP_TARGET (master|slaves), ROUNDS ("1 2 3" ...),
#               HADOOP_NAME, SLAVE_HOSTS, RESULTS_DIR
# Workload-specific: YCSB_NAME/YCSB_BINDING (ycsb_*), HBASE_NAME, ZOOKEEPER_NAME, CASSANDRA_NAME,
#                     HIBENCH_NAME, ZK_NODE_CMD (ycsb_zk)
set -euo pipefail
cd /home/ubuntu
RESULTS_DIR=${RESULTS_DIR:-/results}
mkdir -p "$RESULTS_DIR"

target_hosts() {
    if [ "$APP_TARGET" = "master" ]; then echo "$MASTER_HOST"; else echo "$SLAVE_HOSTS"; fi
}

remote_run_n() {
    # remote_run_n <host> <run_n.sh args...>
    local host="$1"; shift
    if [ "$host" = "$MASTER_HOST" ] || [ "$host" = "master" ]; then
        INST_DIR=/plans "/opt/lib/run_n.sh" "$@"
    else
        ssh "$host" "INST_DIR=/plans /opt/lib/run_n.sh $*"
    fi
}

reset_cluster() {
    # The original benchmark_scripts/*.sh (benchmark_ycsb_hbase.sh, benchmark_ycsb_cass.sh, ...)
    # each start with a stop/clean/<component>/start sequence — every round in the real protocol
    # runs against a completely fresh cluster, so a previous round's injected fault (or any data
    # it left behind) can't leak into the next round. Baseline already gets this for free from
    # run_experiment.sh's own format+start immediately before this script runs, so this is only
    # needed between rounds.
    echo "== resetting cluster for a fresh round =="
    /opt/lib/cluster_ctl.sh clean
    /opt/lib/cluster_ctl.sh format
    /opt/lib/cluster_ctl.sh start
}

inject_round() {
    local round="$1"
    for host in $(target_hosts); do
        echo "== injecting round $round on $host (target process: $APP_NAME) =="
        remote_run_n "$host" inject "$APP_NAME"
        remote_run_n "$host" add "$round"
        sleep 5
    done
}

collect_phase() {
    # $1 = write|read (matches the original: collect runs once after load, once after run),
    # $2 = round name. Output file naming matches the real historical result dirs exactly
    # (e.g. write<name>_<host>.result — see bug2_r1/writer1_172.31.18.101.result in
    # experimental_results/), so a fresh run diffs directly against them.
    local label="$1" name="$2"
    for host in $(target_hosts); do
        remote_run_n "$host" collect | tee "$RESULTS_DIR/${label}${name}_${host}.result"
        collect_node_artifacts "$host" "${label}${name}_${host}"
    done
}

pull_path() {
    # $1 = host, $2 = is_local (1|0), $3 = remote path, $4 = local dest dir. Best-effort: silently
    # skips anything that doesn't exist there (most bugs only configure a subset of
    # Hadoop/HBase/ZooKeeper/Cassandra/HiBench, so most of these paths won't exist on any given
    # bug's nodes) rather than failing the whole collect step under `set -e`.
    local host="$1" is_local="$2" src="$3" dest="$4"
    mkdir -p "$dest"
    if [ "$is_local" = 1 ]; then
        if [ -e "$src" ]; then
            cp -r "$src"/. "$dest"/ 2>/dev/null || true
        fi
    else
        if ssh "$host" "[ -e '$src' ]" 2>/dev/null; then
            scp -rq "$host:$src/." "$dest/" 2>/dev/null || true
        fi
    fi
}

collect_node_artifacts() {
    # $1 = host, $2 = destination prefix (e.g. "writebaseline_slave1"). Pulls everything worth
    # keeping off that node: the instrumentation tool's raw /data dump (original
    # benchmark_scripts/*.sh did `scp $slave:'/data/*' ...`) and every configured component's log
    # directory — Hadoop always, HBase/ZooKeeper/Cassandra/HiBench only if this bug uses them.
    local host="$1" prefix="$2" is_local=0
    if [ "$host" = "$MASTER_HOST" ] || [ "$host" = "master" ]; then
        is_local=1
    fi

    pull_path "$host" "$is_local" "/data" "$RESULTS_DIR/${prefix}_data"
    pull_path "$host" "$is_local" "/home/ubuntu/${HADOOP_NAME}/logs" "$RESULTS_DIR/${prefix}_logs/hadoop"
    [ -n "${HBASE_NAME:-}" ] &&
        pull_path "$host" "$is_local" "/home/ubuntu/${HBASE_NAME}/logs" "$RESULTS_DIR/${prefix}_logs/hbase"
    [ -n "${ZOOKEEPER_NAME:-}" ] &&
        pull_path "$host" "$is_local" "/home/ubuntu/${ZOOKEEPER_NAME}/logs" "$RESULTS_DIR/${prefix}_logs/zookeeper"
    [ -n "${CASSANDRA_NAME:-}" ] &&
        pull_path "$host" "$is_local" "/home/ubuntu/${CASSANDRA_NAME}/logs" "$RESULTS_DIR/${prefix}_logs/cassandra"
    [ -n "${HIBENCH_NAME:-}" ] &&
        pull_path "$host" "$is_local" "/home/ubuntu/${HIBENCH_NAME}/report" "$RESULTS_DIR/${prefix}_logs/hibench"
    true
}

setup_once() {
    case "$WORKLOAD" in
    ycsb_hbase)
        echo "n_splits = 40
create '${YCSB_TABLE:-ycsb}', '${YCSB_CF:-cf}', {SPLITS => (1..n_splits).map {|i| \"user#{1000+i*(9999-1000)/n_splits}\"}}" \
            | "/home/ubuntu/${HBASE_NAME}/bin/hbase" shell
        ;;
    ycsb_hbase_old)
        echo "n_splits = 40
splits = (1..n_splits).map { |i| \"user#{1000 + i * (9999 - 1000) / n_splits}\" }
create '${YCSB_TABLE:-ycsb}', '${YCSB_CF:-cf}', splits" \
            | "/home/ubuntu/${HBASE_NAME}/bin/hbase" shell
        ;;
    ycsb_zk)
        for host in $SLAVE_HOSTS; do
            ssh "$host" "cd ~/$ZOOKEEPER_NAME && echo '${ZK_NODE_CMD:-create /benchmark}' | ./bin/zkCli.sh"
        done
        ;;
    ycsb_cass)
        local seed=$MASTER_HOST
        echo "create keyspace ycsb WITH REPLICATION = {'class':'SimpleStrategy','replication_factor':1};" \
            | "/home/ubuntu/${CASSANDRA_NAME}/bin/cqlsh" "$seed"
        echo "create table ycsb.usertable (
            y_id varchar primary key, field0 varchar, field1 varchar, field2 varchar,
            field3 varchar, field4 varchar, field5 varchar, field6 varchar, field7 varchar,
            field8 varchar, field9 varchar);" | "/home/ubuntu/${CASSANDRA_NAME}/bin/cqlsh" "$seed"
        sleep 5
        ;;
    hibench)
        : # both workloads (pagerank=write, terasort=read) are toggled per-round in run_hibench_pair
        ;;
    esac
}

run_ycsb() {
    # $1 = ycsb subcommand (load|run), $2 = round name (baseline|r1|r2|...)
    # Log filenames follow the ORIGINAL benchmark_scripts/*.sh convention exactly (write<name>.log /
    # read<name>.log, no separating underscore) — this matches the file names found in the real
    # historical result directories (ycsb-0.12.0/bug2_r1/writer1.log etc — see experimental_results/
    # in each bug folder), so a fresh run's output can be diffed directly against those.
    local op="$1" name="$2"
    local label; [ "$op" = "load" ] && label=write || label=read
    cd "/home/ubuntu/${YCSB_NAME}"
    case "$WORKLOAD" in
    ycsb_hbase|ycsb_hbase_old)
        ./bin/ycsb "$op" "${YCSB_BINDING}" -P workloads/workloada -s \
            -p recordcount="$NUM" -p table="${YCSB_TABLE:-ycsb}" -p columnfamily="${YCSB_CF:-cf}" \
            -p recordcolumn=f1 -p operationcount="$NUM" 2>&1 | tee "$RESULTS_DIR/${label}${name}.log"
        ;;
    ycsb_zk)
        ./bin/ycsb "$op" zookeeper -P workloads/workloada -s \
            -p recordcount="$NUM" -p operationcount="$NUM" 2>&1 | tee "$RESULTS_DIR/${label}${name}.log"
        ;;
    ycsb_cass)
        ./bin/ycsb "$op" cassandra-cql -P workloads/workloada -s \
            -p exportfile=result.csv -p recordcount="$NUM" -p operationcount="$NUM" \
            -p hosts="$MASTER_HOST" 2>&1 | tee "$RESULTS_DIR/${label}${name}.log"
        ;;
    esac
    cd /home/ubuntu
}

toggle_hibench_workload() {
    # $1=on|off $2=workload-name (e.g. websearch.pagerank)
    local list="/home/ubuntu/${HIBENCH_NAME}/conf/benchmarks.lst"
    if [ "$1" = "on" ]; then
        sed -i "s/^#${2//./\\.}$/${2}/" "$list"
    else
        sed -i "s/^${2//./\\.}$/#${2}/" "$list"
    fi
}

run_hibench_pair() {
    # Matches the original benchmark_yarn.sh: pagerank's report becomes this round's "write" log,
    # terasort's becomes "read" — both under the SAME single inject step, not two separate rounds.
    local name="$1"
    cd "/home/ubuntu/${HIBENCH_NAME}"
    toggle_hibench_workload on websearch.pagerank
    ./bin/run_all.sh 2>&1 | tee "$RESULTS_DIR/write_${name}.log"
    cp report/hibench.report "$RESULTS_DIR/write_report_${name}.tsv" 2>/dev/null || true
    toggle_hibench_workload off websearch.pagerank

    toggle_hibench_workload on micro.terasort
    ./bin/run_all.sh 2>&1 | tee "$RESULTS_DIR/read_${name}.log"
    cp report/hibench.report "$RESULTS_DIR/read_report_${name}.tsv" 2>/dev/null || true
    toggle_hibench_workload off micro.terasort
    cd /home/ubuntu
}

main() {
    setup_once

    echo "###### baseline ######"
    if [ "$WORKLOAD" = "hibench" ]; then
        run_hibench_pair baseline
    else
        run_ycsb load baseline
        collect_phase write baseline
        run_ycsb run baseline
        collect_phase read baseline
    fi

    for round in $ROUNDS; do
        echo "###### round r$round ######"
        reset_cluster
        setup_once
        inject_round "$round"
        if [ "$WORKLOAD" = "hibench" ]; then
            run_hibench_pair "r${round}"
        else
            run_ycsb load "r${round}"
            collect_phase write "r${round}"
            run_ycsb run "r${round}"
            collect_phase read "r${round}"
        fi
    done
    echo "###### done — results in $RESULTS_DIR ######"
}

main
