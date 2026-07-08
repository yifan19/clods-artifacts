# Shared base image for the 5 packageable Android (Element) bugs.
#
# Network use during `docker build`: OS packages only (JDK 8, adb/platform-tools, python3). The
# actual instrumentation toolchain — dex2jar and the blameMasterInstrument "android" branch build
# (the one with CommandLine.java, which upstream `bm_instrument/main` doesn't have) — is vendored,
# not downloaded. Each bug's own already-built APK is vendored in that bug's own folder. See
# ../ANDROID_README.md for what's NOT vendored (Android NDK — needed only to recompile the native
# agent per-round; a generic prebuilt fallback is included) and why.
FROM ubuntu:20.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        openjdk-8-jdk \
        android-tools-adb \
        python3 python3-pip \
        unzip zip make g++ \
        ca-certificates \
    && pip3 install --no-cache-dir javaproperties \
    && rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
ENV PATH="${JAVA_HOME}/bin:${PATH}"

# --- vendored offline instrumentation toolchain -----------------------------
# dex2jar (prebuilt lib/ + d2j-*.sh launchers, ready to run) and blameMasterInstrument-android.jar
# (built from bm_instrument's `android` branch — has CommandLine.class, see ANDROID_README.md) are
# both .gitignore'd (see ../DATA.md) and fetched by ../fetch_data.sh before `docker build` runs —
# these COPYs fail with a clear "not found" error if you skip that step.
COPY dex2jar /opt/dex2jar
COPY blameMasterInstrument-android.jar /opt/blameMasterInstrument-android.jar

# Neither tool's *source* is copied into the image — both are archived as full-history git bundles
# instead (../fetch_data.sh --source: dex2jar.bundle, bm_instrument.bundle — same bundle the
# server-side image uses, just `git checkout android` for the branch with CommandLine.java).

# Native agent: agent.cpp/Makefile/generate_agent.py/example.btm are small text, tracked directly
# in git; libagent.so.prebuilt-generic is .gitignore'd and fetched by fetch_data.sh into this same
# directory before build (see ANDROID_README.md for why this, not a literal "agent_element.cpp",
# is what's vendored).
COPY agent-src /opt/agent-src

COPY lib /opt/lib
RUN chmod +x /opt/lib/*.sh /opt/lib/*.py

WORKDIR /work
