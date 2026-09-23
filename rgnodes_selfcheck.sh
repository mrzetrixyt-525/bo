#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
APP_DIR="${RGNODES_APP_DIR:-/root/rgnodes-vps-bot}"
fail=0
ok(){ printf '✅ %s\n' "$*"; }
warn(){ printf '⚠️  %s\n' "$*"; }
check_cmd(){ if command -v "$1" >/dev/null 2>&1; then ok "$1"; else warn "$1 missing"; fail=1; fi; }

printf '%s\n' '=== RGNODES™ VPS Manager Self-Check ==='
check_cmd python3
check_cmd lxc
check_cmd lxd
check_cmd systemctl
check_cmd node
check_cmd npm
check_cmd pm2

if [[ -x "$APP_DIR/.venv/bin/python" ]]; then
  ok "Python venv: $APP_DIR/.venv"
  "$APP_DIR/.venv/bin/python" -m py_compile "$APP_DIR/bot.py" "$APP_DIR/node-agent.py" && ok 'Python syntax' || { warn 'Python syntax failed'; fail=1; }
else
  warn "Python venv missing: $APP_DIR/.venv"
  fail=1
fi

if command -v lxc >/dev/null 2>&1; then
  lxc info >/dev/null 2>&1 && ok 'LXD daemon responding' || { warn 'LXD daemon not responding'; fail=1; }
  lxc storage show default >/dev/null 2>&1 && ok 'default storage pool' || warn 'default storage pool unavailable'
  lxc profile show default >/dev/null 2>&1 && ok 'default profile' || warn 'default LXD profile unavailable'
fi

if [[ -f "$APP_DIR/.env" ]]; then
  ok '.env exists'
  if grep -qE '^DISCORD_TOKEN[[:space:]]*=[[:space:]]*[^[:space:]]' "$APP_DIR/.env"; then
    ok 'Discord token configured'
  else
    warn 'Discord token is empty'
  fi
else
  warn '.env missing'
  fail=1
fi

if [[ -f "$APP_DIR/vps.db" ]] && command -v sqlite3 >/dev/null 2>&1; then
  integrity="$(sqlite3 "$APP_DIR/vps.db" 'PRAGMA integrity_check;' 2>/dev/null || true)"
  [[ "$integrity" == 'ok' ]] && ok 'SQLite integrity' || { warn "SQLite integrity: ${integrity:-failed}"; fail=1; }
fi

if command -v systemd-analyze >/dev/null 2>&1 && [[ -f /etc/systemd/system/bot.service ]]; then
  systemd-analyze verify /etc/systemd/system/bot.service >/dev/null 2>&1 && ok 'bot.service syntax' || { warn 'bot.service verification failed'; fail=1; }
fi

if [[ -x "$APP_DIR/node-agent.py" ]]; then ok 'node-agent.py installed'; fi
printf '\nResult: %s\n' "$([[ $fail -eq 0 ]] && echo PASS || echo 'CHECK REQUIRED')"
exit "$fail"
