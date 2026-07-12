#!/bin/bash
# Stand up a Synapse homeserver on this EC2 box, reachable over HTTPS from the
# Element debug APK, using a self-signed CA instead of a registered domain.
#
# Why this works: element-android's debug builds ship
#   vector/src/main/res/xml/network_security_config.xml
# with a <debug-overrides><trust-anchors><certificates src="user"/></...>
# block. That means the *debug* APK (which is what's vendored for every
# element-<bug> in final_artifact/) will trust any CA cert you manually
# install on the device — no public CA, no domain, no Cloudflare needed.
#
# Run this ON THE EC2 BOX as root (sudo -E ./setup_https_homeserver.sh).
#
# What it does:
#   1. apt-installs postgres/nginx/build deps
#   2. creates the synapse_user/synapse Postgres role+db
#   3. lets Synapse generate a correct homeserver.yaml skeleton (signing key,
#      log config, a *real* registration_shared_secret, etc.) then patches in
#      your listener/database/rate-limit settings
#   4. generates a self-signed CA + a leaf cert whose SAN is this box's public IP
#   5. configures nginx to terminate TLS on :8448 and proxy to Synapse's
#      loopback :8008 (matches x_forwarded: true / bind_addresses: loopback)
#   6. prints the exact steps to pull the CA onto your Android device and the
#      homeserver URL to type into Element
#
# NOTE on your pasted config: `registration_shared_secret: DATADIR/reg_key`
# was almost certainly a mistake — that key takes the *literal secret string*,
# not a path (the path-based variant is `registration_shared_secret_path`).
# As written, your shared secret would have been the 15-byte string
# "DATADIR/reg_key", which is weak and also breaks `register_new_matrix_user`
# if DATADIR was never substituted. This script lets Synapse generate a real
# random secret instead and does not use the path form.

set -euo pipefail

PUBLIC_IP="${1:-$(curl -fsS -4 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')}"
if [ -z "$PUBLIC_IP" ]; then
    echo "Could not auto-detect a public IP. Usage: $0 <public-ip>" >&2
    exit 1
fi
echo "== using public IP: $PUBLIC_IP =="

BASE=/opt/synapse-clods
CONFDIR="$BASE"
DATADIR="$BASE/data"
VENV="$BASE/venv"
SYNAPSE_SRC="${SYNAPSE_SRC:-/home/ubuntu/artifacts/android/synapse}"
FED_PORT=8448
CLIENT_PORT=8448   # same port for both here; split into 443/8448 later if you want

PGUSER=synapse_user
PGPASS=admin        # matches what you pasted; change PGPASS before running if you want something stronger
PGDB=synapse

mkdir -p "$CONFDIR" "$DATADIR/media_store"

echo "== apt deps =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    build-essential libpq-dev libffi-dev libssl-dev python3-dev python3-venv \
    postgresql nginx openssl >/dev/null

echo "== postgres role + db (UTF8 / C locale, required by Synapse) =="
su - postgres -c "psql -tc \"SELECT 1 FROM pg_roles WHERE rolname='${PGUSER}'\"" | grep -q 1 || \
    su - postgres -c "psql -c \"CREATE ROLE ${PGUSER} WITH LOGIN PASSWORD '${PGPASS}';\""
su - postgres -c "psql -tc \"SELECT 1 FROM pg_database WHERE datname='${PGDB}'\"" | grep -q 1 || \
    su - postgres -c "createdb --encoding=UTF8 --locale=C --template=template0 --owner=${PGUSER} ${PGDB}"

echo "== python venv + synapse (editable install from the vendored checkout) =="
python3 -m venv "$VENV"
"$VENV/bin/pip" install -q --upgrade pip
if [ -d "$SYNAPSE_SRC" ]; then
    "$VENV/bin/pip" install -q -e "$SYNAPSE_SRC[postgres]"
else
    "$VENV/bin/pip" install -q "matrix-synapse[postgres]"
fi

