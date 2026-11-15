#!/usr/bin/env bash
# =====================================================
#  TBP - VPS management menu + Web Panel (app.py)
#  Supports: Ubuntu / Debian
#
#  Run with:
#    bash <(curl -fsSL https://raw.githubusercontent.com/Turbospeed1963/vps-panel/main/vps-panel.sh)
#  or:
#    curl -fsSL https://raw.githubusercontent.com/Turbospeed1963/vps-panel/main/vps-panel.sh -o vps-panel.sh && sudo bash vps-panel.sh
# =====================================================

set -u

TBP_VERSION="3.0"

# ---------- Theme ----------
if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then
  RED=$'\033[38;5;203m'; GREEN=$'\033[38;5;78m'; YELLOW=$'\033[38;5;221m'
  BLUE=$'\033[38;5;75m'; CYAN=$'\033[38;5;51m'; MAG=$'\033[38;5;141m'
  GREY=$'\033[38;5;245m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAG=''; GREY=''; BOLD=''; NC=''
fi

COLS=$(tput cols 2>/dev/null || echo 80)
[[ $COLS =~ ^[0-9]+$ ]] || COLS=80
W=$(( COLS - 2 )); (( W > 44 )) && W=44; (( W < 26 )) && W=26
PROMPT="  ${CYAN}❯${NC} Choose: "

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

# ---------- UI helpers ----------
pause() { echo; read -rp "  ${GREY}Press Enter to continue…${NC} " _; }
ok()    { echo -e "  ${GREEN}✔${NC} $*"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $*"; }
err()   { echo -e "  ${RED}✖${NC} $*"; }
info()  { echo -e "  ${BLUE}ℹ${NC} $*"; }

rule()  { local i s=""; for ((i=0;i<W;i++)); do s+="─"; done; echo -e "  ${GREY}${s}${NC}"; }
title() { echo; echo -e "  ${MAG}${BOLD}▌${NC} ${BOLD}$*${NC}"; rule; }
opt()   { printf "  ${CYAN}${BOLD}%2s${NC} ${GREY}›${NC} %s\n" "$1" "$2"; }

# Progress bar: pbar <percent>
pbar() {
  local p=$1 w=20 f i s="" col=$GREEN
  (( p < 0 )) && p=0; (( p > 100 )) && p=100
  (( p >= 70 )) && col=$YELLOW; (( p >= 90 )) && col=$RED
  f=$(( p * w / 100 ))
  for ((i=0;i<w;i++)); do if (( i < f )); then s+="█"; else s+="░"; fi; done
  printf "%s%s%s %3d%%" "$col" "$s" "$NC" "$p"
}

# Run a command with a spinner; output goes to a temp log (shown only on failure).
# usage: spin_run "Message" command args...
spin_run() {
  local msg=$1; shift
  local log rc pid i=0
  local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  log=$(mktemp)
  "$@" >"$log" 2>&1 </dev/null &
  pid=$!
  if [[ -t 1 ]]; then
    while kill -0 "$pid" 2>/dev/null; do
      printf "\r  ${CYAN}%s${NC} %s" "${frames[i++ % 10]}" "$msg"
      sleep 0.1
    done
    printf "\r\033[K"
  fi
  wait "$pid"; rc=$?
  if (( rc == 0 )); then ok "$msg"; else err "$msg ${GREY}(failed)${NC}"; tail -n 8 "$log" | sed 's/^/      /'; fi
  rm -f "$log"
  return $rc
}

# ---------- Banner / header ----------
banner() {
  local l=(
    "████████╗██╗   ██╗██████╗ ██████╗  ██████╗ "
    "╚══██╔══╝██║   ██║██╔══██╗██╔══██╗██╔═══██╗"
    "   ██║   ██║   ██║██████╔╝██████╔╝██║   ██║"
    "   ██║   ██║   ██║██╔══██╗██╔══██╗██║   ██║"
    "   ██║   ╚██████╔╝██║  ██║██████╔╝╚██████╔╝"
    "   ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚═════╝  ╚═════╝ "
  )
  local shades=(51 45 39 33 99 135) i
  echo
  if (( COLS >= 46 )); then
    for i in "${!l[@]}"; do
      if [[ -n $NC ]]; then printf '  \033[38;5;%sm%s\033[0m\n' "${shades[i]}" "${l[i]}"; else printf '  %s\n' "${l[i]}"; fi
    done
  else
    echo -e "  ${CYAN}${BOLD}⚡ T B P ⚡${NC}"
  fi
  echo -e "  ${GREY}VPS PANEL · v${TBP_VERSION} · Web Panel + Cloudflare Tunnel${NC}"
}

PUBIP=""
get_ip() {
  [[ -n $PUBIP ]] && return
  PUBIP=$(curl -4 -fsS --max-time 3 https://ifconfig.me 2>/dev/null || true)
  [[ -z $PUBIP ]] && PUBIP=$(hostname -I 2>/dev/null | awk '{print $1}')
  [[ -z $PUBIP ]] && PUBIP="N/A"
}

chip() { case $2 in active|running) printf '%s●%s %s' "$GREEN" "$NC" "$1" ;; *) printf '%s●%s %s' "$RED" "$NC" "$1" ;; esac; }

