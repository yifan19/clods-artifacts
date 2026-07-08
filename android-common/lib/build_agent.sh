#!/bin/bash
# Builds libagent.so for one round's breakpoints (ARTTI_instrument's JVMTI live-breakpoint agent
# — see ../../ANDROID_README.md for why this is the automatable agent path in this artifact, and
# what's different about the original production agent this corpus's results were captured with).
#
# Usage: build_agent.sh <round.btm> <output_dir>
# Requires $ANDROID_NDK to point at an NDK root (toolchains/llvm/prebuilt/<host>/bin/...). If unset
# or the toolchain isn't found, falls back to the vendored generic prebuilt libagent.so and prints
# a clear warning — that prebuilt binary's breakpoints were NOT generated from this round's plan,
# so its logcat output won't match this round's probes; treat that fallback as "attach mechanism
# smoke test only", not a real reproduction of this round.
set -euo pipefail
BTM_PLAN="${1:?usage: build_agent.sh <round.btm> <output_dir>}"
OUT_DIR="${2:?usage: build_agent.sh <round.btm> <output_dir>}"
mkdir -p "$OUT_DIR"

HOST_TAG=linux-x86_64
CC_DIR="${ANDROID_NDK:-}/toolchains/llvm/prebuilt/${HOST_TAG}/bin"
API_LEVEL="${ANDROID_API_LEVEL:-28}"
CC="$CC_DIR/aarch64-linux-android${API_LEVEL}-clang++"

if [ -z "${ANDROID_NDK:-}" ] || [ ! -x "$CC" ]; then
    echo "[build_agent] ANDROID_NDK not set or toolchain not found at $CC" >&2
    echo "[build_agent] falling back to the vendored GENERIC prebuilt agent — see MISSING_ARTIFACTS.md" >&2
    cp /opt/agent-src/libagent.so.prebuilt-generic "$OUT_DIR/libagent.so"
    echo "FALLBACK" > "$OUT_DIR/BUILD_MODE"
    exit 0
fi

cp /opt/agent-src/generate_agent.py /opt/agent-src/Makefile "$OUT_DIR/"
cd "$OUT_DIR"
python3 generate_agent.py \
    --cc-dir "$CC_DIR" \
    --cflags '-fPIC -shared -static-libstdc++ -llog' \
    --includes "-I${ANDROID_NDK}/sysroot/usr/include/android" \
    -m "$API_LEVEL" -y \
    --input-file "$BTM_PLAN" \
    --output-dir "$OUT_DIR"

make CC="$CC"
echo "BUILT" > "$OUT_DIR/BUILD_MODE"
echo "[build_agent] built $OUT_DIR/libagent.so from $BTM_PLAN"
