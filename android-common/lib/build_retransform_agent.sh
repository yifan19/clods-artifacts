#!/bin/bash
# Builds libagent_retransform.so — the live JVMTI ClassFileLoadHook/RetransformClasses agent
# (android-common/agent-src/agent_retransform.cpp, generalized from the real production agent
# `agent_element.cpp` so the target class + replacement classfile path are read from Agent_OnAttach's
# `options` string at attach time instead of being hardcoded per round). Because it's parameterized
# at runtime, this builds ONCE and is reused for every round of every bug — unlike
# ARTTI_instrument's breakpoint agent (build_agent.sh), which needs a per-round rebuild.
#
# Usage: build_retransform_agent.sh <output_dir>
# Requires $ANDROID_NDK to point at an NDK root (toolchains/llvm/prebuilt/<host>/bin/...).
set -euo pipefail
OUT_DIR="${1:?usage: build_retransform_agent.sh <output_dir>}"
mkdir -p "$OUT_DIR"

HOST_TAG=linux-x86_64
CC_DIR="${ANDROID_NDK:-}/toolchains/llvm/prebuilt/${HOST_TAG}/bin"
API_LEVEL="${ANDROID_API_LEVEL:-28}"
CC="$CC_DIR/aarch64-linux-android${API_LEVEL}-clang++"
JDK_INCLUDE="${JAVA_INCLUDE_DIR:-/usr/lib/jvm/java-8-openjdk-amd64/include}"

if [ -z "${ANDROID_NDK:-}" ] || [ ! -x "$CC" ]; then
    echo "[build_retransform_agent] ANDROID_NDK not set or toolchain not found at $CC" >&2
    echo "[build_retransform_agent] no fallback for this agent (unlike build_agent.sh) — the live" >&2
    echo "[build_retransform_agent] retransform step will be skipped; offline patching still works" >&2
    exit 1
fi

"$CC" -fPIC -shared -static-libstdc++ -llog \
    -I"$JDK_INCLUDE" \
    -I"$JDK_INCLUDE/linux" \
    -I"${ANDROID_NDK}/sysroot/usr/include/android" \
    /opt/agent-src/agent_retransform.cpp -o "$OUT_DIR/libagent_retransform.so"

echo "[build_retransform_agent] built $OUT_DIR/libagent_retransform.so"
