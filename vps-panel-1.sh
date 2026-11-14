#!/usr/bin/env bash
# =====================================================
#  TURBO Panel - VPS and Telegram bot hosting
#  Supports: Ubuntu / Debian
#
#  Run with:
#    bash <(curl -fsSL https://YOUR-DOMAIN/vps-panel.sh)
#  or:
#    curl -fsSL https://YOUR-DOMAIN/vps-panel.sh -o vps-panel.sh && sudo bash vps-panel.sh
# =====================================================

set -u

# ---------- Colors ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ---------- Root check ----------
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}Please run as root: sudo bash $0${NC}"
  exit 1
fi

# ---------- OS check ----------
if ! command -v apt-get >/dev/null 2>&1; then
  echo -e "${RED}Only Ubuntu/Debian is supported.${NC}"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

pause() { echo; read -rp "Press Enter to continue... " _; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*"; }

# ---------- Header ----------
header() {
  clear
  echo -e "${CYAN}${BOLD}"
  echo "╔══════════════════════════════════════════╗"
  echo "║              TURBO PANEL  v2.0            ║"
  echo "╚══════════════════════════════════════════╝"
  echo -e "${NC}"
  local ip
  ip=$(curl -4 -fsS --max-time 3 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
  echo -e " Host : ${BOLD}$(hostname)${NC}   IP : ${BOLD}${ip}${NC}"
  echo -e " OS   : $(. /etc/os-release && echo "$PRETTY_NAME")"
  echo -e " Up   : $(uptime -p)"
  echo
}

# ---------- 1. System info ----------
sys_info() {
  header
  echo -e "${BOLD}== System Info ==${NC}"
  echo "CPU    : $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs) ($(nproc) cores)"
  echo "Load   : $(cut -d' ' -f1-3 /proc/loadavg)"
  echo
  free -h
  echo
  df -h / | tail -n +1
  pause
}

# ---------- 2. Update ----------
sys_update() {
  header
  echo -e "${BOLD}== System Update ==${NC}"
  apt-get update -y && apt-get upgrade -y && apt-get autoremove -y
  ok "Update complete"
  [[ -f /var/run/reboot-required ]] && warn "Reboot required."
  pause
}

# ---------- 3. Basic tools ----------
install_tools() {
  header
  echo -e "${BOLD}== Basic Tools Install ==${NC}"
  apt-get install -y curl wget git nano htop unzip zip ufw fail2ban net-tools
  ok "Tools installed"
  pause
}

# ---------- 4. Firewall ----------
firewall_menu() {
  while true; do
    header
    echo -e "${BOLD}== Firewall (UFW) ==${NC}"
    echo " 1) Enable firewall (allows SSH first)"
    echo " 2) Open a port"
    echo " 3) Close a port (delete rule)"
    echo " 4) Show status"
    echo " 5) Disable firewall"
    echo " 0) Back"
    read -rp "Choose: " c
    case $c in
      1)
        command -v ufw >/dev/null || apt-get install -y ufw
        local sshp
        sshp=$(grep -E '^\s*Port ' /etc/ssh/sshd_config | awk '{print $2}' | head -n1)
        sshp=${sshp:-22}
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow "${sshp}/tcp"
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw --force enable
        ok "UFW enabled (SSH:${sshp}, 80, 443 allowed)"
        pause ;;
      2)
        read -rp "Port number: " p
        read -rp "Protocol (tcp/udp) [tcp]: " pr; pr=${pr:-tcp}
        if [[ $p =~ ^[0-9]+$ ]] && (( p>=1 && p<=65535 )); then
          ufw allow "${p}/${pr}" && ok "Port $p/$pr opened"
        else err "Invalid port"; fi
        pause ;;
      3)
        read -rp "Port number: " p
        read -rp "Protocol (tcp/udp) [tcp]: " pr; pr=${pr:-tcp}
        ufw delete allow "${p}/${pr}" && ok "Rule deleted"
        pause ;;
      4) ufw status verbose; pause ;;
      5) ufw disable && warn "Firewall disabled"; pause ;;
      0) return ;;
      *) err "Invalid choice" ; sleep 1 ;;
    esac
  done
}

# ---------- 5. SSH security ----------
ssh_menu() {
  while true; do
    header
    echo -e "${BOLD}== SSH Security ==${NC}"
    echo " 1) Change SSH port"
    echo " 2) Disable root password login (only if you have an SSH key!)"
    echo " 3) Create a new sudo user"
    echo " 4) Enable Fail2ban"
    echo " 0) Back"
    read -rp "Choose: " c
    case $c in
      1)
        read -rp "New port (1024-65535): " np
        if [[ $np =~ ^[0-9]+$ ]] && (( np>=1024 && np<=65535 )); then
          cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
          sed -i -E "s/^#?\s*Port .*/Port ${np}/" /etc/ssh/sshd_config
          command -v ufw >/dev/null && ufw allow "${np}/tcp"
          if sshd -t; then
            systemctl restart ssh 2>/dev/null || systemctl restart sshd
            ok "SSH port => ${np} (test a new login on this port before closing this session!)"
          else
            cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
            err "Config invalid, previous config restored"
          fi
        else err "Invalid port"; fi
        pause ;;
      2)
        warn "Do NOT do this unless an SSH key is installed, or you will be locked out."
        read -rp "Continue? (yes/no): " a
        if [[ $a == yes ]]; then
          cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
          sed -i -E "s/^#?\s*PermitRootLogin .*/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config
          sed -i -E "s/^#?\s*PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
          if sshd -t; then
            systemctl restart ssh 2>/dev/null || systemctl restart sshd
            ok "Password login disabled"
          else
            cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
            err "Config invalid, previous config restored"
          fi
        fi
        pause ;;
      3)
        read -rp "Username: " u
        if [[ $u =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
          adduser --gecos "" "$u" && usermod -aG sudo "$u" && ok "User '$u' created (with sudo)"
        else err "Invalid username"; fi
        pause ;;
      4)
        apt-get install -y fail2ban
        systemctl enable --now fail2ban
        ok "Fail2ban enabled"
        pause ;;
      0) return ;;
      *) err "Invalid choice"; sleep 1 ;;
    esac
  done
}

# ---------- 6. Web server ----------
web_menu() {
  while true; do
    header
    echo -e "${BOLD}== Web Server ==${NC}"
    echo " 1) Nginx install"
    echo " 2) Add SSL (Let's Encrypt)"
    echo " 3) Nginx restart"
    echo " 4) Nginx config test"
    echo " 0) Back"
    read -rp "Choose: " c
    case $c in
      1)
        apt-get install -y nginx
        systemctl enable --now nginx
        ok "Nginx installed"
        pause ;;
      2)
        read -rp "Domain (e.g. example.com): " d
        read -rp "Email: " e
        if [[ -n $d && -n $e ]]; then
          apt-get install -y certbot python3-certbot-nginx
          certbot --nginx -d "$d" -m "$e" --agree-tos --no-eff-email --redirect
        else err "Domain and email are required"; fi
        pause ;;
      3) systemctl restart nginx && ok "Restarted"; pause ;;
      4) nginx -t; pause ;;
      0) return ;;
      *) err "Invalid choice"; sleep 1 ;;
    esac
  done
}

# ---------- 7. Docker ----------
install_docker() {
  header
  echo -e "${BOLD}== Docker Install ==${NC}"
  if command -v docker >/dev/null; then
    ok "Docker already installed: $(docker --version)"
  else
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    ok "Docker installed"
  fi
  pause
}

