#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${RGNODES_APP_DIR:-/root/rgnodes-vps-bot}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
SERVICE_NAME="bot.service"
LOG_FILE="/var/log/rgnodes-setup.log"

exec > >(tee -a "$LOG_FILE") 2>&1

log(){ printf '[RGNODES-SETUP] %s\n' "$*"; }
warn(){ printf '[RGNODES-SETUP][WARN] %s\n' "$*" >&2; }
fail(){ printf '[RGNODES-SETUP][ERROR] %s\n' "$*" >&2; exit 1; }
trap 'warn "Setup failed at line $LINENO. Check $LOG_FILE"' ERR

[[ $EUID -eq 0 ]] || fail 'Run this setup script as root: sudo bash setup_rgnodes.sh'
command -v apt >/dev/null 2>&1 || fail 'This installer requires an apt-based Linux host.'

log 'Detecting operating system and package manager...'
. /etc/os-release || true
log "Detected: ${PRETTY_NAME:-unknown}"

export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y \
  python3 python3-pip python3-venv python3-dev build-essential \
  curl ca-certificates git \
  qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virt-manager virtinst \
  sudo openssh-server nodejs npm

log 'Configuring pip safely for system installs while using an isolated venv for the bot...'
mkdir -p /root/.config/pip
cat > /root/.config/pip/pip.conf <<'PIPEOF'
[global]
break-system-packages = true
PIPEOF

log 'Ensuring SSH and libvirt are enabled on the host...'
systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true
systemctl enable --now libvirtd >/dev/null 2>&1 || systemctl enable --now virtqemud >/dev/null 2>&1 || true
systemctl status libvirtd --no-pager >/dev/null 2>&1 || true

log 'Locating bot source files...'
BOT_SOURCE=''
REQ_SOURCE=''
ENV_SOURCE=''
for candidate in "$SCRIPT_DIR/bot.py" "/root/bot.py" "$SCRIPT_DIR/bot_rgnodes_v8_89_fixed.py"; do
  if [[ -f "$candidate" ]]; then BOT_SOURCE="$candidate"; break; fi
done
[[ -n "$BOT_SOURCE" ]] || fail "bot.py not found next to setup script or /root/bot.py"
for candidate in "$SCRIPT_DIR/requirements.txt" "$APP_DIR/requirements.txt"; do
  if [[ -f "$candidate" ]]; then REQ_SOURCE="$candidate"; break; fi
done
[[ -n "$REQ_SOURCE" ]] || fail 'requirements.txt not found.'
for candidate in "$APP_DIR/.env" "/root/.env" "$SCRIPT_DIR/.env"; do
  if [[ -f "$candidate" ]]; then ENV_SOURCE="$candidate"; break; fi
done

mkdir -p "$APP_DIR"
install -m 0755 "$BOT_SOURCE" "$APP_DIR/bot.py"
install -m 0644 "$REQ_SOURCE" "$APP_DIR/requirements.txt"

if [[ -z "$ENV_SOURCE" ]]; then
  if [[ -f "$SCRIPT_DIR/.env.example" ]]; then
    install -m 0600 "$SCRIPT_DIR/.env.example" "$APP_DIR/.env"
    warn 'Created $APP_DIR/.env from .env.example. Put the Discord token there before starting the bot.'
  else
    fail 'No .env or .env.example found.'
  fi
elif [[ "$ENV_SOURCE" != "$APP_DIR/.env" ]]; then
  install -m 0600 "$ENV_SOURCE" "$APP_DIR/.env"
fi

log 'Validating Python source before changing the service...'
"$PYTHON_BIN" -m py_compile "$APP_DIR/bot.py"

log 'Creating isolated Python environment...'
if [[ ! -x "$APP_DIR/.venv/bin/python" ]]; then
  "$PYTHON_BIN" -m venv "$APP_DIR/.venv"
fi
"$APP_DIR/.venv/bin/python" -m pip install --upgrade pip setuptools wheel
"$APP_DIR/.venv/bin/python" -m pip install -r "$APP_DIR/requirements.txt"

log 'Checking LXD CLI and initializing a default LXD storage/network configuration when needed...'
if ! command -v lxc >/dev/null 2>&1 || ! lxc info >/dev/null 2>&1; then
  apt install -y snapd
  systemctl enable --now snapd.socket >/dev/null 2>&1 || true
  if ! command -v snap >/dev/null 2>&1; then fail 'snap command is unavailable after installing snapd.'; fi
  snap install lxd
  ln -sf /snap/bin/lxc /usr/local/bin/lxc
  ln -sf /snap/bin/lxd /usr/local/bin/lxd
