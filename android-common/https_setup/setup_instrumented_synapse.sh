#!/bin/bash
# Rebuild the Synapse venv on Python 3.10 (required by Python-Instrumentation's
# bytecode rewriting — CALL_FUNCTION doesn't exist as an opcode on 3.11+, so
# this WILL crash on Ubuntu 24.04's default python3 (3.12)) and install
# Python-Instrumentation's own deps into that same venv, since the driver
# imports/execs Synapse in-process — both have to live in one interpreter.
#
# Run this ON THE EC2 BOX as root, after setup_https_homeserver.sh has already
# created /opt/synapse-clods. Rebuilds the venv in place; homeserver.yaml,
# certs, nginx config, postgres are untouched.
#
# Usage: sudo ./setup_instrumented_synapse.sh [/path/to/Python-Instrumentation]
#   (defaults to /opt/synapse-clods/Python-Instrumentation — rsync/scp the
#   android/Python-Instrumentation/ directory there first if it's not already)

set -euo pipefail

BASE=/opt/synapse-clods
VENV="$BASE/venv"
SYNAPSE_SRC="${SYNAPSE_SRC:-/home/ubuntu/artifacts/android/synapse}"
PI_DIR="${1:-$BASE/Python-Instrumentation}"

if [ ! -f "$BASE/homeserver.yaml" ]; then
    echo "$BASE/homeserver.yaml not found — run setup_https_homeserver.sh first." >&2
    exit 1
fi
if [ ! -f "$PI_DIR/driver.py" ]; then
    echo "$PI_DIR/driver.py not found." >&2
    echo "scp -r android/Python-Instrumentation/ <this-box>:$PI_DIR first." >&2
    exit 1
fi

echo "== installing Python 3.10 (deadsnakes PPA — Ubuntu 24.04 ships 3.12 by default) =="
export DEBIAN_FRONTEND=noninteractive
if ! command -v python3.10 >/dev/null 2>&1; then
    apt-get install -y -qq software-properties-common >/dev/null
    add-apt-repository -y ppa:deadsnakes/ppa >/dev/null
    apt-get update -qq
    apt-get install -y -qq python3.10 python3.10-venv python3.10-dev >/dev/null
fi
python3.10 --version

echo "== rebuilding $VENV on python3.10 =="
systemctl stop synapse-clods 2>/dev/null || true
rm -rf "$VENV"
python3.10 -m venv "$VENV"
"$VENV/bin/pip" install -q --upgrade pip

if [ -d "$SYNAPSE_SRC" ]; then
    "$VENV/bin/pip" install -q -e "$SYNAPSE_SRC[postgres]"
else
    "$VENV/bin/pip" install -q "matrix-synapse[postgres]"
fi

echo "== installing Python-Instrumentation's deps (pinned to match its own vendored .venv) =="
"$VENV/bin/pip" install -q "setuptools==59.6.0" "bytecode==0.15.1"

echo "== sanity check: CALL_FUNCTION opcode must exist on this interpreter =="
"$VENV/bin/python" -c "
import sys
assert sys.version_info[:2] <= (3, 10), f'need <=3.10, got {sys.version_info[:2]}'
from bytecode import Instr
Instr('CALL_FUNCTION', 2)
print('OK:', sys.version)
"

chown -R synapse-clods:synapse-clods "$BASE" 2>/dev/null || true

cat <<EOF

== done ==

The venv at $VENV is now Python 3.10 + has Python-Instrumentation's deps.
Regenerate signing keys are untouched (same CONFDIR), so homeserver.yaml still works.

Next: run Synapse *through* the instrumentation driver instead of directly —
see run_instrumented_synapse.sh (make sure synapse-clods.service is stopped
first, both bind to the same port):

  systemctl stop synapse-clods
  ./run_instrumented_synapse.sh

Edit $PI_DIR/constants/hooks.py's USER_CALLABLES_TO_HOOK to change which
round/probe is active before each run — the driver has no properties-file
reader, the hook list in that file *is* the currently-armed round.
EOF
