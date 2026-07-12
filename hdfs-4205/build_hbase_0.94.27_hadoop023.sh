#!/bin/bash
# Builds a custom hbase-0.94.27 targeting Hadoop's 0.23-branch IPC generation (hadoop.profile=23),
# because no off-the-shelf HBase release can actually talk to this bug's hadoop-0.23.9-SNAPSHOT
# NameNode — see the "RPC-VERSION WALL" note on the hdfs-4205 entry in ../manifest.py for the full
# story (every -hadoop1 build speaks IPC v4, every -hadoop2/1.0+ build speaks IPC v9 (protobuf
# RPC), and this NameNode only speaks v5 — a transitional generation that predates protobuf-RPC but
# postdates the old Hadoop-1.x Writable RPC). This profile pulls real Apache Hadoop 0.23.9 (not the
# vendored hadoop-0.23.9-SNAPSHOT specifically — RPC version is a hardcoded constant per code-
# generation era, not tied to the exact patch snapshot, so the plain Maven Central release is fine).
#
# Two source patches (jdk8-hadoop23-compat.patch, applied below) are needed purely because this is
# ~2014 code compiled with a 2026 JDK 8 — not functional changes:
#   - PoolMap.remove(K,V) is renamed to removeValue: under JDK8, Map grew a default remove(Object,
#     Object) method that erasure-clashes with PoolMap's own generic remove(K,V) ("name clash ...
#     yet neither overrides the other"). HTablePool.java's one call site is updated to match.
#   - InputSampler.java's writePartitionFile gets an explicit (K[]) cast: modern javac's stricter
#     generic-array-creation checking rejects the implicit conversion through a raw-typed
#     InputFormat that older javac silently accepted.
#
# Usage:
#   ./build_hbase_0.94.27_hadoop023.sh            resolves Hadoop 0.23.9 + all other Maven deps
#                                                  from Apache/Maven Central (needs network)
#   ./build_hbase_0.94.27_hadoop023.sh --offline   resolves them from the vendored Maven repo
#                                                  instead (../binaries/hbase-0.94.27-hadoop023-
#                                                  offline-m2.tar.gz) via `mvn -o` — no Maven-
#                                                  dependency network calls either way. Either mode
#                                                  still does a plain `git clone` of the HBase
#                                                  source itself from GitHub, which always needs
#                                                  network — this repo doesn't vendor HBase source.
# Output: ../binaries/hbase-0.94.27-hadoop023.tar.gz (matches this bug's manifest.py hbase_name).
set -euo pipefail
cd "$(dirname "$0")"

OFFLINE=0
[ "${1:-}" = "--offline" ] && OFFLINE=1

mkdir -p ../binaries
OUT="$(cd ../binaries && pwd)/hbase-0.94.27-hadoop023.tar.gz"
OFFLINE_M2_TARBALL="$(cd ../binaries && pwd)/hbase-0.94.27-hadoop023-offline-m2.tar.gz"

echo "== ensuring JDK 8 is installed (this codebase predates JDK 8's Map API changes; still needs it as the compiler, see patch header) =="
if [ ! -x /usr/lib/jvm/java-8-openjdk-amd64/bin/javac ]; then
    sudo -E DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        openjdk-8-jdk-headless >/dev/null
fi
export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
export PATH="$JAVA_HOME/bin:$PATH"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo "== fetching HBase 0.94.27 source (rel/0.94.27) =="
git clone --depth 1 --branch rel/0.94.27 https://github.com/apache/hbase.git hbase-src

echo "== applying JDK8/modern-javac compatibility patch =="
git -C hbase-src apply "$OLDPWD/jdk8-hadoop23-compat.patch"

MVN_OPTS_LOCAL=()
if [ "$OFFLINE" = "1" ]; then
    echo "== offline mode: extracting vendored Maven repo =="
    [ -f "$OFFLINE_M2_TARBALL" ] || {
        echo "missing $OFFLINE_M2_TARBALL — fetch it (see ../MISSING_ARTIFACTS.md) or drop --offline" >&2
        exit 42
    }
    mkdir -p m2-repo
    tar xzf "$OFFLINE_M2_TARBALL" -C m2-repo
    MVN_OPTS_LOCAL+=(-o -Dmaven.repo.local="$WORK/m2-repo")
fi

echo "== building (mvn -Dhadoop.profile=23 -Dhadoop.version=0.23.9) =="
cd hbase-src
mvn -B "${MVN_OPTS_LOCAL[@]}" -Dhadoop.profile=23 -Dhadoop.version=0.23.9 -Dsurefire.version=2.12 \
    -DskipTests -Dmaven.test.skip=true clean package
# -Dsurefire.version=2.12 replaces this pom's default maven-failsafe-plugin version
# (2.12-TRUNK-HBASE-2, a custom fork hosted at the now-dead http://people.apache.org/~garyh/mvn/)
# with a real Maven Central release — we don't run failsafe integration tests anyway.

echo "== repackaging (rename hbase-0.94.27 -> hbase-0.94.27-hadoop023 to avoid colliding with the standard hbase-0.94.27.tar.gz already vendored in binaries/) =="
mkdir -p repack
tar xzf target/hbase-0.94.27.tar.gz -C repack
mv repack/hbase-0.94.27 repack/hbase-0.94.27-hadoop023
tar -C repack -czf "$OUT" hbase-0.94.27-hadoop023
sha256sum "$OUT"
echo "== done: $OUT =="
