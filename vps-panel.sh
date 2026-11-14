#!/usr/bin/env bash
# =====================================================
#  VPS Panel - Simple server management menu
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
  echo -e "${RED}Root အဖြစ် run ပါ: sudo bash $0${NC}"
  exit 1
fi

# ---------- OS check ----------
if ! command -v apt-get >/dev/null 2>&1; then
  echo -e "${RED}Ubuntu/Debian သာ support လုပ်ပါတယ်။${NC}"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

pause() { echo; read -rp "Enter နှိပ်ပါ... " _; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*"; }

# ---------- Header ----------
header() {
  clear
  echo -e "${CYAN}${BOLD}"
  echo "╔══════════════════════════════════════════╗"
  echo "║              VPS  PANEL  v1.1            ║"
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
  ok "Update ပြီးပါပြီ"
  [[ -f /var/run/reboot-required ]] && warn "Reboot လိုအပ်ပါတယ်။"
  pause
}

# ---------- 3. Basic tools ----------
install_tools() {
  header
  echo -e "${BOLD}== Basic Tools Install ==${NC}"
  apt-get install -y curl wget git nano htop unzip zip ufw fail2ban net-tools
  ok "Tools install ပြီးပါပြီ"
  pause
}

# ---------- 4. Firewall ----------
firewall_menu() {
  while true; do
    header
    echo -e "${BOLD}== Firewall (UFW) ==${NC}"
    echo " 1) Firewall ဖွင့်မယ် (SSH ကို အရင် allow လုပ်ပြီး)"
    echo " 2) Port ဖွင့်မယ်"
    echo " 3) Port ပိတ်မယ် (rule ဖျက်)"
    echo " 4) Status ကြည့်မယ်"
    echo " 5) Firewall ပိတ်မယ်"
    echo " 0) နောက်သို့"
    read -rp "ရွေးပါ: " c
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
        ok "UFW ဖွင့်ပြီး (SSH:${sshp}, 80, 443 allow)"
        pause ;;
      2)
        read -rp "Port နံပါတ်: " p
        read -rp "Protocol (tcp/udp) [tcp]: " pr; pr=${pr:-tcp}
        if [[ $p =~ ^[0-9]+$ ]] && (( p>=1 && p<=65535 )); then
          ufw allow "${p}/${pr}" && ok "Port $p/$pr ဖွင့်ပြီး"
        else err "Port မှားနေပါတယ်"; fi
        pause ;;
      3)
        read -rp "Port နံပါတ်: " p
        read -rp "Protocol (tcp/udp) [tcp]: " pr; pr=${pr:-tcp}
        ufw delete allow "${p}/${pr}" && ok "Rule ဖျက်ပြီး"
        pause ;;
      4) ufw status verbose; pause ;;
      5) ufw disable && warn "Firewall ပိတ်ထားပါတယ်"; pause ;;
      0) return ;;
      *) err "မှားနေပါတယ်" ; sleep 1 ;;
    esac
  done
}

# ---------- 5. SSH security ----------
ssh_menu() {
  while true; do
    header
    echo -e "${BOLD}== SSH Security ==${NC}"
    echo " 1) SSH Port ပြောင်းမယ်"
    echo " 2) Root password login ပိတ်မယ် (key ရှိမှသာ!)"
    echo " 3) Sudo user အသစ်ဖန်တီးမယ်"
    echo " 4) Fail2ban ဖွင့်မယ်"
    echo " 0) နောက်သို့"
    read -rp "ရွေးပါ: " c
    case $c in
      1)
        read -rp "Port အသစ် (1024-65535): " np
        if [[ $np =~ ^[0-9]+$ ]] && (( np>=1024 && np<=65535 )); then
          cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
          sed -i -E "s/^#?\s*Port .*/Port ${np}/" /etc/ssh/sshd_config
          command -v ufw >/dev/null && ufw allow "${np}/tcp"
          if sshd -t; then
            systemctl restart ssh 2>/dev/null || systemctl restart sshd
            ok "SSH Port => ${np} (session မပိတ်ခင် port အသစ်နဲ့ စမ်းချိတ်ကြည့်ပါ!)"
          else
            cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
            err "Config မှားလို့ ပြန်ထားလိုက်ပါတယ်"
          fi
        else err "Port မှားနေပါတယ်"; fi
        pause ;;
      2)
        warn "SSH key မထည့်ရသေးရင် ဒါကိုမလုပ်ပါနဲ့၊ server ထဲ ပြန်မဝင်နိုင်တော့ပါ။"
        read -rp "ဆက်လုပ်မလား? (yes/no): " a
        if [[ $a == yes ]]; then
          cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
          sed -i -E "s/^#?\s*PermitRootLogin .*/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config
          sed -i -E "s/^#?\s*PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
          if sshd -t; then
            systemctl restart ssh 2>/dev/null || systemctl restart sshd
            ok "Password login ပိတ်ပြီး"
          else
            cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
            err "Config မှားလို့ ပြန်ထားလိုက်ပါတယ်"
          fi
        fi
        pause ;;
      3)
        read -rp "Username: " u
        if [[ $u =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
          adduser --gecos "" "$u" && usermod -aG sudo "$u" && ok "User '$u' ဖန်တီးပြီး (sudo ပါ)"
        else err "Username မှားနေပါတယ်"; fi
        pause ;;
      4)
        apt-get install -y fail2ban
        systemctl enable --now fail2ban
        ok "Fail2ban ဖွင့်ပြီး"
        pause ;;
      0) return ;;
      *) err "မှားနေပါတယ်"; sleep 1 ;;
    esac
  done
}

