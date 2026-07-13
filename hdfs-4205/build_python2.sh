#!/bin/bash
# Builds Python 2.7.18 (the final Python 2 release) from verified source and packages it as a
# relocatable-at-a-fixed-prefix tarball — run_experiment_aws.sh deploys this to every node instead
# of relying on an apt python2/python2.7 package, which no longer exists on Ubuntu 24.04 (confirmed:
# `apt-cache policy python2.7` has no candidate there). Ubuntu 20.04/22.04 still package it, but
# using this same build on every OS version keeps the interpreter identical everywhere rather than
# depending on whatever a distro happens to still carry.
#
# Nothing in this bug's own reproduction actually calls python2 (node_prepare.sh invokes
# render_config.py via python3 explicitly) — this exists purely so the deployed environment matches
# ../common/Dockerfile's base image as closely as possible (which does `ln -sf python2.7 /usr/bin/
# python2` / `/usr/bin/python`), in case some vendored old script silently expects a bare `python`/
# `python2` to exist and resolve to Python 2 semantics.
#
# Usage: ./build_python2.sh   (run on any Ubuntu box — doesn't have to be one of the 4 target
#                               hosts, just the same architecture/glibc family; this repo built it
#                               on Ubuntu 24.04 x86_64)
# Output: ../binaries/python-2.7.18-ubuntu24.04-x86_64.tar.gz (extract to /opt/python2.7.18 on the
#         target host — the build's rpath is hardcoded to that path, so it MUST land there, not
#         wherever it happens to be unpacked).
set -euo pipefail
cd "$(dirname "$0")"

VERSION=2.7.18
PREFIX=/opt/python2.7.18
# Resolved to an absolute path now, before any `cd` below changes what "../binaries" would mean.
mkdir -p ../binaries
OUT="$(cd ../binaries && pwd)/python-2.7.18-ubuntu24.04-x86_64.tar.gz"
# Benjamin Peterson — Python 2.7's release manager; signs every 2.7.x source tarball. Fingerprint
# copied from https://www.python.org/downloads/ (also printed by `gpg --verify` once imported).
SIGNING_KEY="C01E1CAD5EA2C4F0B8E3571504C367C218ADD4FF"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo "== installing build dependencies =="
export NEEDRESTART_SUSPEND=1
sudo -E apt-get update -qq
sudo -E DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    build-essential zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
    libncurses5-dev libncursesw5-dev libgdbm-dev libnss3-dev liblzma-dev tk-dev \
    libffi-dev libssl-dev ca-certificates curl gnupg >/dev/null

echo "== downloading + verifying Python-$VERSION source =="
curl -sL -o "Python-$VERSION.tgz" "https://www.python.org/ftp/python/$VERSION/Python-$VERSION.tgz"
curl -sL -o "Python-$VERSION.tgz.asc" "https://www.python.org/ftp/python/$VERSION/Python-$VERSION.tgz.asc"
gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys "$SIGNING_KEY"
gpg --verify "Python-$VERSION.tgz.asc" "Python-$VERSION.tgz"

echo "== building (prefix=$PREFIX) =="
tar xzf "Python-$VERSION.tgz"
cd "Python-$VERSION"
sudo mkdir -p "$PREFIX"
sudo chown "$(whoami)":"$(whoami)" "$PREFIX"
./configure --prefix="$PREFIX" --enable-shared --with-ensurepip=no \
    LDFLAGS="-Wl,-rpath=$PREFIX/lib"
make -j"$(nproc)"
# altinstall, not install: installs as bin/python2.7 only, doesn't touch any system python/python2
# (there is no system one to touch on 24.04 anyway, but this keeps the same recipe safe on
# 20.04/22.04 too, where there might be).
make altinstall

ln -sf python2.7 "$PREFIX/bin/python2"
ln -sf python2.7 "$PREFIX/bin/python"

echo "== sanity check =="
"$PREFIX/bin/python2" -c "import ssl, hashlib, sqlite3, zlib, ctypes; print('modules ok')"
"$PREFIX/bin/python" -V

echo "== packaging =="
tar -C "$(dirname "$PREFIX")" -czf "$OUT" "$(basename "$PREFIX")"
sha256sum "$OUT"
echo "== done: $OUT =="