header() {
  clear
  banner
  rule
  local ram os
  ram=$(free -m 2>/dev/null | awk '/^Mem:/ {printf "%d%%", $3*100/$2}')
  os=$(. /etc/os-release && echo "$PRETTY_NAME")
  echo -e "  ${CYAN}●${NC} ${GREY}Host${NC}  ${BOLD}$(hostname)${NC}"
  echo -e "  ${CYAN}●${NC} ${GREY}IP  ${NC}  ${BOLD}${PUBIP}${NC}"
  echo -e "  ${CYAN}●${NC} ${GREY}OS  ${NC}  ${os}"
  echo -e "  ${CYAN}●${NC} ${GREY}Up  ${NC}  $(uptime -p | sed 's/^up //') · RAM ${ram:-?}"
  echo -e "  $(chip Panel "$(tbp_state)")   $(chip Tunnel "$(cf_state)")"
  rule
}

# ---------- 1. System info ----------
sys_info() {
  header
  title "System Info"
  local mt mu dpct dtxt st su
  read -r mt mu < <(free -m | awk '/^Mem:/ {print $2, $3}')
  read -r st su < <(free -m | awk '/^Swap:/ {print $2, $3}')
  dpct=$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')
  dtxt=$(df -h / | awk 'NR==2 {print $3"/"$2}')
  echo -e "  ${GREY}CPU ${NC} $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs) ($(nproc) cores)"
  echo -e "  ${GREY}Load${NC} $(cut -d' ' -f1-3 /proc/loadavg)"
  echo
  echo -e "  ${GREY}RAM ${NC} $(pbar $(( mu * 100 / mt )))  ${GREY}${mu}/${mt} MB${NC}"
  if (( ${st:-0} > 0 )); then echo -e "  ${GREY}Swap${NC} $(pbar $(( su * 100 / st )))  ${GREY}${su}/${st} MB${NC}"; fi
  echo -e "  ${GREY}Disk${NC} $(pbar "$dpct")  ${GREY}${dtxt}${NC}"
  pause
}

# ---------- 2. Update ----------
sys_update() {
  header
  title "System Update"
  spin_run "Refreshing package lists" apt-get update -y
  spin_run "Upgrading packages" apt-get -o Dpkg::Options::=--force-confold upgrade -y
  spin_run "Cleaning up" apt-get autoremove -y
  [[ -f /var/run/reboot-required ]] && warn "Reboot required."
  pause
}

# ---------- 3. Basic tools ----------
install_tools() {
  header
  title "Basic Tools Install"
  spin_run "Installing curl wget git nano htop unzip zip ufw fail2ban net-tools" \
    apt-get install -y curl wget git nano htop unzip zip ufw fail2ban net-tools
  pause
}