# ---------- 6. Web server ----------
web_menu() {
  while true; do
    header
    echo -e "${BOLD}== Web Server ==${NC}"
    echo " 1) Nginx install"
    echo " 2) SSL (Let's Encrypt) ထည့်မယ်"
    echo " 3) Nginx restart"
    echo " 4) Nginx config test"
    echo " 0) နောက်သို့"
    read -rp "ရွေးပါ: " c
    case $c in
      1)
        apt-get install -y nginx
        systemctl enable --now nginx
        ok "Nginx install ပြီး"
        pause ;;
      2)
        read -rp "Domain (ဥပမာ example.com): " d
        read -rp "Email: " e
        if [[ -n $d && -n $e ]]; then
          apt-get install -y certbot python3-certbot-nginx
          certbot --nginx -d "$d" -m "$e" --agree-tos --no-eff-email --redirect
        else err "Domain/Email လိုအပ်ပါတယ်"; fi
        pause ;;
      3) systemctl restart nginx && ok "Restart ပြီး"; pause ;;
      4) nginx -t; pause ;;
      0) return ;;
      *) err "မှားနေပါတယ်"; sleep 1 ;;
    esac
  done
}

# ---------- 7. Docker ----------
install_docker() {
  header
  echo -e "${BOLD}== Docker Install ==${NC}"
  if command -v docker >/dev/null; then
    ok "Docker ရှိပြီးသားပါ: $(docker --version)"
  else
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    ok "Docker install ပြီး"
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
    warn "Swapfile ရှိပြီးသားပါ"
  else
    read -rp "Swap အရွယ်အစား GB (ဥပမာ 2): " s
    if [[ $s =~ ^[0-9]+$ ]] && (( s>0 )); then
      fallocate -l "${s}G" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$((s*1024))
      chmod 600 /swapfile
      mkswap /swapfile && swapon /swapfile
      grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
      ok "Swap ${s}GB ဖန်တီးပြီး"
    else err "တန်ဖိုးမှားနေပါတယ်"; fi
  fi
  pause
}

# ---------- 9. Backup ----------
backup_menu() {
  header
  echo -e "${BOLD}== Backup ==${NC}"
  read -rp "Backup ယူမယ့် folder (ဥပမာ /var/www): " src
  [[ -d $src ]] || { err "Folder မရှိပါ"; pause; return; }
  mkdir -p /root/backups
  out="/root/backups/$(basename "$src")-$(date +%F-%H%M).tar.gz"
  tar -czf "$out" "$src" && ok "Backup ပြီး: $out ($(du -h "$out" | cut -f1))"
  pause
}

# ---------- 10. Services / Monitor ----------
monitor_menu() {
  header
  echo -e "${BOLD}== Monitor ==${NC}"
  echo "-- Listening ports --"
  ss -tulpn | head -n 25
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
  read -rp "Reboot လုပ်မှာ သေချာလား? (yes/no): " a
  [[ $a == yes ]] && reboot
}

# ---------- 13. Cloudflare Tunnel ----------
cf_installed() { command -v cloudflared >/dev/null 2>&1; }