# ---------- 8. Swap ----------
swap_menu() {
  header
  echo -e "${BOLD}== Swap ==${NC}"
  swapon --show
  echo
  if swapon --show | grep -q '/swapfile'; then
    warn "Swapfile already exists"
  else
    read -rp "Swap size in GB (e.g. 2): " s
    if [[ $s =~ ^[0-9]+$ ]] && (( s>0 )); then
      fallocate -l "${s}G" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$((s*1024))
      chmod 600 /swapfile
      mkswap /swapfile && swapon /swapfile
      grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
      ok "Swap ${s}GB created"
    else err "Invalid value"; fi
  fi
  pause
}

# ---------- 9. Backup ----------
backup_menu() {
  header
  echo -e "${BOLD}== Backup ==${NC}"
  read -rp "Folder to back up (e.g. /var/www): " src
  [[ -d $src ]] || { err "Folder not found"; pause; return; }
  mkdir -p /root/backups
  out="/root/backups/$(basename "$src")-$(date +%F-%H%M).tar.gz"
  tar -czf "$out" "$src" && ok "Backup done: $out ($(du -h "$out" | cut -f1))"
  pause
}

# ---------- 10. Services / Monitor ----------
monitor_menu() {
  header
  echo -e "${BOLD}== Monitor ==${NC}"
  echo "-- Listening ports --"
  command -v ss >/dev/null || { apt-get update -y >/dev/null 2>&1; apt-get install -y iproute2 >/dev/null 2>&1; }
  ss -tulpn 2>/dev/null | head -n 25 || echo "(ss not available)"
  echo
  echo "-- Top 5 CPU --"
  ps aux --sort=-%cpu | head -n 6
  echo
  echo "-- Top 5 RAM --"
  ps aux --sort=-%mem | head -n 6
  pause
}

# ---------- 11. Speedtest / network ----------
net_menu() {
  header
  echo -e "${BOLD}== Network ==${NC}"
  echo "Public IP : $(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || echo N/A)"
  echo "Ping 1.1.1.1:"
  ping -c 3 1.1.1.1
  pause
}

# ---------- 12. Reboot ----------
do_reboot() {
  read -rp "Reboot now? (yes/no): " a
  [[ $a == yes ]] && reboot
}

# ---------- 13. Cloudflare Tunnel ----------
CF_DIR=/etc/cloudflared-panel
CF_TOKEN_FILE=$CF_DIR/token
CF_LOG=/var/log/cloudflared-panel.log

# Run a command fully detached from this terminal: new session (setsid), ignores
# hangup (nohup), no tty on stdin, and re-parented to init via the subshell.
# It keeps running after you close the terminal. Env vars set before the call are inherited.
detach_run() {
  local log=$1; shift
  if command -v setsid >/dev/null 2>&1; then
    ( setsid nohup "$@" >> "$log" 2>&1 < /dev/null & )
  else
    ( nohup "$@" >> "$log" 2>&1 < /dev/null & )
  fi
}

# systemd is missing in most containers (Railway, Docker, etc.)
have_systemd() { [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; }
cf_installed() { command -v cloudflared >/dev/null 2>&1; }
cf_running() { pgrep -x cloudflared >/dev/null 2>&1; }

cf_state() {
  if have_systemd; then
    systemctl is-active cloudflared 2>/dev/null || true
  elif cf_running; then
    echo active
  else
    echo inactive
  fi
}

cf_install() {
  if cf_installed; then
    ok "cloudflared already installed: $(cloudflared --version 2>&1 | head -n1)"
    return 0
  fi
  echo "Installing cloudflared..."
  mkdir -p --mode=0755 /usr/share/keyrings
  if ! curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
      -o /usr/share/keyrings/cloudflare-main.gpg; then
    err "Could not download Cloudflare key (check internet)"; return 1
  fi
  echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
    > /etc/apt/sources.list.d/cloudflared.list
  apt-get update -y && apt-get install -y cloudflared
  if cf_installed; then ok "cloudflared installed"; else err "Install failed"; return 1; fi
}

# Run cloudflared as a background process (no systemd). Token is passed via
# environment variable so it does not show up in the process list.
cf_start_bg() {
  if [[ ! -s $CF_TOKEN_FILE ]]; then err "No saved token. Use option 1 first."; return 1; fi
  command -v pgrep >/dev/null || { apt-get update -y >/dev/null 2>&1; apt-get install -y procps; }
  pkill -x cloudflared 2>/dev/null; sleep 1
  : > "$CF_LOG"
  TUNNEL_TOKEN=$(cat "$CF_TOKEN_FILE") detach_run "$CF_LOG" cloudflared tunnel --no-autoupdate run
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    if cf_running && grep -q "Registered tunnel connection" "$CF_LOG" 2>/dev/null; then return 0; fi
  done
  return 1
}

cf_connect() {
  cf_install || return 1
  echo
  echo -e "${BOLD}Cloudflare Zero Trust > Networks > Tunnels${NC} -> copy your Tunnel token and paste it below."
  echo "(Token starts with eyJ... You can also paste the whole install command)"
  echo "Pasted text is hidden on screen."
  read -rsp "Token: " raw; echo

  # If the whole command was pasted, extract only the token
  local token
  token=$(echo "$raw" | tr -d '[:space:]' | sed -E 's/.*(eyJ[A-Za-z0-9_=-]+)$/\1/')

  if [[ ! $token =~ ^eyJ[A-Za-z0-9_=-]{40,}$ ]]; then
    err "Invalid token format"
    return 1
  fi

  if have_systemd; then
    # If a service already exists, remove it first
    if systemctl list-unit-files 2>/dev/null | grep -q '^cloudflared.service'; then
      warn "Tunnel service already exists, replacing it..."
      cloudflared service uninstall >/dev/null 2>&1
    fi

    if cloudflared service install "$token"; then
      systemctl enable --now cloudflared >/dev/null 2>&1
      sleep 3
      if systemctl is-active --quiet cloudflared; then
        ok "Tunnel connected"
        echo "Set the Hostname/Service (e.g. http://localhost:80) in the Cloudflare Dashboard."
      else
        err "Service is not running. Check logs (option 4)"
      fi
    else
      err "Tunnel service install failed"
    fi
  else
    warn "systemd not available (container). Running cloudflared as a background process."
    # Remove a leftover SysV service from an earlier failed install
    if [[ -e /etc/init.d/cloudflared ]]; then
      cloudflared service uninstall >/dev/null 2>&1
      rm -f /etc/init.d/cloudflared
    fi
    mkdir -p "$CF_DIR"; chmod 700 "$CF_DIR"
    ( umask 077; printf '%s' "$token" > "$CF_TOKEN_FILE" )
    echo "Connecting..."
    if cf_start_bg; then
      ok "Tunnel connected (background process)"
      echo "It keeps running after you close this terminal."
      echo "Set the Hostname/Service in the Cloudflare Dashboard (web panel: menu 14 shows the port)."
      warn "In a container the tunnel stops when the container restarts. Re-run option 1 or 3 then."
    else
      err "Tunnel did not connect. Last log lines:"
      tail -n 12 "$CF_LOG" 2>/dev/null
    fi
  fi
  unset raw token
}

cf_status() {
  if have_systemd; then
    systemctl status cloudflared --no-pager 2>&1 | head -n 20
  else
    echo "State : $(cf_state)"
    cf_running && echo "PID   : $(pgrep -x cloudflared | head -n1)"
    echo "--- last log lines ---"
    tail -n 8 "$CF_LOG" 2>/dev/null || echo "(no log yet)"
  fi
}

cf_menu() {
  while true; do
    header
    echo -e "${BOLD}== Cloudflare Tunnel ==${NC}"
    if cf_installed; then
      local st
      st=$(cf_state)
      if [[ $st == active ]]; then st="${GREEN}running${NC}"; else st="${RED}${st:-stopped}${NC}"; fi
      echo -e " Status: $st   ($(cloudflared --version 2>&1 | head -n1 | cut -c1-40))"
      have_systemd || echo -e " Mode  : ${YELLOW}background process (no systemd)${NC}"
    else
      echo -e " Status: ${YELLOW}cloudflared not installed${NC}"
    fi
    echo
    echo " 1) Enter tunnel token and connect"
    echo " 2) Show status"
    echo " 3) Restart"
    echo " 4) Show logs (last 50 lines)"
    echo " 5) Remove tunnel"
    echo " 6) Update cloudflared"
    echo " 0) Back"
    read -rp "Choose: " c
    case $c in
      1) cf_connect; pause ;;
      2) cf_status; pause ;;
      3)
        if have_systemd; then
          systemctl restart cloudflared && ok "Restarted"
        else
          echo "Restarting..."
          if cf_start_bg; then ok "Restarted, tunnel connected"; else err "Did not connect"; tail -n 8 "$CF_LOG" 2>/dev/null; fi
        fi
        pause ;;
      4)
        if have_systemd; then journalctl -u cloudflared -n 50 --no-pager; else tail -n 50 "$CF_LOG" 2>/dev/null || echo "(no log yet)"; fi
        pause ;;
      5)
        read -rp "Remove tunnel? (yes/no): " a
        if [[ $a == yes ]]; then
          pkill -x cloudflared 2>/dev/null
          cloudflared service uninstall >/dev/null 2>&1
          rm -rf "$CF_DIR" "$CF_LOG"
          ok "Tunnel removed"
        fi
        pause ;;
      6)
        apt-get update -y && apt-get install -y --only-upgrade cloudflared
        ok "Updated (restart the tunnel to use the new version)"; pause ;;
      0) return ;;
      *) err "Invalid choice"; sleep 1 ;;
    esac
  done
}

