#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
APP=/opt/rgnodes-node-agent
ENV=/etc/rgnodes/node-agent.env
UNIT=/etc/systemd/system/rgnodes-node-agent.service
[[ $EUID -eq 0 ]] || { echo 'Run as root.'; exit 1; }
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
apt update
apt install -y python3 python3-pip python3-venv python3-dev build-essential libffi-dev pkg-config ca-certificates curl sudo openssh-server openssh-client snapd lsb-release procps iproute2 iputils-ping net-tools
systemctl enable --now snapd.socket >/dev/null 2>&1 || true
export PATH="/snap/bin:$PATH"
hash -r
if ! command -v lxc >/dev/null 2>&1 && [[ -x /snap/bin/lxc ]]; then hash -r; fi
if ! command -v lxc >/dev/null 2>&1; then
  snap wait system seed.loaded >/dev/null 2>&1 || true
  snap list lxd >/dev/null 2>&1 || snap install lxd
  export PATH="/snap/bin:$PATH"; hash -r
fi
command -v lxc >/dev/null 2>&1 || [[ -x /snap/bin/lxc ]] || { echo 'LXD/LXC is unavailable.'; exit 1; }
if ! /snap/bin/lxc info >/dev/null 2>&1 && ! lxc info >/dev/null 2>&1; then
  cat >/tmp/rgnodes-node-preseed.yaml <<'YAML'
config: {}
networks:
- name: lxdbr0
  type: bridge
  config:
    ipv4.address: auto
    ipv4.nat: "true"
    ipv6.address: none
storage_pools:
- name: default
  driver: dir
profiles:
- name: default
  devices:
    eth0:
      type: nic
      name: eth0
      network: lxdbr0
    root:
      type: disk
      path: /
      pool: default
YAML
  lxd init --preseed </tmp/rgnodes-node-preseed.yaml
  rm -f /tmp/rgnodes-node-preseed.yaml
fi
install -d -m 0755 "$APP" /etc/rgnodes
install -m 0755 "$SCRIPT_DIR/node-agent.py" "$APP/node-agent.py"
if [[ -f "$ENV" ]]; then
  chmod 0600 "$ENV"
fi
if [[ ! -f "$ENV" ]] || ! grep -q '^RGNODES_NODE_API_KEY=.' "$ENV" 2>/dev/null; then
  key="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)"
  printf 'RGNODES_NODE_API_KEY=%s\nRGNODES_AGENT_PORT=18443\n' "$key" > "$ENV"
  chmod 0600 "$ENV"
  echo
  echo "Generated node API key (save it securely):"
  echo "$key"
fi
cat > "$UNIT" <<'EOF'
[Unit]
Description=RGNODES Remote LXD Node Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/rgnodes-node-agent
EnvironmentFile=/etc/rgnodes/node-agent.env
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 /opt/rgnodes-node-agent/node-agent.py --host=0.0.0.0
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$UNIT"
systemctl daemon-reload
if command -v sshd >/dev/null 2>&1; then
  sshd -t || { echo '❌ Existing sshd configuration is invalid; not restarting SSH.' >&2; exit 1; }
  systemctl enable --now ssh.service >/dev/null 2>&1 || systemctl enable --now sshd.service >/dev/null 2>&1 || true
fi
systemctl enable --now rgnodes-node-agent.service
python3 -m py_compile "$APP/node-agent.py"
ss -lntp 2>/dev/null | grep -q ':18443' || true
echo '✅ RGNODES™ node agent installed.'
