#!/bin/bash
# Install + start the Synapse homeserver set up by setup_https_homeserver.sh
# as a systemd service (survives reboots, auto-restarts on crash, logs via
# journald). Idempotent — safe to re-run after config changes to pick them up.
#
# Run this ON THE EC2 BOX as root, after setup_https_homeserver.sh has
# already created /opt/synapse-clods/{homeserver.yaml,venv}.
#
# Usage:
#   sudo ./start_synapse.sh          # install unit (if needed) + start/restart
#   systemctl status synapse-clods   # check it's up
#   journalctl -u synapse-clods -f   # tail logs
#   systemctl stop synapse-clods     # stop
#   systemctl restart synapse-clods  # restart (e.g. after editing homeserver.yaml)

set -euo pipefail

BASE=/opt/synapse-clods
VENV="$BASE/venv"
CONFDIR="$BASE"
SVC_USER=synapse-clods

if [ ! -f "$CONFDIR/homeserver.yaml" ] || [ ! -x "$VENV/bin/python" ]; then
    echo "$CONFDIR/homeserver.yaml or $VENV not found — run setup_https_homeserver.sh first." >&2
    exit 1
fi

echo "== dedicated service user =="
id -u "$SVC_USER" >/dev/null 2>&1 || \
    useradd --system --home-dir "$BASE" --shell /usr/sbin/nologin "$SVC_USER"
chown -R "$SVC_USER":"$SVC_USER" "$BASE"

echo "== generating any missing signing key / secrets before first start =="
"$VENV/bin/python" -m synapse.app.homeserver \
    --config-path "$CONFDIR/homeserver.yaml" --generate-keys

echo "== writing systemd unit =="
cat > /etc/systemd/system/synapse-clods.service <<EOF
[Unit]
Description=Synapse Matrix homeserver (CLODS test instance)
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=$SVC_USER
WorkingDirectory=$BASE
ExecStart=$VENV/bin/python -m synapse.app.homeserver --config-path=$CONFDIR/homeserver.yaml
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=3
SyslogIdentifier=synapse-clods

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable synapse-clods >/dev/null
systemctl restart synapse-clods

sleep 2
if systemctl is-active --quiet synapse-clods; then
    echo "== synapse-clods is up =="
else
    echo "== FAILED to start — check: journalctl -u synapse-clods -n 50 --no-pager ==" >&2
    exit 1
fi

echo "== quick health check against the loopback listener =="
curl -fsS http://127.0.0.1:8008/health && echo " (Synapse responded)" || \
    echo "no response on :8008 yet — give it a few more seconds and retry"

cat <<EOF

nginx (from setup_https_homeserver.sh) should now be proxying this to
https://<public-ip>:8448 with the self-signed cert.

Useful commands:
  systemctl status synapse-clods
  journalctl -u synapse-clods -f
  systemctl restart synapse-clods   # after any homeserver.yaml edit
EOF