# ---------- 4. Firewall ----------
firewall_menu() {
  while true; do
    header
    title "Firewall (UFW)"
    opt 1 "Enable firewall (allows SSH first)"
    opt 2 "Open a port"
    opt 3 "Close a port (delete rule)"
    opt 4 "Show status"
    opt 5 "Disable firewall"
    opt 0 "Back"
    echo
    read -rp "$PROMPT" c
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
        read -rp "  Port number: " p
        read -rp "  Protocol (tcp/udp) [tcp]: " pr; pr=${pr:-tcp}
        if [[ $p =~ ^[0-9]+$ ]] && (( p>=1 && p<=65535 )); then
          ufw allow "${p}/${pr}" && ok "Port $p/$pr opened"
        else err "Invalid port"; fi
        pause ;;
      3)
        read -rp "  Port number: " p
        read -rp "  Protocol (tcp/udp) [tcp]: " pr; pr=${pr:-tcp}
        ufw delete allow "${p}/${pr}" && ok "Rule deleted"
        pause ;;
      4) ufw status verbose; pause ;;
      5) ufw disable && warn "Firewall disabled"; pause ;;
      0) return ;;
      *) err "Invalid choice"; sleep 1 ;;
    esac
  done
}

# ---------- 5. SSH security ----------
ssh_menu() {
  while true; do
    header
    title "SSH Security / Users"
    opt 1 "Change SSH port"
    opt 2 "Disable root password login"
    opt 3 "Create a new sudo user"
    opt 4 "Enable Fail2ban"
    opt 0 "Back"
    echo
    read -rp "$PROMPT" c
    case $c in
      1)
        read -rp "  New port (1024-65535): " np
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
        read -rp "  Continue? (yes/no): " a
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
        read -rp "  Username: " u
        if [[ $u =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
          adduser --gecos "" "$u" && usermod -aG sudo "$u" && ok "User '$u' created (with sudo)"
        else err "Invalid username"; fi
        pause ;;
      4)
        spin_run "Installing Fail2ban" apt-get install -y fail2ban
        systemctl enable --now fail2ban >/dev/null 2>&1
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
    title "Web Server"
    opt 1 "Nginx install"
    opt 2 "Add SSL (Let's Encrypt)"
    opt 3 "Nginx restart"
    opt 4 "Nginx config test"
    opt 0 "Back"
    echo
    read -rp "$PROMPT" c
    case $c in
      1)
        spin_run "Installing Nginx" apt-get install -y nginx
        systemctl enable --now nginx >/dev/null 2>&1
        pause ;;
      2)
        read -rp "  Domain (e.g. example.com): " d
        read -rp "  Email: " e
        if [[ -n $d && -n $e ]]; then
          spin_run "Installing certbot" apt-get install -y certbot python3-certbot-nginx
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
  title "Docker Install"
  if command -v docker >/dev/null; then
    ok "Docker already installed: $(docker --version)"
  else
    spin_run "Installing Docker" bash -c 'curl -fsSL https://get.docker.com | sh' \
      && { systemctl enable --now docker >/dev/null 2>&1; ok "Docker is running"; }
  fi
  pause
}

# ---------- 8. Swap ----------
swap_menu() {
  header
  title "Swap"
  swapon --show
  echo
  if swapon --show | grep -q '/swapfile'; then
    warn "Swapfile already exists"
  else
    read -rp "  Swap size in GB (e.g. 2): " s
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
  title "Backup"
  read -rp "  Folder to back up (e.g. /var/www): " src
  [[ -d $src ]] || { err "Folder not found"; pause; return; }
  mkdir -p /root/backups
  local out="/root/backups/$(basename "$src")-$(date +%F-%H%M).tar.gz"
  tar -czf "$out" "$src" && ok "Backup done: $out ($(du -h "$out" | cut -f1))"
  pause
}

# ---------- 10. Monitor ----------
monitor_menu() {
  header
  title "Monitor"
  echo -e "  ${BOLD}Listening ports${NC}"
  command -v ss >/dev/null || { apt-get update -y >/dev/null 2>&1; apt-get install -y iproute2 >/dev/null 2>&1; }
  ss -tulpn 2>/dev/null | head -n 25 || echo "(ss not available)"
  echo
  echo -e "  ${BOLD}Top 5 CPU${NC}"
  ps aux --sort=-%cpu | head -n 6
  echo
  echo -e "  ${BOLD}Top 5 RAM${NC}"
  ps aux --sort=-%mem | head -n 6
  pause
}

