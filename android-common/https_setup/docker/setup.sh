#!/bin/bash
# Docker-based replacement for ../setup_https_homeserver.sh + ../start_synapse.sh --
# builds Synapse from its own docker/Dockerfile (no manual poetry/rust/venv wrangling
# on the host) instead of a from-source venv, and runs it via `docker compose` instead
# of a hand-rolled systemd unit.
#
# Layout this script expects (see docker-compose.yml's header comment):
#   ~/clods/synapse/                 <- rsync of android/synapse
#   ~/clods/Python-Instrumentation/  <- rsync of android/Python-Instrumentation (unused by
#                                        this script, but expected alongside for later)
#   ~/clods/docker-compose.yml
#   ~/clods/setup.sh                 <- this file
#
# Run as: ./setup.sh <public-ip>   (from inside ~/clods, as a user in the `docker` group
# or via sudo -- whichever your docker install needs)
#
# What it does:
#   1. generates homeserver.yaml the official way (`docker compose run synapse generate`)
#   2. patches in the same listener/database/rate-limit settings as the non-docker path,
#      using the *container's own* python (it already has PyYAML as a Synapse dependency
#      -- no host-side pip install needed)
#   3. self-signed CA + leaf cert (SAN = public IP), same as the non-docker path
#   4. nginx on the host terminating TLS on :8448, proxying to the container's
#      published 127.0.0.1:8008
#   5. docker compose build && up -d, then a health check

set -euo pipefail

PUBLIC_IP="${1:-$(curl -fsS -4 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')}"

if [ -z "$PUBLIC_IP" ]; then
    echo "Could not auto-detect a public IP. Usage: $0 <public-ip>" >&2
    exit 1
fi
echo "== using public IP: $PUBLIC_IP =="

cd "${2}"

if [ ! -d synapse/docker ]; then
    echo "synapse/docker not found -- rsync android/synapse to ./synapse first." >&2
    exit 1
fi
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    echo "Need Docker + the docker compose plugin installed first." >&2
    exit 1
fi

if [ ! -f data/homeserver.yaml ]; then
    echo "== generating homeserver.yaml =="
    docker compose run --rm \
        -e SYNAPSE_SERVER_NAME="$PUBLIC_IP" \
        -e SYNAPSE_REPORT_STATS=no \
        synapse generate
fi

echo "== patching in listener/database/rate-limit settings =="
docker compose run --rm -T --no-deps --entrypoint python3 synapse - <<'PYEOF'
import yaml

path = "/data/homeserver.yaml"
with open(path) as f:
    cfg = yaml.safe_load(f)

cfg["listeners"] = [{
    "port": 8008,
    "tls": False,
    "type": "http",
    "x_forwarded": True,
    "bind_addresses": ["0.0.0.0"],  # must stay reachable across the compose network, unlike
                                     # the non-docker path's loopback-only bind
    "resources": [{"names": ["client", "federation"], "compress": False}],
}]

cfg["database"] = {
    "name": "psycopg2",
    "args": {
        "user": "synapse_user",
        "password": "admin",
        "dbname": "synapse",
        "host": "postgres",  # the compose service name, not localhost
        "cp_min": 5,
        "cp_max": 10,
    },
}

cfg["report_stats"] = False
cfg["trusted_key_servers"] = [{"server_name": "matrix.org"}]
cfg["rc_message"] = {"per_second": 10000, "burst_count": 10000}

with open(path, "w") as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
print(f"patched {path}")
PYEOF