echo "== generating base homeserver.yaml (signing key, log config, real secrets) =="
if [ ! -f "$CONFDIR/homeserver.yaml" ]; then
    "$VENV/bin/python" -m synapse.app.homeserver \
        --server-name "$PUBLIC_IP" \
        --config-path "$CONFDIR/homeserver.yaml" \
        --config-dir "$CONFDIR" \
        --data-directory "$DATADIR" \
        --generate-config \
        --report-stats=no
fi

echo "== patching in your listener/database/rate-limit settings =="
"$VENV/bin/python" - "$CONFDIR/homeserver.yaml" "$PGUSER" "$PGPASS" "$PGDB" <<'PYEOF'
import sys, yaml

path, pguser, pgpass, pgdb = sys.argv[1:5]
with open(path) as f:
    cfg = yaml.safe_load(f)

cfg["listeners"] = [{
    "port": 8008,
    "tls": False,
    "type": "http",
    "x_forwarded": True,
    "bind_addresses": ["::1", "127.0.0.1"],
    "resources": [{"names": ["client", "federation"], "compress": False}],
}]

cfg["database"] = {
    "name": "psycopg2",
    "args": {
        "user": pguser,
        "password": pgpass,
        "dbname": pgdb,
        "host": "localhost",
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
CERTDIR="$BASE/certs"
mkdir -p "$CERTDIR"
if [ ! -f "$CERTDIR/ca.key" ]; then
    openssl genrsa -out "$CERTDIR/ca.key" 4096
    openssl req -x509 -new -nodes -key "$CERTDIR/ca.key" -sha256 -days 3650 \
        -subj "/CN=CLODS test CA" -out "$CERTDIR/ca.crt"
fi
openssl genrsa -out "$CERTDIR/server.key" 2048
openssl req -new -key "$CERTDIR/server.key" -subj "/CN=$PUBLIC_IP" \
    -out "$CERTDIR/server.csr"
cat > "$CERTDIR/server.ext" <<EOF
subjectAltName = IP:$PUBLIC_IP
extendedKeyUsage = serverAuth
EOF
openssl x509 -req -in "$CERTDIR/server.csr" -CA "$CERTDIR/ca.crt" -CAkey "$CERTDIR/ca.key" \
    -CAcreateserial -out "$CERTDIR/server.crt" -days 825 -sha256 -extfile "$CERTDIR/server.ext"

echo "== nginx: TLS termination on :$FED_PORT -> 127.0.0.1:8008 =="
cat > /etc/nginx/sites-available/synapse-clods <<EOF
server {
    listen $CLIENT_PORT ssl default_server;
    listen [::]:$CLIENT_PORT ssl default_server;

    server_name $PUBLIC_IP;

    ssl_certificate     $CERTDIR/server.crt;
    ssl_certificate_key $CERTDIR/server.key;

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
ln -sf /etc/nginx/sites-available/synapse-clods /etc/nginx/sites-enabled/synapse-clods
nginx -t && systemctl reload nginx

echo "== done =="
cat <<EOF

Next steps:

1. Start Synapse in the foreground to sanity-check it, then Ctrl-C and run it
   under systemd/tmux/screen for real:
     sudo -u postgres true   # (already set up above)
     $VENV/bin/python -m synapse.app.homeserver -c $CONFDIR/homeserver.yaml

2. Create a test account:
     $VENV/bin/register_new_matrix_user -c $CONFDIR/homeserver.yaml http://localhost:8008

3. Pull the CA cert to your workstation and push it to the Android device:
     scp <this-box>:$CERTDIR/ca.crt .
     adb push ca.crt /sdcard/Download/
     adb shell am start -a android.intent.action.VIEW \\
         -d file:///sdcard/Download/ca.crt -t application/x-x509-ca-cert
   (Android will prompt to confirm installing it as a CA cert — this
   confirmation tap can't be scripted, it's an intentional OS security gate.)
   Name it something recognizable ("CLODS test CA"). It installs as a
   *user* CA, which is exactly what element-android's debug-overrides trusts.

4. In Element, "sign in" -> choose a custom homeserver -> enter:
     https://$PUBLIC_IP:$FED_PORT

EOF