# ---------- 11. Network ----------
net_menu() {
  header
  title "Network"
  echo -e "  ${GREY}Public IP${NC} : ${BOLD}$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || echo N/A)${NC}"
  echo -e "  ${GREY}Ping 1.1.1.1${NC}:"
  ping -c 3 1.1.1.1
  pause
}

# ---------- 12. Reboot ----------
do_reboot() {
  read -rp "  Reboot now? (yes/no): " a
  [[ $a == yes ]] && reboot
}

# ---------- 13. Cloudflare Tunnel ----------
CF_DIR=/etc/cloudflared-panel
CF_TOKEN_FILE=$CF_DIR/token
CF_LOG=/var/log/cloudflared-panel.log

# Run a command fully detached from this terminal: new session (setsid), ignores
# hangup (nohup), no tty on stdin. It keeps running after you close the terminal.
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
  mkdir -p --mode=0755 /usr/share/keyrings
  if ! spin_run "Downloading Cloudflare key" curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
      -o /usr/share/keyrings/cloudflare-main.gpg; then
    err "Could not download Cloudflare key (check internet)"; return 1
  fi
  echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
    > /etc/apt/sources.list.d/cloudflared.list
  spin_run "Installing cloudflared" bash -c 'apt-get update -y && apt-get install -y cloudflared'
  if cf_installed; then return 0; else err "Install failed"; return 1; fi
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
  echo -e "  ${BOLD}Cloudflare Zero Trust › Networks › Tunnels${NC} → copy your Tunnel token and paste it below."
  echo -e "  ${GREY}(Token starts with eyJ... You can also paste the whole install command)${NC}"
  echo -e "  ${GREY}Pasted text is hidden on screen.${NC}"
  read -rsp "  Token: " raw; echo

  # If the whole command was pasted, extract only the token
  local token
  token=$(echo "$raw" | tr -d '[:space:]' | sed -E 's/.*(eyJ[A-Za-z0-9_=-]+)$/\1/')

  if [[ ! $token =~ ^eyJ[A-Za-z0-9_=-]{40,}$ ]]; then
    err "Invalid token format"
    unset raw token
    return 1
  fi

  if have_systemd; then
    if systemctl list-unit-files 2>/dev/null | grep -q '^cloudflared.service'; then
      warn "Tunnel service already exists, replacing it..."
      cloudflared service uninstall >/dev/null 2>&1
    fi

    if cloudflared service install "$token"; then
      systemctl enable --now cloudflared >/dev/null 2>&1
      sleep 3
      if systemctl is-active --quiet cloudflared; then
        ok "Tunnel connected"
        info "Set the Hostname/Service (e.g. http://localhost:8787) in the Cloudflare Dashboard."
      else
        err "Service is not running. Check logs (menu 13 → 4)"
      fi
    else
      err "Tunnel service install failed"
    fi
  else
    warn "systemd not available (container). Running cloudflared as a background process."
    if [[ -e /etc/init.d/cloudflared ]]; then
      cloudflared service uninstall >/dev/null 2>&1
      rm -f /etc/init.d/cloudflared
    fi
    mkdir -p "$CF_DIR"; chmod 700 "$CF_DIR"
    ( umask 077; printf '%s' "$token" > "$CF_TOKEN_FILE" )
    echo "  Connecting..."
    if cf_start_bg; then
      ok "Tunnel connected (background process)"
      info "It keeps running after you close this terminal."
      info "Set the Hostname/Service in the Cloudflare Dashboard (Web Panel: localhost:8787)."
      warn "In a container the tunnel stops when the container restarts. Re-run menu 13 → 1 or 3 then."
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
    echo "  State : $(cf_state)"
    cf_running && echo "  PID   : $(pgrep -x cloudflared | head -n1)"
    echo "  --- last log lines ---"
    tail -n 8 "$CF_LOG" 2>/dev/null || echo "  (no log yet)"
  fi
}

