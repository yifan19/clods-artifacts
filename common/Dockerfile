# Shared base image for every server-side bug in this artifact.
#
# Network use during `docker build`: this Dockerfile only reaches the internet for OS packages
# (apt-get: JDK 8, sshd, python2, ...). The actual systems under test (Hadoop/HBase/ZooKeeper/
# Cassandra/YCSB) are NEVER downloaded here — they are bind-mounted at container-run time from
# ../../binaries (vendored tarballs, see MISSING_ARTIFACTS.md for anything not yet present), and
# the instrumentation tool is vendored as a pre-built jar (common/blameMasterInstrument.jar) so no
# Maven Central access is needed either. If you need a fully network-air-gapped `docker build` too,
# replace the `ubuntu:20.04` base with a pre-pulled local image and vendor the apt .debs; this is
# left as-is by default because base-OS packages are a much lower supply-chain concern than the
# old, hard-to-rebuild research systems this artifact exists to preserve.
FROM ubuntu:20.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        openjdk-8-jdk \
        openssh-server openssh-client \
        python2.7 python3 \
        maven \
        rsync net-tools iproute2 procps psmisc \
        vim-tiny less tar gzip unzip curl \
        ca-certificates \
    && ln -sf /usr/bin/python2.7 /usr/bin/python2 \
    && ln -sf /usr/bin/python2.7 /usr/bin/python \
    && rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
ENV PATH="${JAVA_HOME}/bin:${PATH}"

# --- user + SSH setup -------------------------------------------------------
# Every bug's containers (master + slaves) talk to each other over SSH, exactly like the original
# multi-node EC2 cluster scripts (benchmark_scripts/*.sh use `ssh $slave ...` throughout). We bake
# one fixed keypair into the image so every container in the docker-compose network trusts every
# other one out of the box. This is intentionally insecure (fixed key, no passphrase,
# StrictHostKeyChecking disabled) and is only acceptable because these containers are ephemeral and
# only ever reachable on the private docker-compose network — do not reuse this image or key
# outside that context.
RUN useradd -m -s /bin/bash ubuntu \
    && echo "ubuntu:ubuntu" | chpasswd \
    && adduser ubuntu sudo \
    && echo "ubuntu ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers \
    && mkdir -p /var/run/sshd



USER ubuntu
WORKDIR /home/ubuntu
RUN mkdir -p ~/.ssh \
    && ssh-keygen -t rsa -b 2048 -N "" -f ~/.ssh/id_rsa \
    && cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys \
    && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys ~/.ssh/id_rsa \
    && printf "Host *\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n  LogLevel ERROR\n" > ~/.ssh/config \
    && chmod 600 ~/.ssh/config

USER root


RUN mkdir -p /data
RUN chown ubuntu:ubuntu  /data


# Let SSH sessions on this container see the same bug-specific env vars (HADOOP_NAME, etc.) that
# docker-compose set on the container itself. Compose's `environment:` only reaches PID 1 and its
# direct children (i.e. `docker compose exec`) — a fresh `ssh slave1/slave2/slave3 ...` login session does NOT
# inherit it by default. PermitUserEnvironment + ~/.ssh/environment (populated at container start
# by entrypoint.sh, since only then do we know the real values) closes that gap so every one of
# common/lib/*.sh behaves identically whether invoked locally or over ssh.
RUN sed -i 's/#\?PermitUserEnvironment.*/PermitUserEnvironment yes/' /etc/ssh/sshd_config \
    && grep -q '^PermitUserEnvironment yes' /etc/ssh/sshd_config \
    || echo 'PermitUserEnvironment yes' >> /etc/ssh/sshd_config

# --- vendored instrumentation tool + Maven offline cache --------------------
# blameMasterInstrument.jar is a prebuilt fallback jar. bm_instrument-src/ + m2-repo/ are also
# vendored (both fetched by ../fetch_data.sh — bm_instrument-src/ from source-bundles/
# bm_instrument.bundle, see ../DATA.md — before `docker build` runs), and this image actually
# builds from that source at image-build time (`mvn -o`, fully offline against m2-repo/) rather
# than only trusting the prebuilt jar, per this artifact's "keep source available and try to build
# it" goal. The freshly-built jar lives at bm_instrument-src/target/uber-blameMasterInstrument-1.0.jar
# inside the image; blameMasterInstrument.jar is kept alongside as a known-good fallback in case a
# future source change breaks the build.
COPY blameMasterInstrument.jar /opt/blameMasterInstrument.jar

# you can build your own bm_instrument
# COPY bm_instrument-src /opt/bm_instrument-src
# COPY m2-repo /opt/m2-repo
# RUN cd /opt/bm_instrument-src && mvn -o -Dmaven.repo.local=/opt/m2-repo package -DskipTests
# RUN chown -R ubuntu:ubuntu /opt/m2-repo /opt/bm_instrument-src 

COPY lib /opt/lib
COPY entrypoint.sh /opt/entrypoint.sh
RUN chmod +x /opt/entrypoint.sh /opt/lib/*.sh \
    && chown -R ubuntu:ubuntu /opt/blameMasterInstrument.jar /opt/lib

EXPOSE 22
ENTRYPOINT ["/opt/entrypoint.sh"]
