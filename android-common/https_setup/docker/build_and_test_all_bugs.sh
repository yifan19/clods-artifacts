#!/bin/bash
# Builds + smoke-tests all 5 per-bug Synapse images from PER_BUG_BUILD_GUIDE.md:
#   clods-synapse:516, :6782, :5132, :7643  <- built once from the `develop` branch
#   clods-synapse:7516                      <- built from the `bug10` branch (old server,
#                                               needed by "Connection failure to old server version")
#
# Setup approach (docker run generate / nginx+certbot for the real deployment) follows
# https://dev.to/jefferyhus/host-your-own-matrix-element-on-a-server-without-losing-your-weekend-559p
#
# For each tag: generates a throwaway SQLite config (server_name test-<bug>.invalid, not a
# real domain -- this script only checks that the image starts and answers /health, it doesn't
# set up anything evaluators would use), runs it (with SYNAPSE_INSTRUMENT set for 516/7516,
# the two bugs with a server-side Python-Instrumentation hook), polls /health, tears down,
# moves to the next.
#
# Usage: ./build_and_test_all_bugs.sh
# Env overrides: SYNAPSE_SRC (default: ../../../../android/synapse),
#   PYTHON_INSTRUMENTATION_SRC (default: ../../../../android/Python-Instrumentation),
#   PYTHON_VERSION (default: 3.10)

set -euo pipefail
cd "$(dirname "$0")"

SYNAPSE_SRC="${SYNAPSE_SRC:-../../../../android/synapse}"
PYTHON_INSTRUMENTATION_SRC="${PYTHON_INSTRUMENTATION_SRC:-../../../../android/Python-Instrumentation}"
PYTHON_VERSION="${PYTHON_VERSION:-3.10}"
WORKDIR="$(mktemp -d)"
TEST_PORT=18008

if [ ! -d "$SYNAPSE_SRC/docker" ]; then
    echo "SYNAPSE_SRC ($SYNAPSE_SRC) doesn't look like a synapse checkout (no docker/ dir)." >&2
    exit 1
fi
if [ ! -f "$PYTHON_INSTRUMENTATION_SRC/driver.py" ]; then
    echo "PYTHON_INSTRUMENTATION_SRC ($PYTHON_INSTRUMENTATION_SRC) doesn't look like a Python-Instrumentation checkout (no driver.py)." >&2
    exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
    echo "Docker not found." >&2
    exit 1
fi

CURRENT_TAGS=(516 6782 5132 7643)
OLD_TAG=7516
# Only these two bugs actually run through the instrumentation driver at container-start time
# (see the smoke-test loop below) -- the rest get the same image contents (harmless, unused)
# but never set SYNAPSE_INSTRUMENT.
INSTRUMENTED_TAGS=(516 7516)

pushd "$PYTHON_INSTRUMENTATION_SRC" >/dev/null
PI_ORIG_BRANCH="$(git branch --show-current)"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "Uncommitted tracked changes in $PYTHON_INSTRUMENTATION_SRC -- commit/stash before running this (branch switches below would touch them)." >&2
    exit 1
fi
popd >/dev/null

pushd "$SYNAPSE_SRC" >/dev/null
ORIG_BRANCH="$(git branch --show-current)"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "Uncommitted tracked changes in $SYNAPSE_SRC -- commit/stash before running this (branch switches below would touch them)." >&2
    exit 1
fi

echo "== building current-version image (develop) for: ${CURRENT_TAGS[*]} =="
git checkout develop
git -C "$PYTHON_INSTRUMENTATION_SRC" checkout element-516   # serialize_event armed -- see PER_BUG_BUILD_GUIDE.md
TAG_ARGS=()
for b in "${CURRENT_TAGS[@]}"; do TAG_ARGS+=(-t "clods-synapse:$b"); done
DOCKER_BUILDKIT=1 docker build -f docker/Dockerfile --build-arg PYTHON_VERSION="$PYTHON_VERSION" \
    --build-context "instrumentation=$PYTHON_INSTRUMENTATION_SRC" "${TAG_ARGS[@]}" .

echo "== building old-version image (bug10) for: $OLD_TAG =="
git checkout bug10
git -C "$PYTHON_INSTRUMENTATION_SRC" checkout element-7516   # check_valid_filter armed
DOCKER_BUILDKIT=1 docker build -f docker/Dockerfile --build-arg PYTHON_VERSION="$PYTHON_VERSION" \
    --build-context "instrumentation=$PYTHON_INSTRUMENTATION_SRC" -t "clods-synapse:$OLD_TAG" .

git checkout "$ORIG_BRANCH"
popd >/dev/null
git -C "$PYTHON_INSTRUMENTATION_SRC" checkout "$PI_ORIG_BRANCH"

echo
echo "== smoke-testing each tag (SQLite, throwaway config, port $TEST_PORT) =="
ALL_TAGS=("${CURRENT_TAGS[@]}" "$OLD_TAG")
FAILED=()
for bug in "${ALL_TAGS[@]}"; do
    echo "--- $bug ---"
    DATA_DIR="$WORKDIR/data-$bug"
    mkdir -p "$DATA_DIR"
    NAME="clods-synapse-test-$bug"
    docker rm -f "$NAME" >/dev/null 2>&1 || true

    # Default UID/GID (no override): generate+run both land on 991 now that docker/start.py's
    # run_generate_config chowns recursively *after* generation instead of non-recursively
    # before it -- fixed upstream on all 4 branches (develop/element-516/bug10/element-7516),
    # was previously worked around here with -e UID=0 -e GID=0.
    docker run --rm -v "$DATA_DIR:/data" \
        -e SYNAPSE_SERVER_NAME="test-$bug.invalid" -e SYNAPSE_REPORT_STATS=no \
        "clods-synapse:$bug" generate >/dev/null

    RUN_ARGS=()
    for ib in "${INSTRUMENTED_TAGS[@]}"; do
        if [ "$ib" = "$bug" ]; then
            RUN_ARGS+=(-e SYNAPSE_INSTRUMENT=/opt/python-instrumentation/driver.py)
        fi
    done
    docker run -d --name "$NAME" -p "$TEST_PORT:8008" -v "$DATA_DIR:/data" \
        "${RUN_ARGS[@]}" "clods-synapse:$bug" >/dev/null

    OK=0
    for i in $(seq 1 20); do
        if curl -fsS "http://127.0.0.1:$TEST_PORT/health" >/dev/null 2>&1; then
            OK=1
            break
        fi
        sleep 2
    done

    if [ "$OK" = 1 ]; then
        echo "$bug: OK (clods-synapse:$bug responds on /health)"
    else
        echo "$bug: FAILED -- no response after 40s, last logs:" >&2
        docker logs "$NAME" 2>&1 | tail -30 >&2
        FAILED+=("$bug")
    fi

    docker rm -f "$NAME" >/dev/null 2>&1 || true
done

# owned by UID 991 (the containers' default non-root user, not the host's) -- still not
# the invoking host user, so plain rm can't touch these
sudo rm -rf "$WORKDIR"

echo
if [ ${#FAILED[@]} -eq 0 ]; then
    echo "All 5 images built and responded to /health: ${ALL_TAGS[*]}"
else
    echo "FAILED: ${FAILED[*]}" >&2
    exit 1
fi