cf_menu() {
  while true; do
    header
    title "Cloudflare Tunnel"
    if cf_installed; then
      local st
      st=$(cf_state)
      if [[ $st == active ]]; then st="${GREEN}running${NC}"; else st="${RED}${st:-stopped}${NC}"; fi
      echo -e "  Status: $st   ${GREY}($(cloudflared --version 2>&1 | head -n1 | cut -c1-40))${NC}"
      have_systemd || echo -e "  Mode  : ${YELLOW}background process (no systemd)${NC}"
    else
      echo -e "  Status: ${YELLOW}cloudflared not installed${NC}"
    fi
    echo
    opt 1 "Enter tunnel token and connect"
    opt 2 "Show status"
    opt 3 "Restart"
    opt 4 "Show logs (last 50 lines)"
    opt 5 "Remove tunnel"
    opt 6 "Update cloudflared"
    opt 0 "Back"
    echo
    read -rp "$PROMPT" c
    case $c in
      1) cf_connect; pause ;;
      2) cf_status; pause ;;
      3)
        if have_systemd; then
          systemctl restart cloudflared && ok "Restarted"
        else
          echo "  Restarting..."
          if cf_start_bg; then ok "Restarted, tunnel connected"; else err "Did not connect"; tail -n 8 "$CF_LOG" 2>/dev/null; fi
        fi
        pause ;;
      4)
        if have_systemd; then journalctl -u cloudflared -n 50 --no-pager; else tail -n 50 "$CF_LOG" 2>/dev/null || echo "  (no log yet)"; fi
        pause ;;
      5)
        read -rp "  Remove tunnel? (yes/no): " a
        if [[ $a == yes ]]; then
          pkill -x cloudflared 2>/dev/null
          cloudflared service uninstall >/dev/null 2>&1
          rm -rf "$CF_DIR" "$CF_LOG"
          ok "Tunnel removed"
        fi
        pause ;;
      6)
        spin_run "Updating cloudflared" bash -c 'apt-get update -y && apt-get install -y --only-upgrade cloudflared'
        info "Restart the tunnel to use the new version"; pause ;;
      0) return ;;
      *) err "Invalid choice"; sleep 1 ;;
    esac
  done
}

# ---------- 14. Web Panel (app.py) ----------
TBP_DIR=/opt/tb-panel
TBP_APP=$TBP_DIR/app.py
TBP_CONF=$TBP_DIR/config.json
TBP_SVC=tb-panel
TBP_LOG=/var/log/tb-panel.log
TBP_PORT=8787
# Override with: TBP_URL=... sudo -E bash vps-panel.sh
TBP_URL="${TBP_URL:-https://raw.githubusercontent.com/Turbospeed1963/vps-panel/main/app.py}"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)

tbp_installed() { [[ -f $TBP_APP ]]; }

tbp_state() {
  if have_systemd; then
    systemctl is-active "$TBP_SVC" 2>/dev/null || true
  elif pgrep -f "python3 $TBP_APP" >/dev/null 2>&1; then
    echo active
  else
    echo inactive
  fi
}

# Stop the older panel (vps-webpanel) if it exists
tbp_stop_old() {
  if have_systemd && systemctl list-unit-files 2>/dev/null | grep -q '^vps-webpanel.service'; then
    systemctl disable --now vps-webpanel >/dev/null 2>&1
    rm -f /etc/systemd/system/vps-webpanel.service
    systemctl daemon-reload
  fi
  pkill -f "python3 /opt/vps-webpanel/app.py" 2>/dev/null || true
}