cf_install() {
  if cf_installed; then
    ok "cloudflared ရှိပြီးသားပါ: $(cloudflared --version 2>&1 | head -n1)"
    return 0
  fi
  echo "cloudflared install လုပ်နေပါတယ်..."
  mkdir -p --mode=0755 /usr/share/keyrings
  if ! curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
      -o /usr/share/keyrings/cloudflare-main.gpg; then
    err "Cloudflare key ဒေါင်းလို့မရပါ (internet စစ်ပါ)"; return 1
  fi
  echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
    > /etc/apt/sources.list.d/cloudflared.list
  apt-get update -y && apt-get install -y cloudflared
  if cf_installed; then ok "cloudflared install ပြီး"; else err "Install မအောင်မြင်ပါ"; return 1; fi
}

cf_connect() {
  cf_install || return 1
  echo
  echo -e "${BOLD}Cloudflare Zero Trust > Networks > Tunnels${NC} ထဲက Tunnel token ကို paste လုပ်ပါ။"
  echo "(token အစက eyJ... ဖြစ်ပါတယ်။ install command တစ်ခုလုံး paste လုပ်လည်းရပါတယ်)"
  echo "Paste လုပ်တာ screen မှာ မပေါ်ပါဘူး။"
  read -rsp "Token: " raw; echo

  # command တစ်ခုလုံး paste လုပ်ထားရင် token ကိုပဲ ထုတ်ယူ
  local token
  token=$(echo "$raw" | tr -d '[:space:]' | sed -E 's/.*(eyJ[A-Za-z0-9_=-]+)$/\1/')

  if [[ ! $token =~ ^eyJ[A-Za-z0-9_=-]{40,}$ ]]; then
    err "Token ပုံစံ မမှန်ပါ"
    return 1
  fi

  # service ရှိပြီးသားဆိုရင် အရင်ဖယ်
  if systemctl list-unit-files 2>/dev/null | grep -q '^cloudflared.service'; then
    warn "Tunnel service ရှိပြီးသားပါ၊ အသစ်နဲ့ အစားထိုးပါမယ်..."
    cloudflared service uninstall >/dev/null 2>&1
  fi

  if cloudflared service install "$token"; then
    systemctl enable --now cloudflared >/dev/null 2>&1
    sleep 3
    if systemctl is-active --quiet cloudflared; then
      ok "Tunnel ချိတ်ဆက်ပြီးပါပြီ"
      echo "Hostname/Service (ဥပမာ http://localhost:80) ကို Cloudflare Dashboard ထဲမှာ သတ်မှတ်ပါ။"
    else
      err "Service မ run ပါ။ Logs ကြည့်ပါ (option 4)"
    fi
  else
    err "Tunnel service install မအောင်မြင်ပါ"
  fi
  unset raw token
}

cf_menu() {
  while true; do
    header
    echo -e "${BOLD}== Cloudflare Tunnel ==${NC}"
    if cf_installed; then
      local st
      st=$(systemctl is-active cloudflared 2>/dev/null)
      [[ $st == active ]] && st="${GREEN}running${NC}" || st="${RED}${st:-not installed}${NC}"
      echo -e " Status: $st   ($(cloudflared --version 2>&1 | head -n1))"
    else
      echo -e " Status: ${YELLOW}cloudflared မ install ရသေးပါ${NC}"
    fi
    echo
    echo " 1) Tunnel token ထည့်ပြီး ချိတ်ဆက်မယ်"
    echo " 2) Status ကြည့်မယ်"
    echo " 3) Restart"
    echo " 4) Logs ကြည့်မယ် (နောက်ဆုံး 50 line)"
    echo " 5) Tunnel ဖြုတ်မယ် (service uninstall)"
    echo " 6) cloudflared ကို update လုပ်မယ်"
    echo " 0) နောက်သို့"
    read -rp "ရွေးပါ: " c
    case $c in
      1) cf_connect; pause ;;
      2) systemctl status cloudflared --no-pager 2>&1 | head -n 20; pause ;;
      3) systemctl restart cloudflared && ok "Restart ပြီး"; pause ;;
      4) journalctl -u cloudflared -n 50 --no-pager; pause ;;
      5)
        read -rp "Tunnel ဖြုတ်မှာ သေချာလား? (yes/no): " a
        if [[ $a == yes ]]; then
          cloudflared service uninstall && ok "Tunnel service ဖြုတ်ပြီး"
        fi
        pause ;;
      6)
        apt-get update -y && apt-get install -y --only-upgrade cloudflared
        ok "Update ပြီး"; pause ;;
      0) return ;;
      *) err "မှားနေပါတယ်"; sleep 1 ;;
    esac
  done
}

