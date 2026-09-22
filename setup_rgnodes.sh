#!/usr/bin/env bash
# =============================================================================
# RGNODES™ VPS Bot — Deep Auto Setup / Repair v9
# Debian/Ubuntu • LXD • SSH • libvirt/KVM (best-effort) • Python venv • PM2
# Safe: never overwrites existing .env or vps.db; idempotent and rollback-aware.
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

APP_DIR="${RGNODES_APP_DIR:-/root/rgnodes-vps-bot}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
SERVICE_NAME="bot.service"
PM2_APP="RGNODES-VPS-BOT"
LOG_FILE="/var/log/rgnodes-setup.log"
LOCK_FILE="/run/lock/rgnodes-setup.lock"
BACKUP_ROOT="/var/backups/rgnodes-bot"

mkdir -p /run/lock "$BACKUP_ROOT" /var/log
exec 9>"$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || die "Another RGNODES™ setup/repair process is already running."
fi
exec > >(tee -a "$LOG_FILE") 2>&1

log(){ printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn(){ log "⚠️ $*"; }
die(){ log "❌ $*"; exit 1; }
trap 'rc=$?; (( rc != 0 )) && warn "Setup stopped at line $LINENO (exit $rc). See $LOG_FILE"' EXIT

[[ $EUID -eq 0 ]] || die 'Run as root: sudo bash setup_rgnodes.sh'
command -v apt >/dev/null 2>&1 || die 'apt is required.'

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_MODE=a

. /etc/os-release
log "Detected: ${PRETTY_NAME:-unknown}"
case "${ID:-}" in
  debian|ubuntu) ;;
  *) warn "This setup is optimized for Debian/Ubuntu; continuing with safety checks." ;;
esac

# ---------- helpers ----------
retry(){
  local attempts="$1"; shift
  local i
  for ((i=1;i<=attempts;i++)); do
    if "$@"; then return 0; fi
    (( i < attempts )) && sleep $((i*2))
  done
  return 1
}

pkg_install(){
  apt install -y --no-install-recommends "$@"
}

