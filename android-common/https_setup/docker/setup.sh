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
cd "$(dirname "$0")"

PUBLIC_IP="${1:-$(curl -fsS -4 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')}"
if [ -z "$PUBLIC_IP" ]; then
    echo "Could not auto-detect a public IP. Usage: $0 <public-ip>" >&2
    exit 1
fi
echo "== using public IP: $PUBLIC_IP =="

if [ ! -d synapse/docker ]; then
    echo "synapse/docker not found -- rsync android/synapse to ./synapse first." >&2
    exit 1
fi
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    echo "Need Docker + the docker compose plugin installed first." >&2
    exit 1
fi

mkdir -p data certs

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

echo "== self-signed CA + leaf cert (SAN = $PUBLIC_IP) =="
if [ ! -f certs/ca.key ]; then
    openssl genrsa -out certs/ca.key 4096
    openssl req -x509 -new -nodes -key certs/ca.key -sha256 -days 3650 \
        -subj "/CN=CLODS test CA" -out certs/ca.crt
fi
openssl genrsa -out certs/server.key 2048
openssl req -new -key certs/server.key -subj "/CN=$PUBLIC_IP" -out certs/server.csr
cat > certs/server.ext <<EOF
subjectAltName = IP:$PUBLIC_IP
extendedKeyUsage = serverAuth
EOF
openssl x509 -req -in certs/server.csr -CA certs/ca.crt -CAkey certs/ca.key \
    -CAcreateserial -out certs/server.crt -days 825 -sha256 -extfile certs/server.ext

echo "== nginx: TLS termination on :8448 -> 127.0.0.1:8008 =="
sudo tee /etc/nginx/sites-available/synapse-clods >/dev/null <<EOF
server {
    listen 8448 ssl default_server;
    listen [::]:8448 ssl default_server;

    server_name $PUBLIC_IP;

    ssl_certificate     $(pwd)/certs/server.crt;
    ssl_certificate_key $(pwd)/certs/server.key;

    location ~ ^(/_matrix|/_synapse/client) {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
        client_max_body_size 50M;
        proxy_http_version 1.1;
    }
}
EOF
sudo ln -sf /etc/nginx/sites-available/synapse-clods /etc/nginx/sites-enabled/synapse-clods
sudo nginx -t && sudo systemctl reload nginx

echo "== building + starting =="
docker compose build
docker compose up -d

sleep 3
docker compose ps
curl -fsS http://127.0.0.1:8008/health && echo " (Synapse responded)" || \
    echo "no response yet -- check: docker compose logs -f synapse"

cat <<EOF

Next steps:
  docker compose logs -f synapse         # tail logs
  docker compose exec synapse register_new_matrix_user http://localhost:8008 -c /data/homeserver.yaml
  curl -vk https://$PUBLIC_IP:8448/_matrix/client/versions   # from outside the box
EOF