# ---------- 14. Web Panel (via Cloudflare Tunnel) ----------
WP_DIR=/opt/turbo-webpanel
WP_APP=$WP_DIR/app.py
WP_CONF=/etc/vps-webpanel/config.json
WP_SVC=turbo-webpanel

WP_LOG=/var/log/turbo-webpanel.log

wp_installed() { [[ -f $WP_APP ]]; }

# True if something already listens on 127.0.0.1:$1 (works without ss/netstat)
port_in_use() {
  timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/"$1"' _ "$1" 2>/dev/null
}

# First free port starting at 8787 (8080 is often taken by other services)
wp_pick_port() {
  local p
  for p in $(seq 8787 8830); do
    port_in_use "$p" || { echo "$p"; return; }
  done
  echo 8787
}

wp_state() {
  if have_systemd; then systemctl is-active "$WP_SVC" 2>/dev/null || true; return; fi
  local pid; pid=$(cat "$WP_DIR/panel.pid" 2>/dev/null || true)
  if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then echo active; else echo inactive; fi
}

wp_stop() {
  if have_systemd; then systemctl stop "$WP_SVC" 2>/dev/null; return; fi
  local pid; pid=$(cat "$WP_DIR/panel.pid" 2>/dev/null || true)
  if [[ $pid =~ ^[0-9]+$ ]]; then kill "$pid" 2>/dev/null || true; sleep 1; kill -9 "$pid" 2>/dev/null || true
  else pkill -f "python3 $WP_APP" 2>/dev/null || true; fi
  rm -f "$WP_DIR/panel.pid"
}

wp_start() {
  if have_systemd; then systemctl enable --now "$WP_SVC" >/dev/null 2>&1; return; fi
  mkdir -p "$WP_DIR"; : >> "$WP_LOG"
  nohup python3 "$WP_APP" >> "$WP_LOG" 2>&1 < /dev/null &
  echo $! > "$WP_DIR/panel.pid"
}

wp_restart() { wp_stop; wp_start; sleep 1; }

wp_status() {
  if have_systemd; then
    systemctl status "$WP_SVC" --no-pager 2>&1 | head -n 15
  else
    echo "State: $(wp_state)  (background process, no systemd)"
    tail -n 8 "$WP_LOG" 2>/dev/null
  fi
}

wp_logs() {
  if have_systemd; then
    journalctl -u "$WP_SVC" -n 50 --no-pager
  else
    tail -n 50 "$WP_LOG" 2>/dev/null || echo "(no log yet)"
  fi
}

wp_port() {
  python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("port",8080))
except Exception: print(8080)' "$WP_CONF" 2>/dev/null
}