backup_runtime(){
  local stamp dir
  stamp="$(date '+%Y%m%d_%H%M%S')"
  dir="$BACKUP_ROOT/$stamp"
  mkdir -p "$dir"
  [[ -f "$APP_DIR/bot.py" ]] && cp -a "$APP_DIR/bot.py" "$dir/" || true
  [[ -f "$APP_DIR/requirements.txt" ]] && cp -a "$APP_DIR/requirements.txt" "$dir/" || true
  [[ -f "$APP_DIR/ecosystem.config.js" ]] && cp -a "$APP_DIR/ecosystem.config.js" "$dir/" || true
  [[ -f "$APP_DIR/node-agent.py" ]] && cp -a "$APP_DIR/node-agent.py" "$dir/" || true
  [[ -f "$APP_DIR/.env" ]] && cp -a "$APP_DIR/.env" "$dir/.env" || true
  for db in "$APP_DIR"/*.db "$APP_DIR"/*.db-wal "$APP_DIR"/*.db-shm; do
    [[ -f "$db" ]] && cp -a "$db" "$dir/" || true
  done
  if [[ -d "$APP_DIR/db_backups" ]]; then cp -a "$APP_DIR/db_backups" "$dir/"; fi
  echo "$dir" > "$BACKUP_ROOT/latest"
  chmod 700 "$dir"
  log "Backup: $dir"
}

# ---------- base host packages ----------
log "📦 Updating package indexes..."
retry 5 apt update || die 'apt update failed after retries.'

log "📦 Installing host dependencies..."
pkg_install \
  python3 python3-pip python3-venv python3-dev \
  build-essential libffi-dev pkg-config \
  curl ca-certificates git unzip \
  sudo openssh-server openssh-client \
  util-linux procps iproute2 iputils-ping net-tools \
  lsb-release \
  snapd nodejs npm

# ---------- SSH ----------
log "🔐 Repairing OpenSSH baseline..."
mkdir -p /etc/ssh /run/sshd
[[ -e /etc/ssh/sshd_config ]] || touch /etc/ssh/sshd_config
chmod 0755 /etc/ssh
chmod 0600 /etc/ssh/sshd_config 2>/dev/null || true

SSHD_UNIT=""
if systemctl list-unit-files ssh.service >/dev/null 2>&1; then SSHD_UNIT=ssh; fi
if [[ -z "$SSHD_UNIT" ]] && systemctl list-unit-files sshd.service >/dev/null 2>&1; then SSHD_UNIT=sshd; fi

if command -v sshd >/dev/null 2>&1; then
  sshd -t || die 'Existing sshd configuration is invalid; fix it before restarting SSH.'
fi
if [[ -n "$SSHD_UNIT" ]]; then
  systemctl enable --now "$SSHD_UNIT" || warn "Could not start $SSHD_UNIT automatically."
fi

log "🔎 SSH config:"
ls -la /etc/ssh/sshd_config || true

# ---------- libvirt / KVM ----------
log "🧩 Checking hardware virtualization (diagnostic only)..."
if command -v lscpu >/dev/null 2>&1; then
  lscpu | grep -iE '^Virtualization|^Virtualization type' || warn 'Hardware virtualization flags are not visible. LXC can still work; nested KVM may not.'
fi

log "📦 Installing libvirt/KVM packages when available..."
# These are host-side helpers. Failure here must not block LXD/LXC deployments.
if ! pkg_install qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virt-manager virtinst; then
  warn 'Some KVM/libvirt packages are unavailable on this host/repository; continuing with LXD.'
fi

for unit in libvirtd virtqemud; do
  if systemctl list-unit-files "$unit.service" >/dev/null 2>&1; then
    systemctl enable --now "$unit" || warn "$unit could not be started."
  fi
done
systemctl status libvirtd --no-pager >/dev/null 2>&1 || true

# root is the runtime user for this bot; group changes are harmless and retained.
usermod -aG libvirt root >/dev/null 2>&1 || true
usermod -aG kvm root >/dev/null 2>&1 || true

# ---------- LXD ----------
log "🦎 Detecting LXD..."
if ! command -v lxc >/dev/null 2>&1; then
  log "LXD CLI missing; installing official snap package."
  systemctl enable --now snapd.socket >/dev/null 2>&1 || true
  if ! snap list lxd >/dev/null 2>&1; then
    snap install lxd
  fi
fi

# Prefer snap binaries when present, but don't create dangerous aliases over an existing native installation.
command -v lxd >/dev/null 2>&1 || [[ -x /snap/bin/lxd ]] || die 'lxd command is unavailable.'
command -v lxc >/dev/null 2>&1 || [[ -x /snap/bin/lxc ]] || die 'lxc command is unavailable.'
export PATH="/snap/bin:$PATH"
hash -r

mkdir -p /etc/lxd

lxd_initialized=0
if lxc info >/dev/null 2>&1; then
  lxd_initialized=1
fi

if (( lxd_initialized == 0 )); then
  log "🛠️ Initializing LXD without interactive prompts..."
  if [[ ! -e /dev/loop-control ]]; then
    warn '/dev/loop-control is unavailable; forcing non-loop dir storage.'
  fi

  # A deterministic preseed avoids `lxd init --auto` choosing loop/LVM on nested hosts.
  # It is also safe to use when dir storage is required explicitly.
  cat > /tmp/rgnodes-lxd-preseed.yaml <<'YAML'
config: {}
networks:
- name: lxdbr0
  type: bridge
  description: RGNODES NAT bridge
  config:
    ipv4.address: auto
    ipv4.nat: "true"
    ipv6.address: none
storage_pools:
- name: default
  driver: dir
  description: RGNODES non-loop storage
  config: {}
profiles:
- name: default
  description: RGNODES default profile
  config: {}
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
  if ! lxd init --preseed < /tmp/rgnodes-lxd-preseed.yaml; then
    rm -f /tmp/rgnodes-lxd-preseed.yaml
    die 'LXD initialization failed.'
  fi
  rm -f /tmp/rgnodes-lxd-preseed.yaml
else
  log "✅ LXD already initialized; preserving existing configuration."
fi

# ---------- Repair/validate LXD objects ----------
log "🔎 Validating LXD storage/network/profile..."
if ! lxc storage show default >/dev/null 2>&1; then
  warn 'Storage pool "default" is missing.'
  # Only create it when there are no existing pools. Never overwrite a live pool.
  pool_count="$(lxc storage list --format csv 2>/dev/null | sed '/^$/d' | wc -l || echo 0)"
  if [[ "$pool_count" -eq 0 ]]; then
    lxc storage create default dir || die 'Could not create default dir storage pool.'
  else
    warn 'Existing storage pools detected; refusing destructive pool replacement. Set DEFAULT_STORAGE_POOL in .env to the correct pool.'
  fi
fi

if ! lxc network show lxdbr0 >/dev/null 2>&1; then
  log 'Creating missing lxdbr0 NAT network.'
  lxc network create lxdbr0 ipv4.address=auto ipv4.nat=true ipv6.address=none || warn 'Could not create lxdbr0.'
fi

if ! lxc profile show default >/dev/null 2>&1; then
  lxc profile create default || true
fi
# Add missing devices without replacing existing custom devices.
lxc profile device show default 2>/dev/null | grep -q '^root:' || lxc profile device add default root disk path=/ pool=default || true
lxc profile device show default 2>/dev/null | grep -q '^eth0:' || lxc profile device add default eth0 nic name=eth0 network=lxdbr0 || true

lxc storage show default >/dev/null 2>&1 || warn 'default storage is still unavailable.'
lxc network show lxdbr0 >/dev/null 2>&1 || warn 'lxdbr0 is still unavailable.'
lxc profile show default >/dev/null 2>&1 || die 'default LXD profile is unavailable.'
lxc info >/dev/null 2>&1 || die 'LXD daemon is not responding.'

# ZFS/udev are optional for dir storage. Do not fail the installer if absent.
modprobe zfs >/dev/null 2>&1 || udevadm trigger >/dev/null 2>&1 || true
source /etc/profile >/dev/null 2>&1 || true
hash -r

# ---------- bot source ----------
log "📁 Locating bot files..."
BOT_SOURCE=""
REQ_SOURCE=""
for candidate in "$SCRIPT_DIR/bot.py" "$SCRIPT_DIR/../bot.py" "/root/bot.py"; do
  if [[ -f "$candidate" ]]; then BOT_SOURCE="$candidate"; break; fi
done
[[ -n "$BOT_SOURCE" ]] || die 'bot.py not found.'

for candidate in "$SCRIPT_DIR/requirements.txt" "$APP_DIR/requirements.txt" "/root/requirements.txt"; do
  if [[ -f "$candidate" ]]; then REQ_SOURCE="$candidate"; break; fi
done
[[ -n "$REQ_SOURCE" ]] || die 'requirements.txt not found.'

mkdir -p "$APP_DIR" "$APP_DIR/db_backups" "$APP_DIR/vps_backups" /var/log
# Stop only our bot before taking the application/database snapshot.
systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
pm2 delete "$PM2_APP" >/dev/null 2>&1 || true
backup_runtime

# Preserve .env and DB at all costs.
if [[ ! -f "$APP_DIR/.env" ]]; then
  if [[ -f "$SCRIPT_DIR/.env.example" ]]; then
    install -m 0600 "$SCRIPT_DIR/.env.example" "$APP_DIR/.env"
    warn "Created $APP_DIR/.env from .env.example. Set DISCORD_TOKEN before start."
  else
    : > "$APP_DIR/.env"
    chmod 0600 "$APP_DIR/.env"
    warn "Created empty $APP_DIR/.env. Set DISCORD_TOKEN before start."
  fi
else
  chmod 0600 "$APP_DIR/.env"
fi

install -m 0755 "$BOT_SOURCE" "$APP_DIR/bot.py"
install -m 0644 "$REQ_SOURCE" "$APP_DIR/requirements.txt"
if [[ -f "$SCRIPT_DIR/node-agent.py" ]]; then
  install -m 0755 "$SCRIPT_DIR/node-agent.py" "$APP_DIR/node-agent.py"
fi

# ---------- Python environment ----------
log "🐍 Creating/repairing isolated Python environment..."
if [[ ! -x "$APP_DIR/.venv/bin/python" ]]; then
  "$PYTHON_BIN" -m venv "$APP_DIR/.venv"
fi
"$APP_DIR/.venv/bin/python" -m pip install --upgrade pip setuptools wheel
"$APP_DIR/.venv/bin/python" -m pip install -r "$APP_DIR/requirements.txt"

# Explicitly ensure DAVE/PyNaCl requested by the user are installed if requirements omitted them.
"$APP_DIR/.venv/bin/python" -m pip install 'davey>=0.1.6,<0.2' 'PyNaCl>=1.6.2,<2'

log "🧪 Validating Python syntax/imports..."
"$APP_DIR/.venv/bin/python" -m py_compile "$APP_DIR/bot.py"
"$APP_DIR/.venv/bin/python" - <<'PY'
import importlib
for name in ('discord', 'dotenv', 'requests', 'psutil', 'nacl', 'davey'):
    importlib.import_module(name)
print('dependency-import-smoke-test: OK')
PY

# ---------- permissions / stale locks ----------
log "🔒 Repairing ownership/permissions and stale runtime files..."
chown -R root:root "$APP_DIR"
chmod 0755 "$APP_DIR"
chmod 0600 "$APP_DIR/.env" 2>/dev/null || true
find "$APP_DIR" -maxdepth 1 -type f -name '*.db' -exec chmod 0600 {} + 2>/dev/null || true
find "$APP_DIR/db_backups" "$APP_DIR/vps_backups" -type f -exec chmod 0600 {} + 2>/dev/null || true
chmod 0755 "$APP_DIR/node-agent.py" 2>/dev/null || true
mkdir -p /run/rgnodes
chmod 0755 /run/rgnodes
rm -f /run/rgnodes/*.pid /run/rgnodes/*.lock 2>/dev/null || true

# ---------- PM2 ----------
log "⚙️ Installing/updating PM2..."
npm install -g pm2 >/dev/null 2>&1
PM2_RUNTIME="$(command -v pm2-runtime || true)"
[[ -n "$PM2_RUNTIME" ]] || [[ -x /usr/local/lib/node_modules/pm2/bin/pm2-runtime.js ]] || die 'pm2-runtime not found.'

# Encode paths as JSON strings using Python to avoid shell/JS quoting corruption.
APP_DIR_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$APP_DIR")"
PYTHON_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$APP_DIR/.venv/bin/python")"

cat > "$APP_DIR/ecosystem.config.js" <<EOFJS
module.exports = {
  apps: [{
    name: 'RGNODES-VPS-BOT',
    cwd: $APP_DIR_JSON,
    script: 'bot.py',
    interpreter: $PYTHON_JSON,
    interpreter_args: '-u',
    exec_mode: 'fork',
    instances: 1,
    autorestart: true,
    restart_delay: 5000,
    exp_backoff_restart_delay: 100,
    max_memory_restart: '768M',
    kill_timeout: 15000,
    listen_timeout: 15000,
    merge_logs: true,
    time: false,
    env: {
      PYTHONUNBUFFERED: '1'
    }
  }]
};
EOFJS
node --check "$APP_DIR/ecosystem.config.js"

# ---------- systemd wrapper ----------
log "🛡️ Installing single-process systemd → PM2 runtime supervision..."
cat > "/etc/systemd/system/$SERVICE_NAME" <<EOFUNIT
[Unit]
Description=RGNODES VPS Bot - PM2 Runtime
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
Environment=HOME=/root
Environment=PM2_HOME=/root/.pm2
Environment=PYTHONUNBUFFERED=1
ExecStart=$PM2_RUNTIME $APP_DIR/ecosystem.config.js
Restart=always
RestartSec=5
KillMode=mixed
TimeoutStopSec=30
LimitNOFILE=65535
TasksMax=infinity

[Install]
WantedBy=multi-user.target
EOFUNIT

# ---------- optional system health ----------
cat > /usr/local/sbin/rgnodes-healthcheck <<'EOF'
#!/usr/bin/env bash
set -u
if ! command -v lxc >/dev/null 2>&1; then exit 0; fi
lxc info >/dev/null 2>&1 || exit 0
ENV_FILE="/root/rgnodes-vps-bot/.env"
if [[ -f "$ENV_FILE" ]] && grep -qE '^DISCORD_TOKEN[[:space:]]*=[[:space:]]*$' "$ENV_FILE"; then exit 0; fi
systemctl is-enabled --quiet bot.service || exit 0
systemctl is-active --quiet bot.service || systemctl restart bot.service >/dev/null 2>&1 || true
EOF
chmod 0755 /usr/local/sbin/rgnodes-healthcheck
cat > /etc/systemd/system/rgnodes-healthcheck.service <<'EOF'
[Unit]
Description=RGNODES VPS Bot health check

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rgnodes-healthcheck
EOF
cat > /etc/systemd/system/rgnodes-healthcheck.timer <<'EOF'
[Unit]
Description=RGNODES VPS Bot health check timer

[Timer]
OnBootSec=3min
OnUnitActiveSec=3min
AccuracySec=15s
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl enable --now rgnodes-healthcheck.timer >/dev/null 2>&1 || true

# Don't start a crash-loop when the operator has not entered the Discord token yet.
if grep -qE '^DISCORD_TOKEN[[:space:]]*=[[:space:]]*$' "$APP_DIR/.env"; then
  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  warn "DISCORD_TOKEN is empty; bot.service is installed/enabled but intentionally not started."
else
  systemctl restart "$SERVICE_NAME"
  sleep 4
fi

log "🧪 Final host validation..."
lxc info >/dev/null 2>&1 || die 'LXD validation failed.'
lxc storage show default >/dev/null 2>&1 || warn 'default storage pool not available.'
node --version || true
npm --version || true
"$APP_DIR/.venv/bin/python" --version
python3 -m py_compile "$APP_DIR/bot.py"
systemctl --no-pager --full status "$SERVICE_NAME" || true

if grep -qE '^DISCORD_TOKEN[[:space:]]*=[[:space:]]*$' "$APP_DIR/.env"; then
  warn "DISCORD_TOKEN is empty: edit $APP_DIR/.env before expecting Discord connection."
fi
if grep -q '^YOUR_SERVER_IP=127.0.0.1$' "$APP_DIR/.env" 2>/dev/null; then
  warn 'YOUR_SERVER_IP is 127.0.0.1; public SSH forwarding will not work until this is changed.'
fi

log "✅ RGNODES™ deep setup/repair completed."
log "Service: systemctl status $SERVICE_NAME"
log "Logs:    journalctl -u $SERVICE_NAME -f"
log "PM2:     pm2 list"
log "App:     $APP_DIR"