tbp_fetch_app() {
  mkdir -p "$TBP_DIR"; chmod 700 "$TBP_DIR"
  local tmp; tmp=$(mktemp)
  if [[ -n $SCRIPT_DIR && -f $SCRIPT_DIR/app.py ]]; then
    cp "$SCRIPT_DIR/app.py" "$tmp"; info "Using app.py next to this script"
  elif ! curl -fsSL --max-time 30 "$TBP_URL" -o "$tmp"; then
    err "Could not download app.py from GitHub"
    info "URL: $TBP_URL"
    rm -f "$tmp"; return 1
  fi
  if ! grep -q 'Userbot Web Panel' "$tmp" || \
     ! python3 -c 'import ast,sys; ast.parse(open(sys.argv[1],encoding="utf-8").read())' "$tmp" 2>/dev/null; then
    err "Downloaded app.py is invalid"; rm -f "$tmp"; return 1
  fi
  install -m 600 "$tmp" "$TBP_APP"; rm -f "$tmp"
  ok "app.py installed to $TBP_APP"
}

tbp_set_password() {
  local u
  read -rp "  Admin username [admin]: " u; u=${u:-admin}
  if [[ ! $u =~ ^[A-Za-z0-9_.-]{3,32}$ ]]; then err "Invalid username"; return 1; fi
  TBP_HOME=$TBP_DIR python3 "$TBP_APP" --set-password "$u"
}

