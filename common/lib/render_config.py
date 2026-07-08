#!/usr/bin/env python3
"""Render Hadoop/HBase/ZooKeeper config for whichever version is vendored for this bug.

Auto-detects the two Hadoop config-layout generations found across this corpus's versions
(0.20.2/1.0.0 use `conf/`; 0.23.9-SNAPSHOT/2.x/3.x use `etc/hadoop/`) rather than hardcoding a
version list, so new vendored versions work without editing this file.

All inputs come from environment variables so this can be invoked identically from every bug's
run_experiment.sh / docker-compose.yml:

  HADOOP_NAME        e.g. hadoop-2.8.2   (required)
  HBASE_NAME         e.g. hbase-1.2.5    (optional)
  ZOOKEEPER_NAME     e.g. zookeeper-3.4.6 (optional)
  MASTER_HOST        default: master
  SLAVE_HOSTS        space-separated, e.g. "slave1 slave2 slave3"
  ZK_MYID            this node's ZooKeeper myid (only needed on nodes running ZK), 1-based
  ENABLE_YARN        "1" to also render yarn-site.xml/mapred-site.xml (only yarn-1458 needs this)
  DFS_REPLICATION    default: min(3, len(SLAVE_HOSTS))
"""
import os
import socket
import sys

HOME = os.path.expanduser("~")


def sh(cmd):
    print("+ " + cmd)
    rc = os.system(cmd)
    if rc != 0:
        sys.exit("command failed (rc=%d): %s" % (rc, cmd))


def write(path, content):
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d)
    with open(path, "w") as f:
        f.write(content)
    print("wrote " + path)


def xml_props(pairs):
    body = "\n".join(
        "  <property>\n    <name>%s</name>\n    <value>%s</value>\n  </property>" % (k, v)
        for k, v in pairs
    )
    return '<?xml version="1.0"?>\n<configuration>\n%s\n</configuration>\n' % body


