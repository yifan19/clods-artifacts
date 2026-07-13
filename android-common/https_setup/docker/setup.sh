#!/bin/bash
# Generates + patches homeserver.yaml for the docker-based Synapse setup. Config only --
# building images is PER_BUG_BUILD_GUIDE.md's job (or ./build_and_test_all_bugs.sh), running
# one against this config is ./run_bug.sh's job.
#
# Needs at least one clods-synapse:<bug> image already built first -- any tag works here,
# `generate` doesn't care which bug's Synapse binary produces the config.
#
# Usage: ./setup.sh <public-ip> [working-dir]
#   working-dir defaults to this script's own directory. homeserver.yaml lands in
#   <working-dir>/data/homeserver.yaml -- exactly where run_bug.sh looks for it.

set -euo pipefail

PUBLIC_IP="${1:-$(curl -fsS -4 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')}"
if [ -z "$PUBLIC_IP" ]; then
    echo "Could not auto-detect a public IP. Usage: $0 <public-ip> [working-dir]" >&2
    exit 1
fi

WORKDIR="${2:-$(dirname "$0")}"
cd "$WORKDIR"
echo "== using public IP: $PUBLIC_IP, working dir: $(pwd) =="

if ! command -v docker >/dev/null 2>&1; then
    echo "Docker not found." >&2
    exit 1
fi

TAG="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^clods-synapse:' | head -1)"
if [ -z "$TAG" ]; then
    echo "No clods-synapse:* image found -- build at least one first (see PER_BUG_BUILD_GUIDE.md" >&2
    echo "or run ./build_and_test_all_bugs.sh, which builds all 5)." >&2
    exit 1
fi
echo "== using $TAG to generate config =="

mkdir -p data

if [ ! -f data/homeserver.yaml ]; then
    echo "== generating homeserver.yaml =="
    docker run --rm -v "$(pwd)/data:/data" \
        -e SYNAPSE_SERVER_NAME="$PUBLIC_IP" -e SYNAPSE_REPORT_STATS=no \
        "$TAG" generate
fi

echo "== patching in listener/rate-limit settings =="
docker run --rm -v "$(pwd)/data:/data" --entrypoint python3 "$TAG" - <<'PYEOF'
import yaml

path = "/data/homeserver.yaml"
with open(path) as f:
    cfg = yaml.safe_load(f)

cfg["listeners"] = [{
    "port": 8008,
    "tls": False,
    "type": "http",
    "x_forwarded": True,
    "bind_addresses": ["0.0.0.0"],  # must stay reachable from the host (run_bug.sh publishes
                                     # this port), not just loopback
    "resources": [{"names": ["client", "federation"], "compress": False}],
}]

# Left on the default sqlite3 backend from `generate` -- no docker-compose (and no postgres
# container/network) in this flow anymore, and the previous `host: postgres` value only ever
# resolved inside a docker-compose network. If you want postgres back, run one yourself and
# either put it on a network run_bug.sh's container joins, or patch database.args.host here to
# wherever it's actually reachable.

cfg["report_stats"] = False
cfg["trusted_key_servers"] = [{"server_name": "matrix.org"}]
cfg["rc_message"] = {"per_second": 10000, "burst_count": 10000}

with open(path, "w") as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
print(f"patched {path}")
PYEOF

echo
echo "== done -- start a bug's server with: ./run_bug.sh <bug> =="
