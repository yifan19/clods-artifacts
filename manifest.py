"""
Manifest of the 13 server-side bugs, sourced from:
  - ~/artifacts/bm_instrument/README.md  (folder <-> bug id mapping)
  - ~/artifacts/benchmark_scripts/master_*.sh  (exact versions, NUM, APP_NAME actually run)
  - ~/artifacts/bm_instrument/server-bugs/instrumentation_*/  (rounds present, symptom.properties)
  - ~/artifacts/bm_instrument/ARTIFACT_EVALUATION.md  (the version matrix this was cross-checked against)

`app_target` is a clean re-derivation for this Docker topology (master = NameNode/ResourceManager/
HMaster/Cassandra-seed, slaves = DataNode/RegionServer/ZooKeeper), NOT always a literal copy of
which host the original ad-hoc EC2 scripts happened to SSH into (those are inconsistent research
scripts, not a clean architecture — see each bug's generated README for the literal original
command this was derived from).

Every `.tar.gz` name below must exist in final_artifact/binaries/ for that bug to run; the
generator flags any that don't (see MISSING_ARTIFACTS.md).
"""

BUGS = [
    dict(
        id="hdfs-9276",
        title="Private token expires in HA mode",
        jira="HDFS-9276",
        src_plans="server-bugs/instrumentation_bug10",
        hadoop_name="hadoop-2.8.1-SNAPSHOT",
        hbase_name="hbase-1.2.5",
        ycsb_name="ycsb-0.12.0",
        ycsb_binding="hbase10",
        workload="ycsb_hbase",
        app_name="Namenode",
        app_target="master",
        num=1000000,
        rounds=["baseline", 1],
        origin_cmd="master_dfsio.sh: HADOOP_NAME=hadoop-2.8.1-SNAPSHOT HBASE_NAME=hbase-1.2.5 "
                    "benchmark_ycsb_hbase.sh {add|baseline} 1 1000000 bug10_y Namenode",
        hist_root="ycsb-0.12.0", hist_prefix="bug10_y",
    ),
    dict(
        id="hdfs-11896",
        title="Wrong metadata caused by re-registration",
        jira="HDFS-11896",
        src_plans="server-bugs/instrumentation_bug3",
        hadoop_name="hadoop-2.7.4-SNAPSHOT",
        hbase_name="hbase-1.2.5",
        ycsb_name="ycsb-0.12.0",
        ycsb_binding="hbase10",
        workload="ycsb_hbase",
        app_name="Namenode",
        app_target="master",
        num=1000000,
        rounds=["baseline", 1, 2],
        origin_cmd="master_dfsio.sh: HADOOP_NAME=hadoop-2.7.4-SNAPSHOT "
                    "benchmark_ycsb_hbase.sh {add|baseline} 1 1000000 bug3 Namenode "
                    "(HBASE_NAME/YCSB_NAME are that script's defaults, not bug-specific pins)",
        hist_root="ycsb-0.12.0", hist_prefix="bug3",
    ),
    dict(
        id="hdfs-12638",
        title="FSCK failure caused by truncate & delete",
        jira="HDFS-12638",
        src_plans="server-bugs/instrumentation_bug2",
        hadoop_name="hadoop-2.8.2",
        hbase_name="hbase-1.2.5",
        ycsb_name="ycsb-0.12.0",
        ycsb_binding="hbase10",
        zookeeper_name='zookeeper-3.4.6',
        workload="ycsb_hbase",
        app_name="Namenode",
        app_target="master",
        num=1000000,
        rounds=["baseline", 1, 2],
        origin_cmd="master_dfsio.sh: HADOOP_NAME=hadoop-2.8.2 "
                    "benchmark_ycsb_hbase.sh {add|baseline} 1 1000000 bug2 Namenode",
        notes="Raw r0/r2/r3 logs already exist locally in server-bugs/instrumentation_bug2 "
              "(r0_logs.txt, r2_logs.txt, r2_logs_prod.txt, r3_logs.txt) — you can sanity-check "
              "against those without a full rerun. No r3_*.properties are checked in even though "
              "r3_logs.txt exists, so round 3 cannot be replayed here (only 1 and 2 are).",
        hist_root="ycsb-0.12.0", hist_prefix="bug2",
    ),
    dict(
        id="hdfs-1540",
        title="DataNode early exited at Namenode crash",
        jira="HDFS-1540",
        src_plans="server-bugs/instrumentation_hdfs1540",
        hadoop_name="hadoop-1.0.0",
        hbase_name="hbase-0.94.27",
        zookeeper_name="zookeeper-3.4.5",
        ycsb_name="ycsb-0.12.0",
        ycsb_binding="hbase094",
        workload="ycsb_hbase",
        app_name="DataNode",
        app_target="slaves",
        num=1000000,
        rounds=["baseline", 1],
        origin_cmd="master_stress.sh: HADOOP_NAME=hadoop-1.0.0 HBASE_NAME=hbase-0.94.27 "
                    "ZOOKEEPER_NAME=zookeeper-3.4.5 YCSB_BENCHMARK=hbase094 "
                    "benchmark_ycsb_hbase.sh {add|baseline} 1 1000000 1540 DataNode",
        hist_root="ycsb-0.12.0", hist_prefix="1540",
    ),
    dict(
        id="hdfs-4205",
        title="Fsck fails with symlinks",
        jira="HDFS-4205",
        src_plans="server-bugs/instrumentation_hdfs4205",
        hadoop_name="hadoop-0.23.9-SNAPSHOT",
        hbase_name="hbase-0.94.27-hadoop023",
        ycsb_name="ycsb-0.12.0",
        zookeeper_name='zookeeper-3.4.6',
        ycsb_binding="hbase094",
        workload="ycsb_hbase",
        app_name="DataNode",
        app_target="slaves",
        num=1000000,
        rounds=["baseline", 1, 2],
        origin_cmd="master_ycsb.sh: HADOOP_NAME=hadoop-0.23.9-SNAPSHOT HBASE_NAME=hbase-1.0.0 "
                    "YCSB_BENCHMARK=hbase10 benchmark_ycsb_hbase.sh {add|baseline} 1 1000000 4205 DataNode",
        notes="FLAG: the injected symptom (server-bugs/instrumentation_hdfs4205/symptom.properties) "
              "is in NameNode-internal class INodeDirectory, but the original script's own APP_NAME "
              "argument for this bug's ycsb run is 'DataNode'. Carried over literally rather than "
              "silently 'corrected' — if the symptom doesn't reproduce with app_target=slaves, try "
              "app_target=master (APP_NAME=Namenode) instead; see this bug's README. "
              "RPC-VERSION WALL: this bug's vendored hadoop-0.23.9-SNAPSHOT NameNode speaks IPC "
              "protocol version 5, a transitional Hadoop-0.23-branch RPC generation that predates "
              "the protobuf-RPC rewrite (v9, used by every off-the-shelf HBase 0.94/0.96/0.98/1.0+ "
              "hadoop2-compat build) but postdates the old Hadoop-1.x Writable RPC (v4, used by "
              "every -hadoop1 build) — so no off-the-shelf HBase release, INCLUDING the ground-"
              "truth hbase-1.0.0 above (origin_cmd), can actually talk to it in this docker-compose "
              "setup: hbase-0.96.2-hadoop1 and hbase-0.98.9-hadoop1 -> 'Server IPC version 5 cannot "
              "communicate with client version 4'; hbase-0.96.2-hadoop2 (fetched from "
              "archive.apache.org) and hbase-1.0.0 itself -> NameNode logs 'got version 9 expected "
              "version 5', HMaster aborts. hbase-1.0.0's real, successful historical run in "
              "experimental_results/ was presumably on real AWS hardware with a different/patched "
              "Hadoop or HBase build than what's vendored in binaries/ today — unresolved, flagged "
              "separately for investigation. hbase_name is pinned here to hbase-0.94.27-hadoop023, "
              "a CUSTOM build (not from binaries/ upstream — see build recipe below) of HBase "
              "0.94.27 compiled with `-Dhadoop.profile=23 -Dhadoop.version=0.23.9`, i.e. against "
              "real Apache Hadoop 0.23.9's own IPC-v5-generation client jars (pulled from Maven "
              "Central, not the vendored SNAPSHOT specifically — same RPC generation/version either "
              "way since RPC version is a hardcoded era-of-code-generation constant, not tied to "
              "the exact patch snapshot). This is the only combination confirmed to actually clear "
              "HBase-master startup against this bug's NameNode. ycsb_binding moved to hbase094 to "
              "match 0.94.x's client wire protocol (already used elsewhere in this corpus by "
              "hdfs-1540's hbase-0.94.27). BUILD RECIPE for hbase-0.94.27-hadoop023.tar.gz: `git "
              "clone --depth 1 --branch rel/0.94.27 https://github.com/apache/hbase.git`, then two "
              "minimal JDK8-compatibility source patches (JDK6/7-era 2014 code doesn't compile "
              "clean under modern javac) — rename PoolMap.remove(K,V) to removeValue (erasure-"
              "clashes with Map's Java-8-added default remove(Object,Object), update its one "
              "caller in HTablePool.java) and add an explicit (K[]) cast in InputSampler.java's "
              "writePartitionFile (raw-typed InputFormat erases the generic return type under "
              "modern javac's stricter checking) — then `JAVA_HOME=<jdk8> mvn -B -Dhadoop.profile="
              "23 -Dhadoop.version=0.23.9 -Dsurefire.version=2.12 -DskipTests -Dmaven.test.skip="
              "true clean package` (the -Dsurefire.version override replaces a dead custom-repo-"
              "hosted maven-failsafe-plugin fork with a real Central release). Produces target/"
              "hbase-0.94.27.tar.gz directly via the project's own assembly plugin; repack renaming "
              "the top-level dir (and the tarball) to hbase-0.94.27-hadoop023 to avoid colliding "
              "with the unrelated standard hbase-0.94.27.tar.gz already vendored in binaries/.",
        hist_root="ycsb-0.12.0", hist_prefix="4205",
    ),
    dict(
        id="hdfs-10453",
        title="Replication failure caused by delete",
        jira="HDFS-10453",
        src_plans="server-bugs/instrumentation_hdfs10453",
        hadoop_name="hadoop-2.5.2",
        hbase_name="hbase-1.2.5",
        ycsb_name="ycsb-0.12.0",
        zookeeper_name='zookeeper-3.4.6',
        ycsb_binding="hbase10",
        workload="ycsb_hbase",
        app_name="Namenode",
        app_target="master",
        num=1000000,
        rounds=["baseline", 1, 2, 3, 4],
        origin_cmd="master_dfsio.sh (as 'instrumentation_bug1'): HADOOP_NAME=hadoop-2.5.2 "
                    "benchmark_ycsb_hbase.sh {add|baseline} 1 1000000 kairux_y Namenode",
        notes="Largest search space in the corpus (#SI=59 across 4 rounds) — budget more runtime.",
        hist_root="ycsb-0.12.0", hist_prefix="bug1",
    ),
    dict(
        id="zk-1434",
        title="Checking status of non-existent znode fails",
        jira="ZOOKEEPER-1434",
        src_plans="server-bugs/instrumentation_zookeeper1434",
        hadoop_name="hadoop-2.8.2",
        hbase_name="hbase-1.2.5",
        zookeeper_name="zookeeper-3.3.5-zookeeper1434",
        ycsb_name="ycsb-0.18.0-SNAPSHOT",
        workload="ycsb_zk",
        zk_node_cmd="create /benchmark asd",
        app_name="QuorumPeerMain",
        app_target="slaves",
        num=1000000,
        rounds=["baseline", 1, 2],
        origin_cmd="master_zookeeper.sh: HADOOP_NAME=hadoop-2.8.2 ZOOKEEPER_NAME=zookeeper-3.3.5-zookeeper1434 "
                    "benchmark_ycsb_zk.sh {add|baseline} 1 1000000 1435_2 QuorumPeerMain",
        notes="ZooKeeper build is a patched '-zookeeper1434' tarball, not a stock Apache release.",
        hist_root="ycsb-0.18.0-SNAPSHOT", hist_prefix="1435_2",
    ),
    dict(
        id="zk-1851",
        title="Client gets disconnected with create request",
        jira="ZOOKEEPER-1851",
        src_plans="server-bugs/instrumentation_zookeeper1851",
        hadoop_name="hadoop-2.8.2",
        hbase_name="hbase-1.2.5",
        zookeeper_name="zookeeper-3.5.0-SNAPSHOT",
        ycsb_name="ycsb-0.18.0-SNAPSHOT",
        workload="ycsb_zk",
        zk_node_cmd="create /benchmark",
        app_name="QuorumPeerMain",
        app_target="slaves",
        num=1000000,
        rounds=["baseline", 1, 2, 3, 4, 5, 6],
        origin_cmd="master_zookeeper.sh: HADOOP_NAME=hadoop-2.8.2 ZOOKEEPER_NAME=zookeeper-3.5.0-SNAPSHOT "
                    "benchmark_ycsb_zk.sh {add|baseline} 1 1000000 1851_2 QuorumPeerMain "
                    "(commented out in the checked-in script; command shape reused from the analogous "
                    "1434/1900 blocks in the same file)",
        hist_root="ycsb-0.18.0-SNAPSHOT", hist_prefix="1851_2",
    ),
    dict(
        id="zk-1900",
        title="Trying to truncate a deleted log file fails",
        jira="ZOOKEEPER-1900",
        src_plans="server-bugs/instrumentation_zookeeper1900",
        hadoop_name="hadoop-2.8.2",
        hbase_name="hbase-1.2.5",
        zookeeper_name="zookeeper-3.4.5",
        ycsb_name="ycsb-0.18.0-SNAPSHOT",
        workload="ycsb_zk",
        zk_node_cmd="create /benchmark asd",
        app_name="QuorumPeerMain",
        app_target="slaves",
        num=1000000,
        rounds=["baseline", 1, 2, 3, 4, 5, 6],
        origin_cmd="master_zookeeper.sh: HADOOP_NAME=hadoop-2.8.2 ZOOKEEPER_NAME=zookeeper-3.4.5 "
                    "benchmark_ycsb_zk.sh {add|baseline} 1 1000000 1900_x QuorumPeerMain",
        hist_root="ycsb-0.18.0-SNAPSHOT", hist_prefix="1900_x",
    ),
    dict(
        id="hbase-3403",
        title="FSCK detects an error after region split fails",
        jira="HBASE-3403",
        src_plans="server-bugs/instrumentation_hbase3403",
        hadoop_name="hadoop-0.20.2",
        hbase_name="hbase-0.91.0-SNAPSHOT",
        zookeeper_name="zookeeper-3.2.2",
        ycsb_name="ycsb-0.1.4",
        ycsb_binding="hbase",
        workload="ycsb_hbase_old",
        app_name="HRegionServer",
        app_target="slaves",
        num=1000000,
        rounds=["baseline", 1, 2],
        origin_cmd="master_hdfs_old.sh: HADOOP_NAME=hadoop-0.20.2 HBASE_NAME=hbase-0.91.0-SNAPSHOT "
                    "benchmark_ycsb_hbase_old.sh {add|baseline} 1 1000000 3403 HRegionServer",
        notes="Oldest stack in the corpus (Hadoop 0.20.2 / HBase 0.91) — expect the most manual "
              "config finagling of any bug here; legacy conf/ layout.",
    ),
    dict(
        id="hbase-3627",
        title="RegionServer crashes during open",
        jira="HBASE-3627",
        src_plans="server-bugs/instrumentation_hbase3627",
        hadoop_name="hadoop-0.20.2",
        hbase_name="hbase-0.91.0-hbase3627",
        zookeeper_name="zookeeper-3.2.2",
        ycsb_name="ycsb-0.1.4",
        ycsb_binding="hbase",
        workload="ycsb_hbase_old",
        app_name="QuorumPeerMain",
        app_target="slaves",
        num=1000000,
        rounds=["baseline", 1, 2, 3, 4],
        origin_cmd="master_hdfs_old.sh: HADOOP_NAME=hadoop-0.20.2 HBASE_NAME=hbase-0.91.0-hbase3627 "
                    "ZOOKEEPER_NAME=zookeeper-3.2.2 benchmark_ycsb_hbase_old.sh add 3 1000000 3627_2 QuorumPeerMain",
        notes="HBase build is a patched '-hbase3627' tarball, not a stock Apache release. "
              "server-bugs/instrumentation_hbase3627/log.txt + parse.py are checked in locally — "
              "use those to sanity-check your rerun.",
    ),
    dict(
        id="cassandra-13004",
        title="Data corruption caused by schema change",
        jira="CASSANDRA-13004",
        src_plans="server-bugs/instrumentation_bug4",
        cassandra_name="apache-cassandra-3.10-SNAPSHOT",
        ycsb_name="ycsb-0.12.0",
        workload="ycsb_cass",
        app_name="cassandra",
        app_target="master",
        num=1000000,
        rounds=["baseline", 1, 2],
        origin_cmd="master_ycsb_cass.sh / benchmark_ycsb_cass.sh: CASSANDRA_NAME=apache-cassandra-3.10-SNAPSHOT "
                    "benchmark_ycsb_cass.sh {add|baseline} 1 1000000 1",
        notes="Cassandra runs on all 4 nodes (master + 3 slaves), matching the original historical "
              "setup (~/artifacts/old_setup.sh's 'cassandra' target, ~/artifacts/cassandra-config/"
              "cassandra.yaml's 4-address seed list) — replication_factor=3 for the ycsb keyspace, "
              "same as the original. Fault injection still targets 'cassandra' on master only "
              "(app_target above), matching the original bug report.",
    ),
    dict(
        id="yarn-1458",
        title="EventProcessor blocked on many jobs",
        jira="YARN-1458",
        src_plans="server-bugs/instrumentation_bug5",
        hadoop_name="hadoop-3.0.0-SNAPSHOT",
        hibench_name="HiBench2",
        workload="hibench",
        hibench_workload="websearch.pagerank",  # + micro.terasort, see run_experiment.sh for this bug
        app_name="Resour",
        app_target="master",
        enable_yarn=True,
        num=5,
        rounds=["baseline", 2, 3, 4],  # NB: no round 1 exists for this bug
        origin_cmd="master_yarn.sh: HADOOP_NAME=hadoop-3.0.0-SNAPSHOT "
                    "benchmark_yarn.sh {add|baseline} 2..4 20 5  (HiBench2, workloads "
                    "micro.terasort + websearch.pagerank toggled via conf/benchmarks.lst — see "
                    "~/artifacts/hibench.lst, a snapshot of that exact file mid-run)",
        notes="Not a YCSB/HBase bug — the only bug in this corpus driven by HiBench instead. "
              "Two ambiguous vendored tarballs exist for this exact version "
              "(hadoop-3.0.0-SNAPSHOT.tar.gz and hadoop-3.0.0-SNAPSHOT-new.tar.gz, both extract to "
              "the same 'hadoop-3.0.0-SNAPSHOT/' directory name); this manifest defaults to the "
              "non-'-new' one — see MISSING_ARTIFACTS.md.",
        hist_root="HiBench2", hist_prefix="5",
    ),
]

# Bugs with no local instrumentation folder at all — nothing to package. Recorded here purely so
# the generator can emit an explanatory stub folder instead of silently omitting them.
UNPACKAGEABLE = [
    dict(id="hdfs-4261", jira="HDFS-4261", title="Balancer infinite loop",
         reason="Det=N, Succ=N in the results table and no server-bugs/ folder exists for it."),
    dict(id="hdfs-14135", jira="HDFS-14135", title="Unit test timeout by backlog size",
         reason="Det=Y, Succ=N; this was reproduced as a plain unit test, not through this "
                "benchmark harness — no instrumentation folder exists."),
    dict(id="hdfs-4558", jira="HDFS-4558", title="Balancer's bad configuration",
         reason="No server-bugs/ folder, no plans, no logs anywhere in this checkout."),
    dict(id="hbase-4078", jira="HBASE-4078", title="A column family is lost due to HDFS error",
         reason="Det=N, Succ=N in the results table and no server-bugs/ folder exists for it."),
]