def main():
    hadoop_name = os.environ["HADOOP_NAME"]
    hbase_name = os.environ.get("HBASE_NAME", "")
    zookeeper_name = os.environ.get("ZOOKEEPER_NAME", "")
    master = os.environ.get("MASTER_HOST", "master")
    slaves = os.environ.get("SLAVE_HOSTS", "").split()
    enable_yarn = os.environ.get("ENABLE_YARN", "0") == "1"
    replication = int(os.environ.get("DFS_REPLICATION", str(min(3, max(1, len(slaves))))))

    hadoop_dir = os.path.join(HOME, hadoop_name)
    if not os.path.isdir(hadoop_dir):
        sys.exit("expected %s to exist (did deploy_and_start.sh extract the tarball first?)" % hadoop_dir)

    modern = os.path.isdir(os.path.join(hadoop_dir, "etc", "hadoop"))
    conf_dir = os.path.join(hadoop_dir, "etc", "hadoop") if modern else os.path.join(hadoop_dir, "conf")
    print("detected %s hadoop layout at %s" % ("modern (etc/hadoop)" if modern else "legacy (conf)", conf_dir))

    # --- core-site.xml -------------------------------------------------
    write(os.path.join(conf_dir, "core-site.xml"), xml_props([
        ("fs.default.name", "hdfs://%s:9000" % master),
        ("fs.defaultFS", "hdfs://%s:9000" % master),
        ("hadoop.tmp.dir", "/tmp/hadoop-${user.name}"),
    ]))

    # --- hdfs-site.xml ---------------------------------------------------
    write(os.path.join(conf_dir, "hdfs-site.xml"), xml_props([
        ("dfs.replication", str(replication)),
        ("dfs.permissions", "false"),
        ("dfs.namenode.name.dir", "/tmp/hadoop-${user.name}/dfs/name"),
        ("dfs.datanode.data.dir", "/tmp/hadoop-${user.name}/dfs/data"),
    ]))

    # --- masters / slaves ------------------------------------------------
    slaves_file = "slaves" if not (modern and os.path.exists(os.path.join(conf_dir, "workers"))) else "workers"
    write(os.path.join(conf_dir, slaves_file), "\n".join(slaves) + "\n")
    if not modern:
        write(os.path.join(conf_dir, "masters"), master + "\n")

    # --- hadoop-env.sh: make sure JAVA_HOME + running-as-root (container) work ---
    env_file = os.path.join(conf_dir, "hadoop-env.sh")
    extra_env = (
        "\nexport JAVA_HOME=%s\n"
        "export HADOOP_HOME_WARN_SUPPRESS=1\n"
        "export HDFS_NAMENODE_USER=ubuntu\n"
        "export HDFS_DATANODE_USER=ubuntu\n"
        "export HDFS_SECONDARYNAMENODE_USER=ubuntu\n"
        "export YARN_RESOURCEMANAGER_USER=ubuntu\n"
        "export YARN_NODEMANAGER_USER=ubuntu\n"
    ) % os.environ.get("JAVA_HOME", "/usr/lib/jvm/java-8-openjdk-amd64")
    with open(env_file, "a") as f:
        f.write(extra_env)
    print("appended JAVA_HOME/*_USER exports to " + env_file)

    if enable_yarn and modern:
        write(os.path.join(conf_dir, "yarn-site.xml"), xml_props([
            ("yarn.resourcemanager.hostname", master),
            ("yarn.nodemanager.aux-services", "mapreduce_shuffle"),
        ]))
        write(os.path.join(conf_dir, "mapred-site.xml"), xml_props([
            ("mapreduce.framework.name", "yarn"),
        ]))

    # --- HBase --------------------------------------------------------
    if hbase_name:
        hbase_dir = os.path.join(HOME, hbase_name)
        if not os.path.isdir(hbase_dir):
            sys.exit("expected %s to exist" % hbase_dir)
        hbase_conf = os.path.join(hbase_dir, "conf")
        has_standalone_zk = bool(zookeeper_name and slaves)
        zk_quorum = ",".join(slaves) if has_standalone_zk else master
        # docker-compose's network registers each container under two DNS names: the short
        # `hostname:` alias (e.g. "slave1") and an auto-generated one
        # (e.g. "hdfs-10453-slave1-1.hdfs-10453_bugnet"). Left to its own hostname
        # auto-detection, HMaster resolves a regionserver's connecting IP to the auto-generated
        # name instead of the short one everything else here uses (SSH, the regionservers file,
        # ZK assignment) — "Master passed us a different hostname to use" in the RS log — so the
        # meta region's assignment gets recorded under a mismatched identity, is declared
        # hijacked, and never recovers (HMaster hangs forever waiting for it). Pinning the
        # hostname explicitly bypasses that reverse-DNS ambiguity.
        this_host = socket.gethostname()
        write(os.path.join(hbase_conf, "hbase-site.xml"), xml_props([
            ("hbase.rootdir", "hdfs://%s:9000/hbase" % master),
            ("hbase.cluster.distributed", "true"),
            ("hbase.zookeeper.quorum", zk_quorum),
            ("hbase.zookeeper.property.clientPort", "2181"),
            ("hbase.regionserver.hostname", this_host),
            ("hbase.master.hostname", this_host),
        ]))
        write(os.path.join(hbase_conf, "regionservers"), "\n".join(slaves) + "\n")
        with open(os.path.join(hbase_conf, "hbase-env.sh"), "a") as f:
            # Bugs with their own standalone ZK ensemble (has_standalone_zk) manage it themselves
            # via cluster_ctl.sh's zkServer.sh calls, so HBase must NOT also try to run one — hence
            # false there. Bugs with no separate ZK service (zk_quorum falls back to master) have
            # nothing else to provide one, so HBase must manage its own embedded ZK (true) or
            # HMaster crashes on startup with "Connection refused" to master:2181.
            f.write("\nexport JAVA_HOME=%s\nexport HBASE_MANAGES_ZK=%s\n" %
                    (os.environ.get("JAVA_HOME", "/usr/lib/jvm/java-8-openjdk-amd64"),
                     "false" if has_standalone_zk else "true"))

    # --- ZooKeeper (rendered on nodes that actually run a ZK server) -----
    if zookeeper_name and "ZK_MYID" in os.environ:
        zk_dir = os.path.join(HOME, zookeeper_name)
        if not os.path.isdir(zk_dir):
            sys.exit("expected %s to exist" % zk_dir)
        myid = os.environ["ZK_MYID"]
        data_dir = "/home/ubuntu/zk_storage/zookeeper/data"
        os.makedirs(data_dir, exist_ok=True)
        write(os.path.join(data_dir, "myid"), myid + "\n")
        server_lines = "\n".join(
            "server.%d=%s:2888:3888" % (i + 1, h) for i, h in enumerate(slaves)
        )
        zoo_cfg = (
            "tickTime=2000\n"
            "initLimit=10\n"
            "syncLimit=5\n"
            "dataDir=%s\n"
            "clientPort=2181\n"
            "%s\n"
        ) % (data_dir, server_lines)
        write(os.path.join(zk_dir, "conf", "zoo.cfg"), zoo_cfg)


if __name__ == "__main__":
    main()
