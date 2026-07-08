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
# dex2jar: prebuilt lib/ + d2j-*.sh launchers (ready to run, no build needed) + true source (small,
# excludes the ~1GB of stale decompiled-APK working dirs that were sitting alongside it upstream).
COPY dex2jar /opt/dex2jar
COPY dex2jar-src /opt/dex2jar-src

# blameMasterInstrument, built from bm_instrument's `android` branch (bm_instrument8/target's
# prebuilt jar already includes CommandLine.class — see ANDROID_README.md) + full source + the
# offline Maven cache, so it can be rebuilt without hitting Maven Central.
COPY blameMasterInstrument-android.jar /opt/blameMasterInstrument-android.jar
COPY bm_instrument-android-src /opt/bm_instrument-android-src

# Native agent source (ARTTI_instrument's JVMTI live-breakpoint agent — see ANDROID_README.md for
# why this, not a literal "agent_element.cpp", is what's vendored) + a generic prebuilt fallback.
COPY agent-src /opt/agent-src

COPY lib /opt/lib
RUN chmod +x /opt/lib/*.sh /opt/lib/*.py

WORKDIR /work