wp_write_app() {
  mkdir -p "$WP_DIR" /etc/turbo-webpanel
  chmod 700 "$WP_DIR" /etc/turbo-webpanel
  cat > "$WP_APP" <<'PYEOF'
#!/usr/bin/env python3
"""TURBO Web Panel: multi-user Telegram bot hosting using native background processes (no Docker/systemd)."""
import os, sys, json, time, hmac, hashlib, secrets, html, shutil, subprocess
import threading, sqlite3, re, io, zipfile, pathlib, tempfile, urllib.parse
from email.parser import BytesParser
from email.policy import default
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from http.cookies import SimpleCookie, CookieError

CONF = os.environ.get("TURBO_CONF", "/etc/vps-webpanel/config.json")
DB = "/etc/turbo-webpanel/panel.db"
BOT_ROOT = "/opt/turbo-bots"
MAX_UPLOAD = 20 * 1024 * 1024
SESSION_TTL = 8 * 3600
SESSIONS, FAILS, LOCK = {}, {}, threading.RLock()
SEC_HEADERS = {"Content-Security-Policy":"default-src 'self'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'; img-src 'self' data:","X-Frame-Options":"DENY","X-Content-Type-Options":"nosniff","Referrer-Policy":"no-referrer","Cache-Control":"no-store"}
CSS = """
:root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;background:#080d17;color:#e8eef8;font:15px/1.5 system-ui, sans-serif}a{color:#7dd3fc;text-decoration:none}main{max-width:1120px;margin:auto;padding:22px}.top{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:22px}.brand{font-size:25px;font-weight:900;letter-spacing:2px;color:#fff}.brand b{color:#38bdf8}.sub{color:#8494aa;font-size:12px;letter-spacing:2px}.nav{display:flex;gap:9px;flex-wrap:wrap}.card{background:linear-gradient(145deg,#111b2c,#0d1421);border:1px solid #24344a;border-radius:16px;padding:18px;margin:12px 0;box-shadow:0 12px 30px #0003}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:12px}.stat{font-size:26px;font-weight:800}.muted{color:#8da0b8}.pill{display:inline-block;padding:3px 9px;border-radius:99px;background:#142c40;color:#7dd3fc;font-size:12px}.good{color:#4ade80}.bad{color:#fb7185}h1{font-size:22px;margin:0 0 8px}h2{font-size:17px;margin:4px 0 12px}label{display:block;color:#aabbd0;font-size:13px;margin:8px 0 4px}input,select{width:100%;padding:12px;border-radius:10px;border:1px solid #30425a;background:#091321;color:#fff;margin:3px 0 9px}button,.btn{display:inline-block;border:0;border-radius:10px;padding:10px 14px;background:#0284c7;color:#fff;font-weight:700;cursor:pointer;font-size:13px}button:hover,.btn:hover{filter:brightness(1.15)}.secondary{background:#243449}.danger{background:#9f2942}.row{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap;padding:12px 0;border-bottom:1px solid #24344a}.row:last-child{border:0}.actions{display:flex;gap:7px;flex-wrap:wrap}form.inline{display:inline}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#050a12;border:1px solid #1e2b3d;border-radius:10px;padding:13px;max-height:420px;overflow:auto;font-size:12px}.notice{padding:11px;border-radius:10px;background:#10283a;color:#a5e3ff;margin:10px 0}.error{background:#3b1721;color:#fecdd3}.empty{text-align:center;padding:28px;color:#91a4bb}.login{max-width:420px;margin:8vh auto}.small{font-size:12px}.bar{height:8px;background:#25354a;border-radius:9px;overflow:hidden}.bar i{display:block;height:100%;background:#0ea5e9}.footer{text-align:center;color:#62738b;font-size:12px;padding:22px}
"""

def esc(v): return html.escape(str(v), quote=True)
def page(title, body):
    return "<!doctype html><html><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><meta name=robots content='noindex,nofollow'><title>%s · TURBO</title><style>%s</style></head><body><main>%s<div class=footer>TURBO WEB PANEL · SECURE BOT HOSTING</div></main></body></html>" % (esc(title), CSS, body)
def connect():
    os.makedirs(os.path.dirname(DB), mode=0o700, exist_ok=True); os.makedirs(BOT_ROOT, mode=0o755, exist_ok=True); os.chmod(BOT_ROOT,0o755)
    c=sqlite3.connect(DB, timeout=15); c.row_factory=sqlite3.Row; c.execute("PRAGMA foreign_keys=ON")
    c.executescript("CREATE TABLE IF NOT EXISTS users(id INTEGER PRIMARY KEY,username TEXT UNIQUE NOT NULL,salt TEXT NOT NULL,pwhash TEXT NOT NULL,role TEXT NOT NULL DEFAULT 'user',created INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS bots(id TEXT PRIMARY KEY,user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,name TEXT NOT NULL,folder TEXT NOT NULL,entry TEXT NOT NULL DEFAULT 'bot.py',created INTEGER NOT NULL);")
    os.chmod(DB,0o600); return c
def hash_pw(p,s): return hashlib.pbkdf2_hmac('sha256',p.encode(),bytes.fromhex(s),250000).hex()
def save_conf(d):
    os.makedirs(os.path.dirname(CONF),mode=0o700,exist_ok=True); t=CONF+'.tmp'
    fd=os.open(t,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
    with os.fdopen(fd,'w') as f: json.dump(d,f)
    os.replace(t,CONF)
def load_conf():
    try:
        with open(CONF) as f:return json.load(f)
    except Exception:return {}
def cli_set_password(user):
    pw=sys.stdin.read().rstrip('\n')
    if len(pw)<10: print('Password must be at least 10 characters');sys.exit(1)
    c=connect(); salt=secrets.token_hex(16)
    exists=c.execute("SELECT id FROM users WHERE role='admin' ORDER BY id LIMIT 1").fetchone()
    if exists:c.execute("UPDATE users SET username=?,salt=?,pwhash=? WHERE id=?",(user,salt,hash_pw(pw,salt),exists['id']))
    else:c.execute("INSERT INTO users(username,salt,pwhash,role,created) VALUES(?,?,?,'admin',?)",(user,salt,hash_pw(pw,salt),int(time.time())))
    c.commit();c.close()
def cli_set_port(port):
    p=int(port)
    if not 1024<=p<=65535:print('Invalid port');sys.exit(1)
    d=load_conf();d['port']=p;save_conf(d)
def bot_os_user(botid):return 'tb'+re.sub('[^a-f0-9]','',botid)[:24]
def run_cmd(args,timeout=90):
    try:
        r=subprocess.run(args,capture_output=True,text=True,timeout=timeout)
        return r.returncode,r.stdout.strip(),r.stderr.strip()
    except subprocess.TimeoutExpired:return 124,'','Command timed out'
    except Exception as e:return 1,'',str(e)
def pid_alive(pid):
    try:os.kill(int(pid),0);return True
    except (ProcessLookupError,ValueError,TypeError):return False
    except PermissionError:return True
def bot_pidfile(botid):return os.path.join(BOT_ROOT,botid,'.bot.pid')
def bot_state(botid):
    pf=bot_pidfile(botid)
    try:
        pid=int(open(pf).read().strip())
        if pid_alive(pid):return 'running'
        os.unlink(pf)
    except Exception:pass
    return 'stopped'
def stop_bot(botid):
    pf=bot_pidfile(botid)
    try:
        pid=int(open(pf).read().strip())
        try:os.killpg(pid,15)
        except Exception:
            try:os.kill(pid,15)
            except Exception:pass
        for _ in range(30):
            if not pid_alive(pid):break
            time.sleep(.2)
        if pid_alive(pid):
            try:os.killpg(pid,9)
            except Exception:
                try:os.kill(pid,9)
                except Exception:pass
    except Exception:pass
    try:os.unlink(pf)
    except Exception:pass
def remove_bot_service(botid):
    stop_bot(botid)
    user=bot_os_user(botid)
    if shutil.which('userdel'):run_cmd(['userdel','--force',user],15)
def ensure_supervisor():
    path='/usr/local/lib/turbo-panel/bot_supervisor.py'
    os.makedirs(os.path.dirname(path),mode=0o755,exist_ok=True)
    code='''#!/usr/bin/env python3
import os,sys,time,signal,subprocess
folder,entry=sys.argv[1],sys.argv[2]
py=os.path.join(folder,'.venv','bin','python')
child=None; stopping=False

def stop(sig,frame):
 global stopping,child
 stopping=True
 if child and child.poll() is None:
  try: child.terminate()
  except Exception: pass
signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
delay=3
while not stopping:
 try:
  child=subprocess.Popen([py,'-u',os.path.join(folder,entry)],cwd=folder,env=dict(os.environ,PYTHONUNBUFFERED='1'))
  while child.poll() is None and not stopping: time.sleep(1)
  rc=child.poll()
 except Exception as e:
  print('Supervisor error:',repr(e),flush=True);rc=1
 if stopping: break
 print('Bot exited with code %s; restarting in %s seconds'%(rc,delay),flush=True)
 time.sleep(delay);delay=min(delay*2,60)
'''
    if not os.path.isfile(path) or open(path,errors='ignore').read()!=code:
        with open(path,'w') as f:f.write(code)
        os.chmod(path,0o755)
    return path
def install_python_venv_support():
    # Ubuntu minimal/Railway images may ship Python without ensurepip.
    # Install the matching distro package automatically from the root panel process.
    if os.geteuid()!=0 or not shutil.which('apt-get'):
        return False,'apt-get/root permission မရှိပါ။ Python venv package ကို Auto Install မလုပ်နိုင်ပါ။'
    version='%s.%s'%(sys.version_info.major,sys.version_info.minor)
    update=run_cmd(['apt-get','update','-y'],600)
    packages=['python%s-venv'%version,'python3-venv']
    errors=[]
    for package in packages:
        rc,out,err=run_cmd(['apt-get','install','-y',package],900)
        if rc==0:
            return True,package+' ကို Auto Install လုပ်ပြီးပါပြီ။'
        errors.append(package+': '+(err or out)[-700:])
    return False,'Python venv package Auto Install မအောင်မြင်ပါ။ '+(' | '.join(errors))[-1800:]

def start_bot(bot):
    folder=bot['folder'];entry=bot['entry'];entry_path=os.path.realpath(os.path.join(folder,entry))
    if not entry_path.startswith(os.path.realpath(folder)+os.sep) or not os.path.isfile(entry_path):return False,'Bot entry file မတွေ့ပါ။'
    if bot_state(bot['id'])=='running':return True,'ဒီ Bot က Run နေပြီးသားပါ။'
    if not shutil.which('useradd') or not shutil.which('runuser'):
        return False,'ဒီ Railway image မှာ useradd/runuser မရှိပါ။ Bot code ကို root နဲ့ မ run စေရန် util-linux/passwd tools လိုအပ်ပါတယ်။'
    runner=bot_os_user(bot['id'])
    rc,out,err=run_cmd(['id',runner],10)
    if rc:
        rc,out,err=run_cmd(['useradd','--system','--no-create-home','--home-dir','/nonexistent','--shell','/usr/sbin/nologin',runner],20)
        if rc:return False,'သီးခြား Bot Linux user မဖန်တီးနိုင်ပါ: '+(err or out)[-1200:]
    # Give this bot its own files and virtual environment, never run uploaded code as root.
    try:
        for root,dirs,files in os.walk(folder):
            shutil.chown(root,user=runner,group=runner)
            for fn in files:shutil.chown(os.path.join(root,fn),user=runner,group=runner)
        os.chmod(folder,0o750)
    except Exception as e:return False,'Bot folder permission မပြင်နိုင်ပါ: '+str(e)
    py=os.path.join(folder,'.venv','bin','python')
    if not os.path.isfile(py):
        venv_path=os.path.join(folder,'.venv')
        rc,out,err=run_cmd(['runuser','-u',runner,'--','python3','-m','venv',venv_path],240)
        if rc:
            first_error=(err or out)
            # ensurepip missing is common on slim Ubuntu images. Install the
            # matching pythonX.Y-venv package, remove the incomplete venv and retry.
            if 'ensurepip' in first_error.lower() or 'venv' in first_error.lower():
                installed,detail=install_python_venv_support()
                if installed:
                    shutil.rmtree(venv_path,ignore_errors=True)
                    rc,out,err=run_cmd(['runuser','-u',runner,'--','python3','-m','venv',venv_path],300)
                    if rc:
                        return False,'Python venv Auto Install လုပ်ပြီးနောက် ပြန်တည်ဆောက်မရပါ: '+(err or out)[-1800:]
                else:
                    return False,'Python venv မရှိလို့ Auto Install ကြိုးစားခဲ့ပေမဲ့ မအောင်မြင်ပါ: '+detail
            else:
                return False,'Python venv တည်ဆောက်မရပါ: '+first_error[-1800:]
        if not os.path.isfile(py):
            return False,'Python venv တည်ဆောက်ပြီးသော်လည်း .venv/bin/python မတွေ့ပါ။'
    req=os.path.join(folder,'requirements.txt')
    if os.path.isfile(req):
        if os.path.getsize(req)>100000:return False,'requirements.txt အရွယ်အစား 100KB ကျော်နေပါတယ်။'
        rc,out,err=run_cmd(['runuser','-u',runner,'--',py,'-m','pip','install','--disable-pip-version-check','-r',req],900)
        if rc:return False,'Package install မအောင်မြင်ပါ:\n'+(err or out)[-2500:]
    supervisor=ensure_supervisor();log=os.path.join(folder,'bot.log');pidfile=bot_pidfile(bot['id'])
    try:
        lf=open(log,'a',buffering=1)
        proc=subprocess.Popen(['runuser','-u',runner,'--',py,supervisor,folder,entry],cwd=folder,stdin=subprocess.DEVNULL,stdout=lf,stderr=subprocess.STDOUT,start_new_session=True,close_fds=True,env=dict(os.environ,PYTHONUNBUFFERED='1'))
        lf.close()
        time.sleep(1)
        if proc.poll() is not None:return False,'Bot supervisor စတင်မရပါ။ Log ကိုစစ်ပါ။'
        fd=os.open(pidfile,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
        with os.fdopen(fd,'w') as f:f.write(str(proc.pid))
        return True,'Bot ကို Railway-compatible background process အဖြစ် Run လိုက်ပါပြီ။ Docker/Systemd မလိုပါ။ requirements.txt ကို သီးခြား venv ထဲ install လုပ်ပြီးပါပြီ။'
    except Exception as e:return False,'Bot start မအောင်မြင်ပါ: '+str(e)
def tail_logs(botid,lines=100):
    log=os.path.join(BOT_ROOT,botid,'bot.log')
    try:
        with open(log,errors='replace') as f:return ''.join(f.readlines()[-lines:])[-16000:]
    except Exception:return 'Log မရှိသေးပါ။'
def cpu_mem():
    mem={}
    try:
        for ln in open('/proc/meminfo'):
            k,v=ln.split(':',1);mem[k]=int(v.split()[0])*1024
        du=shutil.disk_usage('/');total=mem['MemTotal'];used=total-mem.get('MemAvailable',mem.get('MemFree',0))
        return {'cpu':os.cpu_count() or 1,'ram':used,'ramtotal':total,'disk':du.used,'disktotal':du.total,'load':' '.join(open('/proc/loadavg').read().split()[:3])}
    except Exception:return {'cpu':1,'ram':0,'ramtotal':1,'disk':0,'disktotal':1,'load':'-'}
def human(n):
    for u in ('B','KB','MB','GB','TB'):
        if n<1024:return '%.1f %s'%(n,u)
        n/=1024
    return '%.1f PB'%n
def percent(a,b):return min(100,int(a*100/max(1,b)))
def form(act,label,csrf,extra='',cls='secondary'):
    return "<form class='inline' method=post action=/action><input type=hidden name=csrf value='%s'><input type=hidden name=act value='%s'>%s<button class='%s'>%s</button></form>"%(esc(csrf),esc(act),extra,cls,esc(label))
def nav(s):return "<div class=top><div><div class=brand>⚡ TUR<b>BO</b></div><div class=sub>TELEGRAM BOT HOSTING</div></div><div class=nav><span class=pill>%s</span><a class=btn secondary href='/'>Dashboard</a><form method=post action=/logout class=inline><input type=hidden name=csrf value='%s'><button class=secondary>Logout</button></form></div></div>"%(esc(s[1]['username']),esc(s[1]['csrf']))
def user_bots(uid):
    c=connect();rows=c.execute('SELECT * FROM bots WHERE user_id=? ORDER BY created DESC',(uid,)).fetchall();c.close();return rows
def get_bot(botid):
    c=connect();r=c.execute('SELECT * FROM bots WHERE id=?',(botid,)).fetchone();c.close();return r
def is_admin(s):return s[1].get('role')=='admin'
def allowed(bot,s):return is_admin(s) or int(bot['user_id'])==int(s[1]['uid'])
def dashboard(s):
    info=cpu_mem(); uid=s[1]['uid']; admin=is_admin(s)
    c=connect()
    if admin:
        bots=c.execute('SELECT b.*,u.username FROM bots b JOIN users u ON u.id=b.user_id ORDER BY b.created DESC').fetchall(); users=c.execute("SELECT id,username,role,created FROM users ORDER BY created DESC").fetchall()
    else:bots=c.execute('SELECT * FROM bots WHERE user_id=? ORDER BY created DESC',(uid,)).fetchall();users=[]
    c.close(); running=sum(1 for b in bots if bot_state(b['id'])=='running')
    body=nav(s)+"<h1>Dashboard</h1><p class=muted>Run Python bots directly with separate virtual environments and background supervisors. Docker and systemd are not required.</p><div class=grid><div class=card><div class=muted>CPU CORES</div><div class=stat>%s</div><div class=small muted>Load %s</div></div><div class=card><div class=muted>MEMORY</div><div class=stat>%s / %s</div><div class=bar><i style='width:%s%%'></i></div></div><div class=card><div class=muted>DISK</div><div class=stat>%s / %s</div><div class=bar><i style='width:%s%%'></i></div></div><div class=card><div class=muted>BOT STATUS</div><div class=stat>%s / %s</div><span class=pill>RUNNING</span></div></div>"%(info['cpu'],esc(info['load']),human(info['ram']),human(info['ramtotal']),percent(info['ram'],info['ramtotal']),human(info['disk']),human(info['disktotal']),percent(info['disk'],info['disktotal']),running,len(bots))
    body+="<div class=card><h2>＋ Upload New Bot</h2><p class=muted>Upload a Python .py file or a .zip containing bot.py. Optional requirements.txt is installed automatically.</p><form method=post action=/upload enctype=multipart/form-data><input type=hidden name=csrf value='%s'><label>Bot name</label><input name=name required maxlength=48 placeholder='My Telegram Bot'><label>Bot file (.py / .zip)</label><input type=file name=botfile accept='.py,.zip' required><button>Upload Bot</button></form></div>"%esc(s[1]['csrf'])
    body+="<div class=card><h2>Your Bots%s</h2>"%(' · All users' if admin else '')
    if not bots:body+="<div class=empty>No bots uploaded yet. Upload your first bot above.</div>"
    for b in bots:
        st=bot_state(b['id']);color='good' if st=='running' else 'bad'
        body+="<div class=row><div><b>%s</b> <span class=pill>%s</span><div class=small muted>%s · %s</div></div><div class=actions>%s %s %s %s</div></div>"%(esc(b['name']),esc(st.upper()),esc(b['username'] if admin else b['entry']),time.strftime('%Y-%m-%d',time.localtime(b['created'])),form('start:'+b['id'],'Start',s[1]['csrf'],cls=''),form('stop:'+b['id'],'Stop',s[1]['csrf']),form('logs:'+b['id'],'Logs',s[1]['csrf']),form('delete:'+b['id'],'Delete',s[1]['csrf'],cls='danger'))
    body+='</div>'
    if admin:
        body+="<div class=card><h2>＋ Create User Account</h2><form method=post action=/action><input type=hidden name=csrf value='%s'><input type=hidden name=act value=create_user><label>Username (3-32 characters)</label><input name=username pattern='[A-Za-z0-9_.-]{3,32}' required><label>Password (minimum 10 characters)</label><input type=password name=password minlength=10 required><button>Create User</button></form></div><div class=card><h2>User Accounts</h2>"%esc(s[1]['csrf'])
        for u in users:
            if u['role']=='admin':continue
            body+="<div class=row><div><b>%s</b><div class=small muted>Joined %s</div></div>%s</div>"%(esc(u['username']),time.strftime('%Y-%m-%d',time.localtime(u['created'])),form('delete_user:'+str(u['id']),'Delete user',s[1]['csrf'],cls='danger'))
        body+='</div>'
    body+="<div class=notice>Each bot runs as its own restricted Linux account with a separate Python virtual environment and an auto-restart supervisor. No Docker or systemd required. Only upload code you trust.</div>"
    return page('Dashboard',body)

class H(BaseHTTPRequestHandler):
    server_version='TurboPanel';sys_version=''
    def log_message(self,fmt,*args):sys.stderr.write('%s %s\n'%(self.client_address[0],fmt%args))
    def out(self,code,body,headers=None):
        data=body.encode();self.send_response(code);self.send_header('Content-Type','text/html; charset=utf-8');self.send_header('Content-Length',str(len(data)))
        for k,v in SEC_HEADERS.items():self.send_header(k,v)
        for k,v in (headers or []):self.send_header(k,v)
        self.end_headers();self.wfile.write(data)
    def redirect(self,path,headers=None):
        self.send_response(303);self.send_header('Location',path);self.send_header('Content-Length','0')
        for k,v in SEC_HEADERS.items():self.send_header(k,v)
        for k,v in (headers or []):self.send_header(k,v)
        self.end_headers()
    def ip(self):return self.headers.get('CF-Connecting-IP') or self.client_address[0]
    def sess(self):
        try:m=SimpleCookie(self.headers.get('Cookie','')).get('sid')
        except CookieError:return None
        if not m:return None
        with LOCK:
            s=SESSIONS.get(m.value)
            if s and s['exp']>time.time():return m.value,s
            SESSIONS.pop(m.value,None)
        return None
    def login_page(self,error=''):
        body="<div class=login><div class=card><div class=brand>⚡ TUR<b>BO</b></div><div class=sub>BOT HOSTING CONTROL CENTER</div><h1 style='margin-top:24px'>Welcome back</h1><p class=muted>Sign in to manage your Telegram bots.</p>%s<form method=post action=/login><label>Username</label><input name=u required autocomplete=username><label>Password</label><input type=password name=p required autocomplete=current-password><button style='width:100%%'>Sign In →</button></form></div></div>"%("<div class='notice error'>%s</div>"%esc(error) if error else '')
        return page('Sign in',body)
    def parse_form(self):
        n=int(self.headers.get('Content-Length','0'))
        if n>MAX_UPLOAD+1024*1024:raise ValueError('Request too large')
        raw=self.rfile.read(n);ct=self.headers.get('Content-Type','')
        if 'multipart/form-data' in ct:
            msg=BytesParser(policy=default).parsebytes(('Content-Type: '+ct+'\r\nMIME-Version: 1.0\r\n\r\n').encode()+raw); fields={}; files={}
            for part in msg.iter_parts():
                key=part.get_param('name',header='content-disposition')
                if not key:continue
                data=part.get_payload(decode=True) or b'';fn=part.get_filename()
                if fn:files[key]=(fn,data)
                else:fields[key]=data.decode('utf-8','replace')
            return fields,files
        vals=urllib.parse.parse_qs(raw.decode('utf-8','replace'),keep_blank_values=True)
        return {k:v[-1] for k,v in vals.items()},{}
    def do_GET(self):
        s=self.sess();path=urllib.parse.urlparse(self.path).path
        if path=='/health':return self.out(200,page('OK','<h1>TURBO OK</h1>'))
        if path=='/login' and not s:return self.out(200,self.login_page())
        if not s:return self.redirect('/login')
        if path=='/':return self.out(200,dashboard(s))
        if path.startswith('/logs/'):
            bid=path.split('/')[-1];b=get_bot(bid)
            if not b or not allowed(b,s):return self.out(404,page('Not found','<h1>Not found</h1>'))
            return self.out(200,page('Bot logs',nav(s)+"<h1>Logs · %s</h1><pre>%s</pre><a class=btn href='/'>Back</a>"%(esc(b['name']),esc(tail_logs(bid,180)))))
        return self.out(404,page('Not found','<h1>404</h1>'))
    def do_POST(self):
        path=urllib.parse.urlparse(self.path).path
        try:d,files=self.parse_form()
        except Exception as e:return self.out(400,page('Bad request','<h1>%s</h1>'%esc(e)))
        if path=='/login':return self.do_login(d)
        s=self.sess()
        if not s:return self.redirect('/login')
        if not hmac.compare_digest(d.get('csrf',''),s[1]['csrf']):return self.out(403,page('Forbidden','<h1>Invalid CSRF token</h1>'))
        if path=='/logout':
            with LOCK:SESSIONS.pop(s[0],None)
            return self.redirect('/login',[('Set-Cookie','sid=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict')])
        if path=='/upload':return self.do_upload(d,files,s)
        if path=='/action':return self.do_action(d,s)
        return self.out(404,page('Not found','<h1>404</h1>'))
    def do_login(self,d):
        ip=self.ip();now=time.time()
        with LOCK:
            f=FAILS.get(ip,[0,0])
            if f[1]>now:return self.out(429,self.login_page('Too many attempts. Wait five minutes.'))
        c=connect();u=c.execute('SELECT * FROM users WHERE username=?',(d.get('u',''),)).fetchone();c.close()
        valid=bool(u and hmac.compare_digest(hash_pw(d.get('p',''),u['salt']),u['pwhash']))
        if not valid:
            with LOCK:
                f=FAILS.get(ip,[0,0]);f[0]+=1
                if f[0]>=5:f=[0,now+300]
                FAILS[ip]=f
            time.sleep(.6);return self.out(401,self.login_page('Invalid username or password'))
        tok=secrets.token_urlsafe(32);csrf=secrets.token_urlsafe(24)
        with LOCK:
            FAILS.pop(ip,None);SESSIONS[tok]={'exp':now+SESSION_TTL,'csrf':csrf,'uid':u['id'],'username':u['username'],'role':u['role']}
        secure='; Secure' if self.headers.get('X-Forwarded-Proto')=='https' or self.headers.get('Cf-Visitor') else ''
        return self.redirect('/',[('Set-Cookie','sid=%s; Path=/; HttpOnly; SameSite=Strict; Max-Age=%d%s'%(tok,SESSION_TTL,secure))])
    def do_upload(self,d,files,s):
        item=files.get('botfile')
        if not item:return self.out(400,page('Upload error',nav(s)+'<h1>Choose a bot file.</h1>'))
        filename,data=item
        if len(data)>MAX_UPLOAD:return self.out(413,page('Too large',nav(s)+'<h1>Upload limit is 20 MB.</h1>'))
        name=(d.get('name') or 'Telegram Bot').strip()[:48]
        if not name:return self.out(400,page('Invalid name',nav(s)+'<h1>Bot name is required.</h1>'))
        bid=secrets.token_hex(12);folder=os.path.join(BOT_ROOT,bid);os.makedirs(folder,mode=0o750)
        try:
            low=filename.lower()
            if low.endswith('.py'):
                if not data.strip():raise ValueError('Empty Python file')
                open(os.path.join(folder,'bot.py'),'wb').write(data)
            elif low.endswith('.zip'):
                with zipfile.ZipFile(io.BytesIO(data)) as z:
                    total=0
                    for info in z.infolist():
                        p=pathlib.PurePosixPath(info.filename)
                        if p.is_absolute() or '..' in p.parts or info.is_dir():continue
                        if info.file_size>MAX_UPLOAD:raise ValueError('ZIP contains an oversized file')
                        total+=info.file_size
                        if total>MAX_UPLOAD:raise ValueError('Uncompressed ZIP exceeds 20 MB')
                        dest=os.path.realpath(os.path.join(folder,*p.parts))
                        if not dest.startswith(os.path.realpath(folder)+os.sep):raise ValueError('Unsafe ZIP path')
                        os.makedirs(os.path.dirname(dest),exist_ok=True)
                        with z.open(info) as src,open(dest,'wb') as dst:shutil.copyfileobj(src,dst)
                if not os.path.isfile(os.path.join(folder,'bot.py')):raise ValueError('ZIP ထဲမှာ root folder အောက် bot.py ပါရမယ်။')
            else:raise ValueError('Only .py and .zip files are accepted')
            req=os.path.join(folder,'requirements.txt')
            if os.path.exists(req) and os.path.getsize(req)>100000:raise ValueError('requirements.txt too large')
            os.chmod(folder,0o755)
            for root,dirs,fs in os.walk(folder):
                for f in fs:os.chmod(os.path.join(root,f),0o644)
            try:os.chown(folder,10001,10001)
            except Exception:pass
            c=connect();c.execute('INSERT INTO bots(id,user_id,name,folder,entry,created) VALUES(?,?,?,?,?,?)',(bid,s[1]['uid'],name,folder,'bot.py',int(time.time())));c.commit();c.close()
        except Exception as e:
            shutil.rmtree(folder,ignore_errors=True);return self.out(400,page('Upload failed',nav(s)+"<div class='notice error'>%s</div><a class=btn href='/'>Back</a>"%esc(e)))
        return self.redirect('/')
    def do_action(self,d,s):
        act=d.get('act','')
        if act=='create_user' and is_admin(s):
            u=d.get('username','').strip();pw=d.get('password','')
            if not re.fullmatch(r'[A-Za-z0-9_.-]{3,32}',u) or len(pw)<10:return self.out(400,page('Invalid user',nav(s)+"<div class='notice error'>Username or password invalid.</div><a href='/'>Back</a>"))
            salt=secrets.token_hex(16);c=connect()
            try:c.execute("INSERT INTO users(username,salt,pwhash,role,created) VALUES(?,?,?,'user',?)",(u,salt,hash_pw(pw,salt),int(time.time())));c.commit()
            except sqlite3.IntegrityError:return self.out(409,page('Exists',nav(s)+"<div class='notice error'>Username already exists.</div><a href='/'>Back</a>"))
            finally:c.close()
            return self.redirect('/')
        if act.startswith('delete_user:') and is_admin(s):
            try:uid=int(act.split(':',1)[1])
            except: return self.out(400,page('Invalid','<h1>Invalid user ID</h1>'))
            if uid==int(s[1]['uid']):return self.out(400,page('Denied',nav(s)+'<h1>Cannot delete your own admin account.</h1>'))
            c=connect();rows=c.execute('SELECT * FROM bots WHERE user_id=?',(uid,)).fetchall()
            for b in rows:remove_bot_service(b['id']);shutil.rmtree(b['folder'],ignore_errors=True)
            c.execute("DELETE FROM users WHERE id=? AND role!='admin'",(uid,));c.commit();c.close();return self.redirect('/')
        if act.startswith(('start:','stop:','logs:','delete:')):
            op,bid=act.split(':',1);b=get_bot(bid)
            if not b or not allowed(b,s):return self.out(404,page('Not found','<h1>Bot not found</h1>'))
            if op=='start':ok,msg=start_bot(b);return self.out(200,page('Bot start',nav(s)+"<div class=notice>%s</div><a class=btn href='/'>Back</a>"%esc(msg)))
            if op=='stop':stop_bot(bid);return self.redirect('/')
            if op=='logs':return self.redirect('/logs/'+bid)
            if op=='delete':
                remove_bot_service(bid);shutil.rmtree(b['folder'],ignore_errors=True);c=connect();c.execute('DELETE FROM bots WHERE id=?',(bid,));c.commit();c.close();return self.redirect('/')
        if act.startswith('restart:') and is_admin(s):
            service=act.split(':',1)[1]
            if service in ('nginx','fail2ban','ssh','cloudflared'):
                try:r=subprocess.run(['systemctl','restart',service],capture_output=True,text=True,timeout=60);out=r.stdout+r.stderr
                except Exception as e:out=str(e)
                return self.out(200,page('Service',nav(s)+'<pre>'+esc(out or 'Restart command sent')+'</pre><a href="/">Back</a>'))
        return self.out(403,page('Forbidden',nav(s)+'<h1>Action not allowed.</h1>'))

def main():
    if len(sys.argv)>=3 and sys.argv[1]=='--set-password':return cli_set_password(sys.argv[2])
    if len(sys.argv)>=3 and sys.argv[1]=='--set-port':return cli_set_port(sys.argv[2])
    conf=load_conf();c=connect();admin=c.execute("SELECT id FROM users WHERE role='admin' LIMIT 1").fetchone();c.close()
    if not admin:print('No admin configured. Run installer and set admin password.');sys.exit(1)
    port=int(conf.get('port',8787));srv=ThreadingHTTPServer(('127.0.0.1',port),H);srv.daemon_threads=True
    print('TURBO Web Panel listening on 127.0.0.1:%s'%port,flush=True)
    try:srv.serve_forever()
    except KeyboardInterrupt:pass
if __name__=='__main__':main()
PYEOF
  chmod 700 "$WP_APP"
}
wp_set_password() {
  local u pw1 pw2
  read -rp "Admin username [admin]: " u; u=${u:-admin}
  if [[ ! $u =~ ^[A-Za-z0-9_.-]{3,32}$ ]]; then err "Invalid username (3-32 chars: letters, digits, _ . -)"; return 1; fi
  read -rsp "Password (min 10 characters): " pw1; echo
  read -rsp "Repeat password: " pw2; echo
  if [[ $pw1 != "$pw2" ]]; then err "Passwords do not match"; return 1; fi
  if printf '%s' "$pw1" | python3 "$WP_APP" --set-password "$u"; then
    chmod 600 "$WP_CONF"
    ok "Password set for admin '$u'"
  else
    err "Could not set password"; return 1
  fi
}

wp_install() {
  header
  echo -e "${BOLD}== TURBO Web Panel Install ==${NC}"
  command -v python3 >/dev/null || apt-get install -y python3
  command -v curl >/dev/null || apt-get install -y curl

  command -v pgrep >/dev/null || { apt-get update -y >/dev/null 2>&1; apt-get install -y procps; }
  if ! python3 -m venv --help >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y python3-venv python3-pip || { err "Python venv installation failed"; pause; return 1; }
  fi
  wp_stop
  wp_write_app

  local port def
  def=$(wp_pick_port)
  read -rp "Panel port (listens on localhost only) [$def]: " port; port=${port:-$def}
  if [[ ! $port =~ ^[0-9]+$ ]] || (( port<1024 || port>65535 )); then err "Invalid port"; pause; return; fi
  if port_in_use "$port"; then err "Port $port is already used by another program. Choose a different port."; pause; return; fi
  python3 "$WP_APP" --set-port "$port" || { pause; return; }

  wp_set_password || { pause; return; }

  if have_systemd; then
  cat > /etc/systemd/system/${WP_SVC}.service <<EOF
[Unit]
Description=TURBO Multi-User Web Panel
After=network.target

[Service]
ExecStart=$(command -v python3) $WP_APP
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  fi
  wp_start
  sleep 2

  local html
  html=$(curl -s --max-time 5 "http://127.0.0.1:${port}/login")
  if [[ $html == *"TURBO"* ]]; then
    ok "Web panel is running (http://127.0.0.1:${port})"
    have_systemd || echo "Panel is running as a background process. Railway restarts/redeploys require the service start command to launch it again."
  else
    err "Panel failed to start. Last log lines:"
    wp_logs 2>&1 | tail -n 8
    pause; return
  fi
  wp_tunnel_help "$port"
  pause
}

wp_tunnel_help() {
  local port=${1:-$(wp_port)}
  echo
  echo -e "${BOLD}Connect TURBO via Cloudflare Tunnel:${NC}"
  echo " 1) Cloudflare Zero Trust > Networks > Tunnels > (your tunnel) > Edit"
  echo " 2) Published application / Public hostname > Add"
  echo "      Subdomain : panel   (example)"
  echo "      Domain    : choose your domain"
  echo "      Type      : HTTP"
  echo "      URL       : localhost:${port}"
  echo " 3) Save, then open https://panel.yourdomain.com"
  echo
  echo -e "${YELLOW}Security tip:${NC} In Zero Trust > Access > Applications,"
  echo "add an Access policy (email OTP / Google login) for this hostname."
  echo "Cloudflare will then verify visitors before they reach the panel login."
  if [[ $(cf_state) != active ]]; then
    echo
    warn "cloudflared is not running. Connect your Tunnel token first via menu 13."
  fi
}

wp_menu() {
  while true; do
    header
    echo -e "${BOLD}== TURBO Web Panel ==${NC}"
    if wp_installed; then
      local st
      st=$(wp_state)
      [[ $st == active ]] && st="${GREEN}running${NC}" || st="${RED}${st:-stopped}${NC}"
      echo -e " Status: $st   Local: http://127.0.0.1:$(wp_port)"
    else
      echo -e " Status: ${YELLOW}not installed${NC}"
    fi
    echo
    echo " 1) Install / Reinstall (Multi-User + Native Python Bot Hosting (no Docker/systemd))"
    echo " 2) Show status"
    echo " 3) Change admin password"
    echo " 4) Restart"
    echo " 5) Show logs (includes login attempts)"
    echo " 6) Cloudflare Tunnel setup help (hostname/port)"
    echo " 7) Update panel code (keeps config)"
    echo " 8) Uninstall"
    echo " 0) Back"
    read -rp "Choose: " c
    case $c in
      1) wp_install ;;
      2) wp_status; pause ;;
      3) if wp_installed; then wp_set_password && wp_restart && ok "All sessions have been logged out"; else err "Install the panel first"; fi; pause ;;
      4) wp_restart; ok "Restarted"; pause ;;
      5) wp_logs; pause ;;
      6) wp_tunnel_help; pause ;;
      7) if wp_installed; then wp_write_app && wp_restart && ok "Updated"; else err "Install the panel first"; fi; pause ;;
      8)
        read -rp "Remove web panel? (yes/no): " a
        if [[ $a == yes ]]; then
          wp_stop
          if [[ -d /opt/turbo-bots ]] && have_systemd; then
            for d in /opt/turbo-bots/*; do [[ -d $d ]] || continue; bid=$(basename "$d"); unit="turbo-bot-${bid}.service"; systemctl disable --now "$unit" 2>/dev/null || true; rm -f "/etc/systemd/system/$unit"; done
            systemctl daemon-reload 2>/dev/null || true
          fi
          if have_systemd; then
            systemctl disable "$WP_SVC" 2>/dev/null
            rm -f /etc/systemd/system/${WP_SVC}.service
            systemctl daemon-reload
          fi
          rm -rf "$WP_DIR" /etc/vps-webpanel /etc/turbo-webpanel /opt/turbo-bots "$WP_LOG"
          ok "Removed. Also delete the hostname in the Cloudflare Dashboard."
        fi
        pause ;;
      0) return ;;
      *) err "Invalid choice"; sleep 1 ;;
    esac
  done
}

# ---------- Main menu ----------
main_menu() {
  while true; do
    header
    echo -e " ${GREEN}1)${NC}  System Info"
    echo -e " ${GREEN}2)${NC}  System Update"
    echo -e " ${GREEN}3)${NC}  Basic Tools Install"
    echo -e " ${GREEN}4)${NC}  Firewall (UFW)"
    echo -e " ${GREEN}5)${NC}  SSH Security / Users"
    echo -e " ${GREEN}6)${NC}  Web Server (Nginx + SSL)"
    echo -e " ${GREEN}7)${NC}  Optional Docker Install (not used by TURBO bots)"
    echo -e " ${GREEN}8)${NC}  Swap Setup"
    echo -e " ${GREEN}9)${NC}  Backup"
    echo -e " ${GREEN}10)${NC} Monitor"
    echo -e " ${GREEN}11)${NC} Network Check"
    echo -e " ${GREEN}12)${NC} Reboot"
    echo -e " ${GREEN}13)${NC} Cloudflare Tunnel"
    echo -e " ${GREEN}14)${NC} Web Panel (access via Tunnel)"
    echo -e " ${RED}0)${NC}  Exit"
    echo
    read -rp " Choose: " choice
    case $choice in
      1) sys_info ;;
      2) sys_update ;;
      3) install_tools ;;
      4) firewall_menu ;;
      5) ssh_menu ;;
      6) web_menu ;;
      7) install_docker ;;
      8) swap_menu ;;
      9) backup_menu ;;
      10) monitor_menu ;;
      11) net_menu ;;
      12) do_reboot ;;
      13) cf_menu ;;
      14) wp_menu ;;
      0) echo "Goodbye!"; exit 0 ;;
      *) err "Invalid choice"; sleep 1 ;;
    esac
  done
}

main_menu