tbp_write_unit() {
  cat > /etc/systemd/system/$TBP_SVC.service <<EOF
[Unit]
Description=TBP Userbot Web Panel
After=network.target

[Service]
Environment=TBP_HOME=$TBP_DIR
Environment=TBP_PORT=$TBP_PORT
ExecStart=$(command -v python3) $TBP_APP
WorkingDirectory=$TBP_DIR
Restart=always
RestartSec=3
# Keep bot processes alive when the panel restarts (panel re-adopts them)
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

tbp_start() {
  if have_systemd; then
    tbp_write_unit
    systemctl enable "$TBP_SVC" >/dev/null 2>&1
    systemctl restart "$TBP_SVC"
  else
    pkill -f "python3 $TBP_APP" 2>/dev/null; sleep 1
    detach_run "$TBP_LOG" env TBP_HOME="$TBP_DIR" TBP_PORT="$TBP_PORT" python3 "$TBP_APP"
  fi
  local i
  for i in 1 2 3 4 5 6; do
    sleep 1
    if curl -s --max-time 3 "http://127.0.0.1:$TBP_PORT/login" | grep -q 'TBP'; then
      ok "Web panel running on http://127.0.0.1:$TBP_PORT"
      return 0
    fi
  done
  err "Panel did not start. Last logs:"
  tbp_logs_tail
  return 1
}

tbp_stop() {
  if have_systemd; then
    systemctl stop "$TBP_SVC" 2>/dev/null
  else
    pkill -f "python3 $TBP_APP" 2>/dev/null
  fi
  sleep 1
}

tbp_restart() { tbp_stop; tbp_start; }

tbp_logs_tail() {
  if have_systemd; then
    journalctl -u "$TBP_SVC" -n 15 --no-pager 2>/dev/null
  else
    tail -n 15 "$TBP_LOG" 2>/dev/null || echo "  (no log yet)"
  fi
}

tbp_status() {
  if have_systemd; then
    systemctl status "$TBP_SVC" --no-pager 2>&1 | head -n 12
  else
    echo "  State: $(tbp_state)  (background process, no systemd)"
    tail -n 6 "$TBP_LOG" 2>/dev/null
  fi
}

tbp_logs() {
  if have_systemd; then
    journalctl -u "$TBP_SVC" -n 80 --no-pager
  else
    tail -n 80 "$TBP_LOG" 2>/dev/null || echo "  (no log yet)"
  fi
}

tbp_install() {
  header
  title "Web Panel (app.py) · Install"
  if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
    spin_run "Installing python3" apt-get install -y python3
    if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
      err "Python 3.10+ is required (Ubuntu 22.04+ / Debian 12+)"; pause; return
    fi
  fi
  command -v curl >/dev/null || spin_run "Installing curl" apt-get install -y curl

  tbp_stop_old
  tbp_fetch_app || { pause; return; }

  if [[ ! -s $TBP_CONF ]] || ! grep -q '"hash"' "$TBP_CONF"; then
    tbp_set_password || { pause; return; }
  else
    ok "Admin password already set (kept)"
  fi

  tbp_start || { pause; return; }

  echo
  read -rp "  Connect Cloudflare Tunnel now? [y/N]: " a
  if [[ $a =~ ^[Yy] ]]; then cf_connect; fi
  echo
  info "Cloudflare Dashboard → Tunnel → Public Hostname: panel.yourdomain.com → HTTP → localhost:$TBP_PORT"
  pause
}

tbp_uninstall() {
  read -rp "  Remove web panel, bots and config? (yes/no): " a
  [[ $a == yes ]] || return
  tbp_stop
  local p
  for p in $(pgrep -f 'bot\.(py|js)$' 2>/dev/null); do
    case $(readlink "/proc/$p/cwd" 2>/dev/null) in
      "$TBP_DIR"/bots/*) kill "$p" 2>/dev/null ;;
    esac
  done
  if have_systemd; then
    systemctl disable "$TBP_SVC" 2>/dev/null
    rm -f /etc/systemd/system/$TBP_SVC.service
    systemctl daemon-reload
  fi
  rm -rf "$TBP_DIR" "$TBP_LOG"
  ok "Removed. Also delete the hostname in the Cloudflare Dashboard."
}

wp_menu() {
  while true; do
    header
    title "Web Panel (app.py) + Cloudflare"
    if tbp_installed; then
      local st
      st=$(tbp_state)
      if [[ $st == active ]]; then st="${GREEN}running${NC}"; else st="${RED}${st}${NC}"; fi
      echo -e "  Status: $st   ${GREY}http://127.0.0.1:$TBP_PORT${NC}"
    else
      echo -e "  Status: ${YELLOW}not installed${NC}"
    fi
    echo
    opt 1 "Install / update web panel"
    opt 2 "Change admin password"
    opt 3 "Restart"
    opt 4 "Stop"
    opt 5 "Show status"
    opt 6 "Show logs"
    opt 7 "Cloudflare Tunnel (token)"
    opt 8 "Uninstall"
    opt 0 "Back"
    echo
    read -rp "$PROMPT" c
    case $c in
      1) tbp_install ;;
      2) if tbp_installed; then tbp_set_password && tbp_restart; else err "Install first"; fi; pause ;;
      3) if tbp_installed; then tbp_restart; else err "Install first"; fi; pause ;;
      4) tbp_stop; ok "Stopped"; pause ;;
      5) tbp_status; pause ;;
      6) tbp_logs; pause ;;
      7) cf_menu ;;
      8) tbp_uninstall; pause ;;
      0) return ;;
      *) err "Invalid choice"; sleep 1 ;;
    esac
  done
}

# ---------- Main menu ----------
MENU=(
  "System Info" "System Update" "Basic Tools" "Firewall (UFW)" "SSH & Users" "Nginx + SSL" "Docker Install"
  "Swap Setup" "Backup" "Monitor" "Network Check" "Reboot" "Cloudflare Tunnel" "Web Panel (app.py)"
)

print_menu() {
  local i half=7
  if (( COLS >= 46 )); then
    for ((i=0;i<half;i++)); do
      printf "  ${CYAN}${BOLD}%2s${NC} ${GREY}›${NC} %-17s ${CYAN}${BOLD}%2s${NC} ${GREY}›${NC} %s\n" \
        "$((i+1))" "${MENU[i]}" "$((i+half+1))" "${MENU[i+half]}"
    done
  else
    for i in "${!MENU[@]}"; do opt "$((i+1))" "${MENU[i]}"; done
  fi
  echo
  echo -e "  ${RED}${BOLD} 0${NC} ${GREY}›${NC} Exit"
  echo
}

main_menu() {
  while true; do
    header
    print_menu
    read -rp "$PROMPT" choice
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
      0) echo -e "\n  ${CYAN}⚡ Goodbye!${NC}\n"; exit 0 ;;
      *) err "Invalid choice"; sleep 1 ;;
    esac
  done
}

printf "  ${GREY}Loading TBP…${NC}\r"
get_ip
main_menu