fi

if ! lxc info >/dev/null 2>&1; then
  if command -v lxd >/dev/null 2>&1; then
    lxd init --auto
  else
    fail 'LXD is installed but its lxc/lxd client is not usable.'
  fi
fi

if ! lxc storage show default >/dev/null 2>&1; then
  log 'LXD default storage pool is missing; attempting automatic initialization...'
  lxd init --auto || true
fi
lxc storage show default >/dev/null 2>&1 || warn 'LXD storage pool "default" was not detected. Set DEFAULT_STORAGE_POOL in .env to your real pool.'

log 'Installing PM2...'
npm install -g pm2
PM2_RUNTIME="$(command -v pm2-runtime || true)"
[[ -n "$PM2_RUNTIME" ]] || fail 'pm2-runtime was not found after installation.'

log 'Creating PM2 ecosystem configuration...'
APP_DIR_JS=$(printf '%s' "$APP_DIR" | sed "s/[\\&']/\\\\\\&/g")
cat > "$APP_DIR/ecosystem.config.js" <<EOFJS
module.exports = {
  apps: [{
    name: 'RGNODES-VPS-BOT',
    cwd: '$APP_DIR_JS',
    script: 'bot.py',
    interpreter: '$APP_DIR_JS/.venv/bin/python',
    interpreter_args: '-u',
    autorestart: true,
    restart_delay: 5000,
    exp_backoff_restart_delay: 100,
    max_memory_restart: '512M',
    kill_timeout: 10000,
    listen_timeout: 10000,
    env: {
      PYTHONUNBUFFERED: '1'
    }
  }]
};
EOFJS

log 'Creating systemd service (systemd supervises PM2; PM2 supervises the Python bot).'
cat > "/etc/systemd/system/$SERVICE_NAME" <<EOFUNIT
[Unit]
Description=RGNODES VPS Bot - PM2 Managed
After=network-online.target snap.lxd.daemon.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
Environment=PM2_HOME=/root/.pm2
Environment=PYTHONUNBUFFERED=1
ExecStart=$PM2_RUNTIME $APP_DIR/ecosystem.config.js
Restart=always
RestartSec=5
KillMode=mixed
TimeoutStopSec=20
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOFUNIT

log 'Installing a self-healing permission/network helper timer...'
cat > /usr/local/bin/rgnodes-healthcheck <<'EOS'
#!/usr/bin/env bash
set -u
APP_DIR="${RGNODES_APP_DIR:-/root/rgnodes-vps-bot}"
command -v lxc >/dev/null 2>&1 || exit 0
lxc info >/dev/null 2>&1 || exit 0
# Repair stale PM2 daemon state without launching a second bot process.
if systemctl is-active --quiet bot.service; then
  exit 0
fi
systemctl restart bot.service >/dev/null 2>&1 || true
EOS
chmod 0755 /usr/local/bin/rgnodes-healthcheck
cat > /etc/systemd/system/rgnodes-healthcheck.service <<'EOFUNIT'
[Unit]
Description=RGNODES VPS Bot health check
After=network-online.target bot.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/rgnodes-healthcheck
EOFUNIT
cat > /etc/systemd/system/rgnodes-healthcheck.timer <<'EOFUNIT'
[Unit]
Description=RGNODES VPS Bot periodic health check

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
AccuracySec=15s
Persistent=true

[Install]
WantedBy=timers.target
EOFUNIT

log 'Applying systemd changes and starting the single bot process...'
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl enable --now rgnodes-healthcheck.timer
systemctl restart "$SERVICE_NAME"
sleep 3

log 'Validation:'
systemctl --no-pager --full status "$SERVICE_NAME" || true
systemctl --no-pager --full status rgnodes-healthcheck.timer || true
lxc storage list || true
lxc network list || true

if grep -q '^DISCORD_TOKEN=$' "$APP_DIR/.env" 2>/dev/null; then
  warn 'DISCORD_TOKEN is blank. Add the bot token to: '"$APP_DIR/.env"
fi
if grep -q '^YOUR_SERVER_IP=127.0.0.1$' "$APP_DIR/.env" 2>/dev/null; then
  warn 'YOUR_SERVER_IP is still 127.0.0.1. Change it to the host address users should reach for port forwards.'
fi

log 'Setup complete.'
log "App: $APP_DIR"
log "Service: systemctl status $SERVICE_NAME"
log "Logs: journalctl -u $SERVICE_NAME -f"
log "PM2: pm2 list"