# ---------- 14. Web Panel (via Cloudflare Tunnel) ----------
WP_DIR=/opt/vps-webpanel
WP_APP=$WP_DIR/app.py
WP_CONF=/etc/vps-webpanel/config.json
WP_SVC=vps-webpanel

wp_installed() { [[ -f $WP_APP ]]; }

wp_port() {
  python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("port",8080))
except Exception: print(8080)' "$WP_CONF" 2>/dev/null
}

wp_write_app() {
  mkdir -p "$WP_DIR"
  chmod 700 "$WP_DIR"
  cat > "$WP_APP" <<'PYEOF'
#!/usr/bin/env python3
# VPS Web Panel - listens on 127.0.0.1 only, intended to be exposed via Cloudflare Tunnel.
# No arbitrary command execution: only a fixed whitelist of actions.
import os, sys, json, time, hmac, hashlib, secrets, html, shutil, subprocess, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from http.cookies import SimpleCookie, CookieError
from urllib.parse import urlparse, parse_qs

CONF = os.environ.get("VPSPANEL_CONF", "/etc/vps-webpanel/config.json")
SESSION_TTL = 8 * 3600
MAX_FAILS, LOCK_SECS = 5, 300
SERVICES = ["cloudflared", "nginx", "docker", "ssh", "ufw", "fail2ban"]
RESTARTABLE = ["nginx", "docker", "fail2ban"]

SESSIONS, FAILS, LOCK = {}, {}, threading.Lock()

SEC_HEADERS = {
    "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
    "X-Frame-Options": "DENY",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "Cache-Control": "no-store",
}

CSS = """
body{margin:0;font:15px/1.5 system-ui,sans-serif;background:#0f1419;color:#e6e6e6}
main{max-width:760px;margin:0 auto;padding:16px}
h1{font-size:20px;margin:0 0 12px}h2{font-size:16px;margin:20px 0 8px;color:#8ab4f8}
.card{background:#1a2129;border:1px solid #2a3440;border-radius:10px;padding:12px;margin:10px 0}
.row{display:flex;justify-content:space-between;align-items:center;gap:8px;padding:6px 0;border-bottom:1px solid #2a3440;flex-wrap:wrap}
.row:last-child{border:0}
.bar{height:8px;background:#2a3440;border-radius:4px;overflow:hidden;margin:4px 0 8px}
.bar i{display:block;height:100%}
.ok{color:#4caf50}.bad{color:#ef5350}.mut{color:#9aa5b1}
button,input{font:inherit;padding:8px 12px;border-radius:8px;border:1px solid #3a4756;background:#242d38;color:inherit}
button{cursor:pointer}button.danger{background:#7f2a2a;border-color:#a33}
input[type=text],input[type=password]{width:100%;box-sizing:border-box;margin:4px 0 10px}
a{color:#8ab4f8}
pre{white-space:pre-wrap;word-break:break-all;background:#0b0f13;padding:10px;border-radius:8px;font-size:12px}
form{display:inline}
.err{color:#ef5350;margin:0 0 10px}
"""


def esc(s):
    return html.escape(str(s), quote=True)


def page(title, body):
    return ("<!doctype html><html><head><meta charset=utf-8>"
            "<meta name=viewport content='width=device-width,initial-scale=1'>"
            "<meta name=robots content='noindex,nofollow'>"
            "<title>%s</title><style>%s</style></head><body><main>%s</main></body></html>"
            % (esc(title), CSS, body))


# ---------- config / auth ----------
def load_conf():
    try:
        with open(CONF) as f:
            return json.load(f)
    except Exception:
        return {}


def save_conf(conf):
    d = os.path.dirname(CONF)
    os.makedirs(d, mode=0o700, exist_ok=True)
    tmp = CONF + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(conf, f)
    os.replace(tmp, CONF)


def hash_pw(pw, salt_hex):
    return hashlib.pbkdf2_hmac("sha256", pw.encode(), bytes.fromhex(salt_hex), 200000).hex()


def cli_set_password(user):
    pw = sys.stdin.read().rstrip("\n")
    if len(pw) < 10:
        print("Password must be at least 10 characters")
        sys.exit(1)
    conf = load_conf()
    salt = secrets.token_hex(16)
    conf.update({"user": user, "salt": salt, "hash": hash_pw(pw, salt)})
    save_conf(conf)


def cli_set_port(port):
    p = int(port)
    if not 1024 <= p <= 65535:
        print("Invalid port")
        sys.exit(1)
    conf = load_conf()
    conf["port"] = p
    save_conf(conf)


# ---------- system helpers ----------
def run(cmd, timeout=30, env=None, stdout_only=False):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
        out = r.stdout if stdout_only else (r.stdout + r.stderr)
        return out.strip()
    except subprocess.TimeoutExpired:
        return "Timed out"
    except Exception as e:
        return "Error: %s" % e


def svc_state(name):
    out = run(["systemctl", "is-active", name], 5)
    return out.splitlines()[0] if out else "unknown"


def human(n):
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return "%.1f %s" % (n, u)
        n /= 1024.0
    return "%.1f PB" % n


def stats():
    mem = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, v = line.split(":", 1)
            mem[k] = int(v.split()[0]) * 1024
    total = mem["MemTotal"]
    avail = mem.get("MemAvailable", mem.get("MemFree", 0))
    du = shutil.disk_usage("/")
    up = float(open("/proc/uptime").read().split()[0])
    load = open("/proc/loadavg").read().split()[:3]
    osname = "Linux"
    try:
        for line in open("/etc/os-release"):
            if line.startswith("PRETTY_NAME="):
                osname = line.split("=", 1)[1].strip().strip('"')
    except Exception:
        pass
    d, rem = divmod(int(up), 86400)
    h, rem = divmod(rem, 3600)
    return {
        "host": os.uname().nodename, "os": osname, "cores": os.cpu_count() or 1,
        "load": " ".join(load), "uptime": "%dd %dh %dm" % (d, h, rem // 60),
        "mem_used": total - avail, "mem_total": total,
        "disk_used": du.used, "disk_total": du.total,
    }


def bar(p):
    p = max(0, min(100, int(p)))
    c = "#4caf50" if p < 70 else ("#ff9800" if p < 90 else "#ef5350")
    return "<div class=bar><i style='width:%d%%;background:%s'></i></div>" % (p, c)


def form(act, label, csrf, extra="", cls=""):
    return ("<form method=post action=/action><input type=hidden name=csrf value='%s'>"
            "<input type=hidden name=act value='%s'>%s<button class='%s'>%s</button></form>"
            % (esc(csrf), esc(act), extra, cls, esc(label)))


# ---------- HTTP handler ----------
class H(BaseHTTPRequestHandler):
    server_version = "vpspanel"
    sys_version = ""

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.ip(), fmt % args))

    def ip(self):
        return self.headers.get("CF-Connecting-IP") or self.client_address[0]

    def secure(self):
        return "https" in (self.headers.get("X-Forwarded-Proto", "") + self.headers.get("Cf-Visitor", ""))

    def out(self, code, body, extra=None):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        for k, v in SEC_HEADERS.items():
            self.send_header(k, v)
        for k, v in (extra or []):
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def redirect(self, to, extra=None):
        self.send_response(303)
        self.send_header("Location", to)
        self.send_header("Content-Length", "0")
        for k, v in SEC_HEADERS.items():
            self.send_header(k, v)
        for k, v in (extra or []):
            self.send_header(k, v)
        self.end_headers()

    def sess(self):
        try:
            m = SimpleCookie(self.headers.get("Cookie", "")).get("sid")
        except CookieError:
            return None
        if not m:
            return None
        with LOCK:
            s = SESSIONS.get(m.value)
            if s and s["exp"] > time.time():
                return m.value, s
            SESSIONS.pop(m.value, None)
        return None

    def form_data(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        if n > 4096:
            return {}
        raw = self.rfile.read(n).decode("utf-8", "replace")
        return {k: v[0] for k, v in parse_qs(raw).items()}

    # ----- pages -----
    def login_page(self, error=""):
        err = "<p class=err>%s</p>" % esc(error) if error else ""
        body = ("<h1>VPS Panel</h1><div class=card>%s<form method=post action=/login>"
                "<label>Username</label><input type=text name=u autocomplete=username required>"
                "<label>Password</label><input type=password name=p autocomplete=current-password required>"
                "<button>Login</button></form></div>" % err)
        self.out(200, page("Login", body))

    def dashboard(self, s):
        csrf = s[1]["csrf"]
        st = stats()
        mp = st["mem_used"] * 100 / st["mem_total"]
        dp = st["disk_used"] * 100 / st["disk_total"]
        rows = ""
        for n in SERVICES:
            state = svc_state(n)
            cls = "ok" if state == "active" else ("mut" if state in ("inactive", "unknown") else "bad")
            btn = form("restart:" + n, "Restart", csrf) if n in RESTARTABLE else ""
            rows += ("<div class=row><span><b>%s</b> <span class=%s>%s</span></span>"
                     "<span><a href='/logs?svc=%s'>Logs</a> %s</span></div>"
                     % (esc(n), cls, esc(state), esc(n), btn))
        body = (
            "<h1>%s</h1><div class=mut>%s &middot; up %s &middot; load %s</div>"
            "<h2>Resources</h2><div class=card>"
            "CPU cores: %d<br>RAM: %s / %s%s Disk /: %s / %s%s</div>"
            "<h2>Services</h2><div class=card>%s</div>"
            "<h2>Actions</h2><div class=card>%s "
            "<form method=post action=/action><input type=hidden name=csrf value='%s'>"
            "<input type=hidden name=act value=reboot>"
            "<label><input type=checkbox name=confirm value=yes required> confirm</label> "
            "<button class=danger>Reboot server</button></form></div>"
            "<div class=row><a href='/'>Refresh</a>"
            "<form method=post action=/logout><input type=hidden name=csrf value='%s'><button>Logout</button></form></div>"
            % (esc(st["host"]), esc(st["os"]), esc(st["uptime"]), esc(st["load"]),
               st["cores"], human(st["mem_used"]), human(st["mem_total"]), bar(mp),
               human(st["disk_used"]), human(st["disk_total"]), bar(dp),
               rows, form("check_updates", "Check updates", csrf), esc(csrf), esc(csrf)))
        self.out(200, page("VPS Panel", body))

    # ----- routes -----
    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/login":
            return self.login_page()
        s = self.sess()
        if not s:
            return self.redirect("/login")
        if u.path == "/":
            return self.dashboard(s)
        if u.path == "/logs":
            svc = parse_qs(u.query).get("svc", [""])[0]
            if svc not in SERVICES:
                return self.out(404, page("Not found", "<p>Not found</p>"))
            log = run(["journalctl", "-u", svc, "-n", "100", "--no-pager"], 15)
            return self.out(200, page("Logs", "<h1>%s logs</h1><pre>%s</pre><a href='/'>Back</a>"
                                      % (esc(svc), esc(log or "(empty)"))))
        self.out(404, page("Not found", "<p>Not found</p>"))

    def do_POST(self):
        path = urlparse(self.path).path
        d = self.form_data()
        if path == "/login":
            return self.do_login(d)
        s = self.sess()
        if not s:
            return self.redirect("/login")
        if not hmac.compare_digest(d.get("csrf", ""), s[1]["csrf"]):
            return self.out(403, page("Forbidden", "<p>Invalid CSRF token</p>"))
        if path == "/logout":
            with LOCK:
                SESSIONS.pop(s[0], None)
            return self.redirect("/login", [("Set-Cookie", "sid=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict")])
        if path == "/action":
            return self.do_action(d)
        self.out(404, page("Not found", "<p>Not found</p>"))

    def do_login(self, d):
        ip, now = self.ip(), time.time()
        with LOCK:
            if len(FAILS) > 10000:
                FAILS.clear()
            f = FAILS.get(ip, [0, 0])
            if f[1] > now:
                return self.out(429, page("Locked", "<p>Too many attempts. Try again later.</p>"))
        conf = load_conf()
        if "hash" not in conf:
            return self.out(500, page("Error", "<p>Panel is not configured.</p>"))
        ok_p = hmac.compare_digest(hash_pw(d.get("p", ""), conf["salt"]), conf["hash"])
        ok_u = hmac.compare_digest(d.get("u", "").encode(), conf["user"].encode())
        if not (ok_p and ok_u):
            with LOCK:
                f = FAILS.get(ip, [0, 0])
                f[0] += 1
                if f[0] >= MAX_FAILS:
                    f = [0, now + LOCK_SECS]
                FAILS[ip] = f
            sys.stderr.write("LOGIN FAILED from %s\n" % ip)
            time.sleep(1)
            return self.login_page("Invalid username or password")
        tok, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(24)
        with LOCK:
            FAILS.pop(ip, None)
            for k in [k for k, v in SESSIONS.items() if v["exp"] <= now]:
                SESSIONS.pop(k, None)
            SESSIONS[tok] = {"exp": now + SESSION_TTL, "csrf": csrf}
        cookie = "sid=%s; Path=/; HttpOnly; SameSite=Strict; Max-Age=%d%s" % (
            tok, SESSION_TTL, "; Secure" if self.secure() else "")
        sys.stderr.write("LOGIN OK from %s\n" % ip)
        self.redirect("/", [("Set-Cookie", cookie)])

    def do_action(self, d):
        act = d.get("act", "")
        if act.startswith("restart:") and act[8:] in RESTARTABLE:
            name = act[8:]
            out = run(["systemctl", "restart", name], 60) or "Restart command sent."
            out += "\nStatus: " + svc_state(name)
        elif act == "check_updates":
            env = dict(os.environ, DEBIAN_FRONTEND="noninteractive")
            run(["apt-get", "update", "-q"], 180, env)
            lst = run(["apt", "list", "--upgradable"], 30, env, stdout_only=True)
            lines = [l for l in lst.splitlines() if l and not l.startswith("Listing")]
            out = ("%d package(s) can be upgraded.\n\n" % len(lines)) + "\n".join(lines[:60])
        elif act == "reboot" and d.get("confirm") == "yes":
            subprocess.Popen(["/bin/sh", "-c", "sleep 3; systemctl reboot"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return self.out(200, page("Reboot", "<h1>Rebooting...</h1><p>Server will be back in a minute.</p>"))
        else:
            return self.out(400, page("Bad request", "<p>Unknown action</p>"))
        self.out(200, page("Result", "<h1>Result</h1><pre>%s</pre><a href='/'>Back</a>" % esc(out)))


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "--set-password":
        return cli_set_password(sys.argv[2])
    if len(sys.argv) >= 3 and sys.argv[1] == "--set-port":
        return cli_set_port(sys.argv[2])
    conf = load_conf()
    if "hash" not in conf:
        print("No password configured. Run the panel menu to set one.")
        sys.exit(1)
    srv = ThreadingHTTPServer(("127.0.0.1", int(conf.get("port", 8080))), H)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
PYEOF
  chmod 700 "$WP_APP"
}

wp_set_password() {
  local u pw1 pw2
  read -rp "Admin username [admin]: " u; u=${u:-admin}
  if [[ ! $u =~ ^[A-Za-z0-9_.-]{3,32}$ ]]; then err "Username မှားနေပါတယ် (3-32 လုံး၊ အက္ခရာ/ဂဏန်း)"; return 1; fi
  read -rsp "Password (အနည်းဆုံး 10 လုံး): " pw1; echo
  read -rsp "Password ထပ်ရိုက်ပါ: " pw2; echo
  if [[ $pw1 != "$pw2" ]]; then err "Password မတူပါ"; return 1; fi
  if printf '%s' "$pw1" | python3 "$WP_APP" --set-password "$u"; then
    chmod 600 "$WP_CONF"
    ok "Admin '$u' အတွက် password သတ်မှတ်ပြီး"
  else
    err "Password မသတ်မှတ်နိုင်ပါ"; return 1
  fi
}

wp_install() {
  header
  echo -e "${BOLD}== Web Panel Install ==${NC}"
  command -v python3 >/dev/null || apt-get install -y python3
  command -v curl >/dev/null || apt-get install -y curl

  systemctl stop "$WP_SVC" 2>/dev/null
  wp_write_app

  local port
  read -rp "Panel port (localhost မှာသာ listen လုပ်မယ်) [8080]: " port; port=${port:-8080}
  if [[ ! $port =~ ^[0-9]+$ ]] || (( port<1024 || port>65535 )); then err "Port မှားနေပါတယ်"; pause; return; fi
  if ss -ltn | awk '{print $4}' | grep -qE "[:.]${port}$"; then err "Port $port ကို တခြားက သုံးနေပါတယ်"; pause; return; fi
  python3 "$WP_APP" --set-port "$port" || { pause; return; }

  wp_set_password || { pause; return; }

  cat > /etc/systemd/system/${WP_SVC}.service <<EOF
[Unit]
Description=VPS Web Panel
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
  systemctl enable --now "$WP_SVC" >/dev/null 2>&1
  sleep 2

  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/login")
  if [[ $code == 200 ]]; then
    ok "Web panel run နေပါပြီ (http://127.0.0.1:${port})"
  else
    err "Panel မစတင်ပါ (HTTP $code)။ Logs: journalctl -u $WP_SVC -n 30"
    pause; return
  fi
  wp_tunnel_help "$port"
  pause
}

wp_tunnel_help() {
  local port=${1:-$(wp_port)}
  echo
  echo -e "${BOLD}Cloudflare Tunnel နဲ့ domain ချိတ်ရန်:${NC}"
  echo " 1) Cloudflare Zero Trust > Networks > Tunnels > (သင့် tunnel) > Edit"
  echo " 2) Published application / Public hostname > Add"
  echo "      Subdomain : panel   (ဥပမာ)"
  echo "      Domain    : သင့် domain ကို ရွေးပါ"
  echo "      Type      : HTTP"
  echo "      URL       : localhost:${port}"
  echo " 3) Save လုပ်ပြီး https://panel.yourdomain.com ကို ဖွင့်ပါ"
  echo
  echo -e "${YELLOW}လုံခြုံရေး အကြံပြုချက်:${NC} Zero Trust > Access > Applications မှာ"
  echo "ဒီ hostname အတွက် Access policy (email OTP/Google login) ထပ်ထည့်ပါ။"
  echo "ဒါဆို panel login မတိုင်ခင် Cloudflare က အရင်စစ်ပေးပါမယ်။"
  if ! systemctl is-active --quiet cloudflared 2>/dev/null; then
    echo
    warn "cloudflared မ run သေးပါ။ Menu 13 ကနေ Tunnel token အရင်ချိတ်ပါ။"
  fi
}

wp_menu() {
  while true; do
    header
    echo -e "${BOLD}== Web Panel ==${NC}"
    if wp_installed; then
      local st
      st=$(systemctl is-active "$WP_SVC" 2>/dev/null)
      [[ $st == active ]] && st="${GREEN}running${NC}" || st="${RED}${st:-stopped}${NC}"
      echo -e " Status: $st   Local: http://127.0.0.1:$(wp_port)"
    else
      echo -e " Status: ${YELLOW}မ install ရသေးပါ${NC}"
    fi
    echo
    echo " 1) Install / Reinstall"
    echo " 2) Status ကြည့်မယ်"
    echo " 3) Admin password ပြောင်းမယ်"
    echo " 4) Restart"
    echo " 5) Logs ကြည့်မယ် (login အောင်/မအောင် ပါ)"
    echo " 6) Cloudflare Tunnel ချိတ်ပုံ (hostname/port)"
    echo " 7) Panel code update (config မပျက်ပါ)"
    echo " 8) Uninstall"
    echo " 0) နောက်သို့"
    read -rp "ရွေးပါ: " c
    case $c in
      1) wp_install ;;
      2) systemctl status "$WP_SVC" --no-pager 2>&1 | head -n 15; pause ;;
      3) if wp_installed; then wp_set_password && systemctl restart "$WP_SVC" && ok "Session အားလုံး logout ဖြစ်သွားပါပြီ"; else err "အရင် install လုပ်ပါ"; fi; pause ;;
      4) systemctl restart "$WP_SVC" && ok "Restart ပြီး"; pause ;;
      5) journalctl -u "$WP_SVC" -n 50 --no-pager; pause ;;
      6) wp_tunnel_help; pause ;;
      7) if wp_installed; then wp_write_app && systemctl restart "$WP_SVC" && ok "Update ပြီး"; else err "အရင် install လုပ်ပါ"; fi; pause ;;
      8)
        read -rp "Web panel ဖြုတ်မှာ သေချာလား? (yes/no): " a
        if [[ $a == yes ]]; then
          systemctl disable --now "$WP_SVC" 2>/dev/null
          rm -f /etc/systemd/system/${WP_SVC}.service
          rm -rf "$WP_DIR" /etc/vps-webpanel
          systemctl daemon-reload
          ok "ဖြုတ်ပြီး။ Cloudflare Dashboard ထဲက hostname ကိုလည်း ဖျက်ပါ။"
        fi
        pause ;;
      0) return ;;
      *) err "မှားနေပါတယ်"; sleep 1 ;;
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
    echo -e " ${GREEN}7)${NC}  Docker Install"
    echo -e " ${GREEN}8)${NC}  Swap Setup"
    echo -e " ${GREEN}9)${NC}  Backup"
    echo -e " ${GREEN}10)${NC} Monitor"
    echo -e " ${GREEN}11)${NC} Network Check"
    echo -e " ${GREEN}12)${NC} Reboot"
    echo -e " ${GREEN}13)${NC} Cloudflare Tunnel"
    echo -e " ${GREEN}14)${NC} Web Panel (Tunnel နဲ့ဝင်ရန်)"
    echo -e " ${RED}0)${NC}  Exit"
    echo
    read -rp " ရွေးပါ: " choice
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
      0) echo "ကျေးဇူးတင်ပါတယ်!"; exit 0 ;;
      *) err "မှားနေပါတယ်"; sleep 1 ;;
    esac
  done
}

main_menu
