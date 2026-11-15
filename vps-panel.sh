#!/usr/bin/env bash
# =====================================================
#  TURBO Panel - VPS management menu + Web Panel
#                (Telegram bot & userbot run from the web panel)
#  Supports: Ubuntu / Debian
#
#  Run with:
#    bash <(curl -fsSL https://YOUR-DOMAIN/vps-panel.sh)
#  or:
#    curl -fsSL https://YOUR-DOMAIN/vps-panel.sh -o vps-panel.sh && sudo bash vps-panel.sh
# =====================================================

set -u

TURBO_VERSION="2.0"

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
    echo -e "  ${CYAN}${BOLD}⚡ T U R B O ⚡${NC}"
  fi
  echo -e "  ${GREY}VPS PANEL · v${TURBO_VERSION} · Web + Telegram bots${NC}"
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
  echo -e "  $(chip Panel "$(wp_state)")   $(chip Tunnel "$(cf_state)")"
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
      *) err "Invalid choice" ; sleep 1 ;;
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
  out="/root/backups/$(basename "$src")-$(date +%F-%H%M).tar.gz"
  tar -czf "$out" "$src" && ok "Backup done: $out ($(du -h "$out" | cut -f1))"
  pause
}

# ---------- 10. Services / Monitor ----------
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

# ---------- 11. Speedtest / network ----------
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
        info "Set the Hostname/Service (e.g. http://localhost:80) in the Cloudflare Dashboard."
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
    echo "  Connecting..."
    if cf_start_bg; then
      ok "Tunnel connected (background process)"
      info "It keeps running after you close this terminal."
      info "Set the Hostname/Service in the Cloudflare Dashboard (web panel: menu 14 shows the port)."
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

# ---------- 14. Web Panel + Bots (via Cloudflare Tunnel) ----------
WP_DIR=/opt/vps-webpanel
WP_APP=$WP_DIR/app.py
WP_CONF=/etc/vps-webpanel/config.json
WP_SVC=vps-webpanel

WP_LOG=/var/log/vps-webpanel.log

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
  if have_systemd; then
    systemctl is-active "$WP_SVC" 2>/dev/null || true
  elif pgrep -f "python3 $WP_APP" >/dev/null 2>&1; then
    echo active
  else
    echo inactive
  fi
}

wp_stop() {
  if have_systemd; then
    systemctl stop "$WP_SVC" 2>/dev/null
  else
    pkill -f "python3 $WP_APP" 2>/dev/null; sleep 1
  fi
}

wp_start() {
  if have_systemd; then
    systemctl enable --now "$WP_SVC" >/dev/null 2>&1
  else
    detach_run "$WP_LOG" python3 "$WP_APP"
  fi
}

wp_restart() { wp_stop; wp_start; sleep 1; }

wp_status() {
  if have_systemd; then
    systemctl status "$WP_SVC" --no-pager 2>&1 | head -n 15
  else
    echo "  State: $(wp_state)  (background process, no systemd)"
    tail -n 8 "$WP_LOG" 2>/dev/null
  fi
}

wp_logs() {
  if have_systemd; then
    journalctl -u "$WP_SVC" -n 50 --no-pager
  else
    tail -n 50 "$WP_LOG" 2>/dev/null || echo "  (no log yet)"
  fi
}

wp_port() {
  python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("port",8080))
except Exception: print(8080)' "$WP_CONF" 2>/dev/null
}

# Writes a bot script unless the user replaced it with their own (no TURBO-BUILTIN marker).
wp_write_bot() {
  local f="$WP_DIR/bots/$1" tmp
  tmp=$(mktemp)
  cat > "$tmp"
  if [[ ! -f $f ]] || head -n 3 "$f" | grep -q 'TURBO-BUILTIN'; then
    install -m 600 "$tmp" "$f"
  else
    warn "Keeping your custom $1 (it has no TURBO-BUILTIN marker)"
  fi
  rm -f "$tmp"
}

wp_write_app() {
  mkdir -p "$WP_DIR/bots"
  chmod 700 "$WP_DIR" "$WP_DIR/bots"
  cat > "$WP_APP" <<'PYEOF'
#!/usr/bin/env python3
# TURBO Web Panel v2 - listens on 127.0.0.1 only; expose it through a Cloudflare Tunnel.
# No arbitrary command execution: fixed whitelist of actions. Bots run the fixed scripts in ./bots/.
import hashlib, hmac, html, json, os, re, secrets, shutil, signal, subprocess, sys, threading, time
from email.parser import BytesParser
from email.policy import default as email_default
import urllib.error, urllib.request
from http.cookies import CookieError, SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

VERSION = "2.1"
CONF = os.environ.get("VPSPANEL_CONF", "/etc/vps-webpanel/config.json")
BOTS_CONF = os.environ.get("TURBO_BOTS_CONF", os.path.join(os.path.dirname(CONF), "bots.json"))
BASE = os.path.dirname(os.path.abspath(__file__))
BOT_DIR, RUN_DIR = os.path.join(BASE, "bots"), os.path.join(BASE, "run")
VENV_PY = os.path.join(BASE, "venv", "bin", "python3")
LOG_DIR = os.environ.get("TURBO_LOG_DIR", "/var/log")
SESSION_TTL = 8 * 3600
MAX_FAILS, LOCK_SECS = 5, 300
SERVICES = ["cloudflared", "nginx", "docker", "ssh", "ufw", "fail2ban"]
RESTARTABLE = ["nginx", "docker", "fail2ban"]
BOTS = {
    "tgbot": {"title": "Telegram Bot", "script": "tgbot.py", "log": LOG_DIR + "/turbo-tgbot.log"},
    "userbot": {"title": "Userbot", "script": "userbot.py", "log": LOG_DIR + "/turbo-userbot.log"},
}

SESSIONS, FAILS, LOGINS = {}, {}, {}
LOCK = threading.Lock()
BLOCK = threading.RLock()          # guards bot processes + bots.json
PROC_OBJ, BSTATE = {}, {}
APP_PROCS = {}  # (username, filename) -> subprocess.Popen
APP_LOCK = threading.RLock()

SEC_HEADERS = {
    "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
    "X-Frame-Options": "DENY",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "Cache-Control": "no-store",
}

CSS = """
:root{color-scheme:dark;--bg:#060814;--bg2:#0b1024;--card:rgba(17,25,52,.72);--card2:rgba(25,35,72,.78);--line:rgba(157,177,255,.20);--txt:#f4f7ff;--mut:#9ba9c9;--a1:#31e7ff;--a2:#9b6cff;--a3:#ff4fd8;--ok:#42f5a7;--bad:#ff6b8a;--warn:#ffd166;--shadow:0 22px 55px rgba(0,0,0,.42)}
*{box-sizing:border-box}
html{background:var(--bg)}
body{margin:0;font:15px/1.55 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;color:var(--txt);min-height:100vh;overflow-x:hidden;background:radial-gradient(700px 500px at 8% -5%,rgba(49,231,255,.20),transparent 65%),radial-gradient(650px 520px at 95% 0%,rgba(155,108,255,.24),transparent 62%),radial-gradient(700px 500px at 55% 110%,rgba(255,79,216,.12),transparent 65%),linear-gradient(145deg,var(--bg),var(--bg2));background-attachment:fixed}
body:before,body:after{content:"";position:fixed;z-index:-1;width:280px;height:280px;border-radius:50%;filter:blur(80px);opacity:.28;pointer-events:none;animation:float 12s ease-in-out infinite alternate}
body:before{background:var(--a1);top:18%;left:-180px}body:after{background:var(--a3);right:-180px;bottom:8%;animation-delay:-5s}
@keyframes float{to{transform:translate3d(80px,-35px,0) scale(1.18)}}
main{max-width:900px;margin:0 auto;padding:20px 16px 48px;perspective:1200px}
.top{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:14px;padding:13px 15px;border:1px solid var(--line);border-radius:20px;background:rgba(10,16,38,.62);backdrop-filter:blur(18px);box-shadow:var(--shadow),inset 0 1px rgba(255,255,255,.12);transform:translateZ(12px)}
.brand{display:flex;align-items:center;gap:9px}.logo{font-weight:950;font-size:23px;letter-spacing:.22em;background:linear-gradient(100deg,var(--a1),#fff 42%,var(--a3));-webkit-background-clip:text;background-clip:text;color:transparent;text-shadow:0 0 28px rgba(49,231,255,.28)}
.ver{color:var(--mut);font-size:11px;letter-spacing:.16em;text-transform:uppercase;margin-top:5px}.bolt{width:23px;height:23px;fill:var(--a1);filter:drop-shadow(0 0 7px var(--a1)) drop-shadow(0 0 18px var(--a2))}
nav{display:flex;align-items:center;gap:7px;flex-wrap:wrap}nav a{color:var(--mut);text-decoration:none;padding:7px 13px;border-radius:999px;font-weight:700;font-size:13px;border:1px solid transparent;transition:.2s ease}nav a:hover{color:#fff;border-color:rgba(49,231,255,.35);background:rgba(49,231,255,.10);transform:translateY(-2px)}nav a.on{color:#fff;background:linear-gradient(110deg,rgba(49,231,255,.20),rgba(155,108,255,.25));border-color:rgba(155,108,255,.6);box-shadow:0 7px 20px rgba(111,91,255,.25),inset 0 1px rgba(255,255,255,.18)}
h1{font-size:26px;letter-spacing:-.02em;margin:18px 0 3px;text-shadow:0 4px 20px rgba(49,231,255,.18)}h2{font-size:12px;margin:25px 0 9px;color:#b9c6e8;letter-spacing:.16em;text-transform:uppercase}
.card{position:relative;background:linear-gradient(145deg,rgba(255,255,255,.10),rgba(255,255,255,.025) 35%,rgba(7,10,25,.25)),var(--card);border:1px solid var(--line);border-radius:20px;padding:16px;margin:11px 0;box-shadow:var(--shadow),inset 0 1px rgba(255,255,255,.13);backdrop-filter:blur(18px);transform:translateZ(8px);transition:.25s ease}.card:hover{transform:translateY(-3px) translateZ(12px);border-color:rgba(49,231,255,.36);box-shadow:0 28px 65px rgba(0,0,0,.48),0 0 30px rgba(49,231,255,.08),inset 0 1px rgba(255,255,255,.16)}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(175px,1fr));gap:13px;margin:15px 0}.tile{position:relative;overflow:hidden;background:linear-gradient(145deg,rgba(37,51,103,.78),rgba(12,17,38,.82));border:1px solid rgba(157,177,255,.24);border-radius:18px;padding:15px;box-shadow:0 14px 30px rgba(0,0,0,.34),inset 0 1px rgba(255,255,255,.14);transform:rotateX(1deg) translateZ(10px);transition:.25s ease}.tile:after{content:"";position:absolute;width:90px;height:90px;right:-35px;top:-45px;border-radius:50%;background:rgba(49,231,255,.28);filter:blur(16px)}.tile:hover{transform:translateY(-5px) rotateX(2deg) translateZ(18px);border-color:rgba(49,231,255,.55)}.tl{color:#aab8dc;font-size:11px;text-transform:uppercase;letter-spacing:.13em}.tv{font-size:23px;font-weight:850;margin-top:3px}.ts{color:var(--mut);font-size:12px}
.row{display:flex;justify-content:space-between;align-items:center;gap:10px;padding:12px 2px;border-bottom:1px solid rgba(157,177,255,.13);flex-wrap:wrap}.row:last-child{border:0}.acts{display:flex;gap:7px;flex-wrap:wrap;align-items:center}.bar{height:8px;background:#111a36;border-radius:99px;overflow:hidden;margin:9px 0 4px;box-shadow:inset 0 2px 5px rgba(0,0,0,.55)}.bar i{display:block;height:100%;border-radius:99px;box-shadow:0 0 12px currentColor}
.pill{display:inline-flex;align-items:center;gap:6px;padding:2px 10px;border-radius:999px;font-size:12px;font-weight:800;border:1px solid;box-shadow:inset 0 1px rgba(255,255,255,.12)}.pill:before{content:"";width:7px;height:7px;border-radius:50%;background:currentColor;box-shadow:0 0 8px currentColor}.pill.ok{color:var(--ok);border-color:rgba(66,245,167,.4);background:rgba(66,245,167,.10)}.pill.bad{color:var(--bad);border-color:rgba(255,107,138,.4);background:rgba(255,107,138,.10)}.pill.warn{color:var(--warn);border-color:rgba(255,209,102,.4);background:rgba(255,209,102,.10)}.pill.mut{color:var(--mut);border-color:var(--line)}
.mut{color:var(--mut)}.ctr{text-align:center}button,.btn{font:inherit;padding:9px 15px;border-radius:11px;border:1px solid rgba(157,177,255,.24);background:linear-gradient(145deg,#26345f,#151e3d);color:var(--txt);cursor:pointer;font-weight:750;text-decoration:none;display:inline-block;box-shadow:0 7px 15px rgba(0,0,0,.25),inset 0 1px rgba(255,255,255,.12);transition:.2s ease}button:hover,.btn:hover{transform:translateY(-2px);filter:brightness(1.14);box-shadow:0 12px 25px rgba(0,0,0,.35),0 0 20px rgba(49,231,255,.12),inset 0 1px rgba(255,255,255,.18)}.btn.pri{border:0;color:#07101e;background:linear-gradient(110deg,var(--a1),#77c7ff 45%,var(--a2));box-shadow:0 8px 24px rgba(49,231,255,.25)}.btn.dng{background:linear-gradient(110deg,#6b213b,#35152c);border-color:#a44462;color:#ffd9e2}.btn.ghost{background:rgba(255,255,255,.035)}.btn.sm{padding:5px 11px;font-size:13px}.wide{width:100%}
input[type=text],input[type=password],input[type=file]{font:inherit;width:100%;padding:11px 13px;margin:5px 0 13px;border-radius:12px;border:1px solid rgba(157,177,255,.22);background:rgba(5,10,27,.72);color:var(--txt);box-shadow:inset 0 3px 10px rgba(0,0,0,.26)}input[type=file]{padding:9px}input:focus{outline:2px solid rgba(49,231,255,.45);border-color:transparent;box-shadow:0 0 20px rgba(49,231,255,.12)}label{display:block;font-size:13px;color:#b4c0df;font-weight:700}a{color:var(--a1)}details{margin:8px 0}summary{cursor:pointer;color:#b4c0df;font-weight:700}code{background:rgba(4,9,24,.75);padding:2px 7px;border-radius:7px;color:#9cefff;border:1px solid rgba(49,231,255,.15)}pre{white-space:pre-wrap;word-break:break-all;background:rgba(3,6,17,.82);border:1px solid var(--line);padding:13px;border-radius:14px;font-size:12px;max-height:60vh;overflow:auto;box-shadow:inset 0 4px 18px rgba(0,0,0,.35)}form{margin:0}.inline{display:inline}.flash{padding:11px 15px;border-radius:14px;border:1px solid;font-weight:700;margin:13px 0;box-shadow:var(--shadow),inset 0 1px rgba(255,255,255,.12)}.flash.ok{color:var(--ok);border-color:rgba(66,245,167,.45);background:linear-gradient(110deg,rgba(66,245,167,.14),rgba(49,231,255,.06))}.flash.bad{color:var(--bad);border-color:rgba(255,107,138,.45);background:rgba(255,107,138,.10)}.auth{min-height:90vh;display:flex;align-items:center;justify-content:center}.authbox{width:100%;max-width:400px}.authbox .card{padding:22px}.foot{margin-top:32px;text-align:center;color:var(--mut);font-size:12px;letter-spacing:.12em;opacity:.85}
@media(max-width:560px){main{padding:12px 10px 35px}.top{padding:11px}.logo{font-size:20px}h1{font-size:23px}.grid{grid-template-columns:repeat(2,minmax(0,1fr));gap:9px}.tile{padding:12px}.tv{font-size:19px}nav{width:100%}nav a{flex:1;text-align:center}}
"""

BOLT = "<svg class=bolt viewBox='0 0 24 24'><path d='M13 2 4 14h6l-1 8 9-12h-6z'/></svg>"


def esc(s):
    return html.escape(str(s), quote=True)


def page(title, body):
    return ("<!doctype html><html><head><meta charset=utf-8>"
            "<meta name=viewport content='width=device-width,initial-scale=1'>"
            "<meta name=robots content='noindex,nofollow'>"
            "<title>%s</title><style>%s</style></head><body><main>%s</main></body></html>"
            % (esc(title), CSS, body))


def layout(s, title, body, active=""):
    with LOCK:
        fl = s[1].pop("flash", None)
    flash = "<div class='flash %s'>%s</div>" % (esc(fl[0]), esc(fl[1])) if fl else ""
    role = s[1].get("role", "admin")
    links = [("dash", "/", "Dashboard"), ("files", "/files", "My Apps")]
    if role == "admin": links.append(("bots", "/bots", "Bots"))
    nav = "".join("<a class='%s' href='%s'>%s</a>" % ("on" if k == active else "", h, t) for k, h, t in links)
    top = ("<div class=top><div class=brand>%s<span class=logo>TURBO</span><span class=ver>panel</span></div>"
           "<nav>%s<form method=post action=/logout><input type=hidden name=csrf value='%s'>"
           "<button class='btn ghost sm'>Logout</button></form></nav></div>" % (BOLT, nav, esc(s[1]["csrf"])))
    foot = "<div class=foot>TURBO PANEL v%s</div>" % VERSION
    return page(title, top + flash + body + foot)


# ---------- config / auth ----------
def read_json(path):
    try:
        with open(path) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f)
    os.replace(tmp, path)


def load_conf():
    return read_json(CONF)


def save_conf(conf):
    write_json(CONF, conf)


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


def users_load():
    conf = load_conf()
    users = conf.get("users", {})
    return users if isinstance(users, dict) else {}


def user_add(username, password):
    if not re.fullmatch(r"[A-Za-z0-9_.-]{3,32}", username) or len(password) < 10:
        return False, "Username must be 3-32 safe characters and password at least 10 characters"
    conf = load_conf()
    users = conf.setdefault("users", {})
    if username == conf.get("user") or username in users:
        return False, "Username already exists"
    salt = secrets.token_hex(16)
    users[username] = {"salt": salt, "hash": hash_pw(password, salt), "role": "user"}
    save_conf(conf)
    os.makedirs(os.path.join(BASE, "userbots", username), mode=0o700, exist_ok=True)
    return True, "User %s created" % username


def user_remove(username):
    conf = load_conf()
    users = conf.get("users", {})
    if username not in users:
        return False, "User not found"
    users.pop(username, None)
    save_conf(conf)
    return True, "User %s removed" % username


def cli_set_port(port):
    p = int(port)
    if not 1024 <= p <= 65535:
        print("Invalid port")
        sys.exit(1)
    conf = load_conf()
    conf["port"] = p
    save_conf(conf)


# ---------- bots config ----------
def bconf_load():
    d = read_json(BOTS_CONF)
    for n in BOTS:
        if not isinstance(d.get(n), dict):
            d[n] = {}
    return d


def bconf_update(bot, **kw):          # NB: the first parameter must not be called "name" (a config key)
    with BLOCK:
        d = bconf_load()
        for k, v in kw.items():
            if v is None:
                d[bot].pop(k, None)
            else:
                d[bot][k] = v
        write_json(BOTS_CONF, d)


def configured(name, c):
    if name == "tgbot":
        return bool(c.get("token"))
    return bool(c.get("session") and c.get("api_id") and c.get("api_hash"))


def mask(v, keep=4):
    v = str(v or "")
    return v[:keep] + "…" + v[-keep:] if len(v) > keep * 3 else "•" * len(v)


# ---------- bot processes ----------
def bot_py(name):
    return VENV_PY if name == "userbot" and os.path.exists(VENV_PY) else sys.executable


def bot_env():
    return {"PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"), "TURBO_BOTS_CONF": BOTS_CONF,
            "PYTHONUNBUFFERED": "1", "LANG": "C.UTF-8", "HOME": BASE}


def pid_file(name):
    return os.path.join(RUN_DIR, name + ".pid")


def read_pid(name):
    try:
        with open(pid_file(name)) as f:
            return int(f.read().strip())
    except Exception:
        return None


def pid_ok(pid, name):
    try:
        with open("/proc/%d/stat" % pid) as f:
            if f.read().rsplit(")", 1)[1].split()[0] in ("Z", "X"):
                return False
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            return BOTS[name]["script"] in f.read().decode("utf-8", "replace")
    except Exception:
        return False


def bot_running(name):
    pid = read_pid(name)
    return bool(pid and pid_ok(pid, name))


def bot_start(name, manual=True):
    with BLOCK:
        if bot_running(name):
            return True, "Already running"
        info = BOTS[name]
        script = os.path.join(BOT_DIR, info["script"])
        if not configured(name, bconf_load()[name]):
            return False, "Not set up yet (add the token)" if name == "tgbot" else "Not logged in yet"
        if not os.path.isfile(script):
            return False, "Bot script missing - run 'Update panel code' in the terminal menu"
        os.makedirs(RUN_DIR, mode=0o700, exist_ok=True)
        try:
            if os.path.getsize(info["log"]) > 5 * 1024 * 1024:
                os.replace(info["log"], info["log"] + ".1")
        except OSError:
            pass
        lf = os.fdopen(os.open(info["log"], os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600), "ab")
        try:
            p = subprocess.Popen([bot_py(name), script], stdin=subprocess.DEVNULL, stdout=lf, stderr=subprocess.STDOUT,
                                 cwd=BASE, env=bot_env(), start_new_session=True, close_fds=True)
        finally:
            lf.close()
        PROC_OBJ[name] = p
        with open(pid_file(name), "w") as f:
            f.write(str(p.pid))
        st = BSTATE.setdefault(name, {"fails": 0, "next": 0, "gave_up": False})
        st["started"] = time.time()
        if manual:
            st.update(fails=0, gave_up=False)
            bconf_update(name, enabled=True)
        time.sleep(1.5)
        if p.poll() is not None:
            return False, "Exited right away (code %s) - see Logs" % p.returncode
        return True, "Started"


def bot_stop(name, disable=True):
    with BLOCK:
        if disable:
            bconf_update(name, enabled=False)
        pid = read_pid(name)
        if pid and pid_ok(pid, name):
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(pid, sig)
                except Exception:
                    try:
                        os.kill(pid, sig)
                    except Exception:
                        pass
                for _ in range(40 if sig == signal.SIGTERM else 10):
                    p = PROC_OBJ.get(name)
                    if p is not None:
                        p.poll()
                    if not pid_ok(pid, name):
                        break
                    time.sleep(0.1)
                if not pid_ok(pid, name):
                    break
        PROC_OBJ.pop(name, None)
        try:
            os.remove(pid_file(name))
        except OSError:
            pass


def bot_restart(name):
    with BLOCK:
        bot_stop(name, disable=False)
        return bot_start(name)


def bot_status(name, conf):
    if bot_running(name):
        return "running", "ok"
    if conf[name].get("enabled") and configured(name, conf[name]):
        return ("crashed", "bad") if BSTATE.get(name, {}).get("gave_up") else ("restarting", "warn")
    return ("stopped", "mut") if configured(name, conf[name]) else ("not set up", "mut")


def watchdog():
    """Keeps enabled bots alive (also starts them after a panel/server restart)."""
    time.sleep(3)
    while True:
        try:
            conf = bconf_load()
            now = time.time()
            for name in BOTS:
                with BLOCK:
                    p = PROC_OBJ.get(name)
                    if p is not None:
                        p.poll()
                    st = BSTATE.setdefault(name, {"fails": 0, "next": 0, "gave_up": False})
                    if not conf[name].get("enabled"):
                        continue
                    if bot_running(name):
                        if now - st.get("started", now) > 120:
                            st["fails"] = 0
                        continue
                    if p is not None and p.returncode == 3:      # bot reported a fatal config problem
                        st["gave_up"] = True
                    if st["gave_up"] or now < st["next"]:
                        continue
                    st["fails"] += 1
                    if st["fails"] > 5:
                        st["gave_up"] = True
                        continue
                    st["next"] = now + min(120, 10 * 2 ** st["fails"])
                    bot_start(name, manual=False)
        except Exception as e:
            sys.stderr.write("watchdog error: %r\n" % e)
        time.sleep(10)


def tail(path, n=100, maxb=32768):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - maxb))
            return "\n".join(f.read().decode("utf-8", "replace").splitlines()[-n:]) or "(empty)"
    except FileNotFoundError:
        return "(no log yet)"
    except Exception as e:
        return "Error: %s" % e


_TL = {"t": 0, "ok": False}


def telethon_ok():
    if time.time() - _TL["t"] > 60:
        try:
            r = subprocess.run([bot_py("userbot"), "-c", "import telethon"], capture_output=True, timeout=15)
            _TL["ok"] = r.returncode == 0
        except Exception:
            _TL["ok"] = False
        _TL["t"] = time.time()
    return _TL["ok"]


def tg_getme(token):
    """Returns (username, error, fatal)."""
    try:
        with urllib.request.urlopen("https://api.telegram.org/bot%s/getMe" % token, timeout=10) as r:
            d = json.load(r)
        return d.get("result", {}).get("username", ""), "", False
    except urllib.error.HTTPError as e:
        if e.code in (401, 404):
            return "", "Telegram rejected this token", True
        return "", "Telegram error (HTTP %s)" % e.code, False
    except Exception as e:
        return "", "Could not reach Telegram (%s)" % e.__class__.__name__, False


def ub_helper(mode, payload, timeout=60):
    script = os.path.join(BOT_DIR, "userbot.py")
    if not os.path.isfile(script):
        return {"ok": False, "error": "userbot.py is missing - run 'Update panel code' in the terminal menu"}
    try:
        r = subprocess.run([bot_py("userbot"), script, mode], input=json.dumps(payload), capture_output=True,
                           text=True, timeout=timeout, env=bot_env())
        lines = r.stdout.strip().splitlines()
        return json.loads(lines[-1]) if lines else {"ok": False, "error": "No answer from helper"}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "Timed out talking to Telegram"}
    except Exception as e:
        return {"ok": False, "error": "Helper failed (%s)" % e.__class__.__name__}


def parse_admins(txt):
    ids = []
    for part in re.split(r"[,\s;]+", txt.strip()):
        if part:
            if not re.fullmatch(r"\d{4,15}", part):
                return None
            ids.append(int(part))
    return ids[:20]


# ---------- system helpers ----------
def run(cmd, timeout=30, env=None, stdout_only=False):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
        return (r.stdout if stdout_only else (r.stdout + r.stderr)).strip()
    except subprocess.TimeoutExpired:
        return "Timed out"
    except Exception as e:
        return "Error: %s" % e


SVC_PROCS = {"cloudflared": "cloudflared", "nginx": "nginx", "docker": "dockerd",
             "ssh": "sshd", "fail2ban": "fail2ban-server"}
HAS_SYSTEMD = os.path.isdir("/run/systemd/system")


def svc_state(name):
    if HAS_SYSTEMD:
        out = run(["systemctl", "is-active", name], 5)
        return out.splitlines()[0] if out else "unknown"
    proc = SVC_PROCS.get(name)
    if not proc:
        return "unknown"
    try:
        r = subprocess.run(["pgrep", "-x", proc], capture_output=True, timeout=5)
        return "active" if r.returncode == 0 else "inactive"
    except Exception:
        return "unknown"


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
    return {"host": os.uname().nodename, "os": osname, "cores": os.cpu_count() or 1,
            "load": " ".join(load), "load1": float(load[0]), "uptime": "%dd %dh %dm" % (d, h, rem // 60),
            "mem_used": total - avail, "mem_total": total, "disk_used": du.used, "disk_total": du.total}


# ---------- user uploaded Python/JavaScript apps ----------
APP_ROOT = os.path.join(BASE, "userbots")
APP_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
APP_EXTS = {".py", ".js"}
MAX_UPLOAD = 2 * 1024 * 1024
BLOCKED_PACKAGES = {"opencv-python", "numpy", "ddddocr", "aiohttp"}


def normalize_pkg(name):
    return re.sub(r"[-_.]+", "-", str(name).strip().lower())


def is_blocked_pkg(name):
    n = normalize_pkg(name)
    return n in {normalize_pkg(x) for x in BLOCKED_PACKAGES} or n.startswith("opencv-python-")


def app_dir(username):
    d = os.path.join(APP_ROOT, username)
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d


def app_path(username, name):
    if name == "requirements.txt":
        pass
    elif not APP_NAME.fullmatch(name) or os.path.splitext(name)[1].lower() not in APP_EXTS:
        return None
    root = os.path.realpath(app_dir(username))
    path = os.path.realpath(os.path.join(root, name))
    return path if os.path.dirname(path) == root else None


def app_key(username, name):
    return (username, name)


def app_running(username, name):
    with APP_LOCK:
        p = APP_PROCS.get(app_key(username, name))
        if not p or p.poll() is not None:
            APP_PROCS.pop(app_key(username, name), None)
            return False
        return True


def app_stop(username, name):
    with APP_LOCK:
        p = APP_PROCS.pop(app_key(username, name), None)
        if p and p.poll() is None:
            try:
                os.killpg(p.pid, signal.SIGTERM)
                p.wait(timeout=3)
            except Exception:
                try: p.kill()
                except Exception: pass


def venv_python(username):
    return os.path.join(app_dir(username), "venv", "bin", "python3")


def blocked_requirements(path):
    bad = []
    try:
        for line in open(path, encoding="utf-8", errors="replace"):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            if line.startswith(("-", "git+", "http:", "https:")):
                bad.append("unsupported requirement: " + line[:60])
                continue
            name = re.split(r"[<>=!~;\s]", line, 1)[0]
            if is_blocked_pkg(name):
                bad.append(normalize_pkg(name))
    except OSError:
        return ["requirements.txt unreadable"]
    return sorted(set(bad))


def install_requirements(username):
    req = app_path(username, "requirements.txt")
    if not req or not os.path.isfile(req): return False, "Upload requirements.txt first"
    bad = blocked_requirements(req)
    if bad: return False, "Blocked packages: " + ", ".join(bad)
    venv = os.path.join(app_dir(username), "venv")
    py = venv_python(username)
    report = os.path.join(app_dir(username), ".pip-dry-run.json")
    constraints = os.path.join(app_dir(username), ".pip-blocked-constraints.txt")
    try:
        # Negative constraints make pip fail resolution instead of ever selecting these names,
        # including when they arrive as transitive dependencies.
        with open(constraints, "w", encoding="utf-8") as cf:
            cf.write("\n".join(x + "<0" for x in sorted(BLOCKED_PACKAGES)) + "\n")
        if not os.path.exists(py):
            r = subprocess.run([sys.executable, "-m", "venv", venv], capture_output=True, text=True, timeout=60)
            if r.returncode != 0: return False, "Could not create virtual environment (python3-venv may be missing)"

        # Refuse to continue if a previous run already placed a blocked package here.
        listed = subprocess.run([py, "-m", "pip", "list", "--format=json"], capture_output=True, text=True, timeout=30)
        if listed.returncode == 0:
            try:
                present = [x.get("name", "") for x in json.loads(listed.stdout)]
                existing = sorted({normalize_pkg(x) for x in present if is_blocked_pkg(x)})
                if existing: return False, "Blocked package already present; install refused: " + ", ".join(existing)
            except (ValueError, TypeError):
                return False, "Could not verify installed packages; install refused"

        # Resolve the complete dependency tree without installing anything.
        # The JSON report includes transitive dependencies, not only requirements.txt lines.
        probe = subprocess.run([py, "-m", "pip", "install", "--dry-run", "--ignore-installed", "--no-cache-dir", "--report", report, "-c", constraints, "-r", req], capture_output=True, text=True, timeout=180)
        if probe.returncode != 0:
            return False, "Dependency check failed: " + (probe.stderr or probe.stdout)[-500:]
        try:
            plan = json.load(open(report, encoding="utf-8"))
            planned = [x.get("metadata", {}).get("name", "") for x in plan.get("install", [])]
        except (OSError, ValueError, TypeError):
            return False, "Could not verify pip dependency plan; install refused"
        transitive = sorted({normalize_pkg(x) for x in planned if is_blocked_pkg(x)})
        if transitive:
            return False, "Blocked dependency detected; nothing installed: " + ", ".join(transitive)

        r = subprocess.run([py, "-m", "pip", "install", "--no-cache-dir", "-c", constraints, "-r", req], capture_output=True, text=True, timeout=300)
        if r.returncode != 0:
            return False, "Dependency install failed: " + (r.stderr or r.stdout)[-500:]
        return True, "Allowed dependencies installed; blocked packages were checked before installation"
    except subprocess.TimeoutExpired:
        return False, "Dependency installation/check timed out"
    except Exception as e:
        return False, "Dependency installation error (%s)" % type(e).__name__
    finally:
        for tmp in (report, constraints):
            try: os.remove(tmp)
            except OSError: pass


def app_start(username, name):
    path = app_path(username, name)
    if not path or not os.path.isfile(path): return False, "Invalid app file"
    app_stop(username, name)
    logp = path + ".log"
    ext = os.path.splitext(name)[1].lower()
    cmd = [venv_python(username) if os.path.exists(venv_python(username)) else sys.executable, path] if ext == ".py" else (["node", path] if shutil.which("node") else None)
    if not cmd: return False, "Node.js is not installed; upload Python or install Node.js separately"
    try:
        lf = open(logp, "ab", buffering=0)
        p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=lf, stderr=subprocess.STDOUT,
                             cwd=app_dir(username), env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": app_dir(username), "PYTHONUNBUFFERED": "1"},
                             start_new_session=True, close_fds=True)
        with APP_LOCK: APP_PROCS[app_key(username, name)] = p
        return True, "%s started (PID %s)" % (name, p.pid)
    except Exception as e:
        return False, "Could not start app (%s)" % type(e).__name__


def app_list(username):
    out=[]
    for name in sorted(os.listdir(app_dir(username))):
        if os.path.splitext(name)[1].lower() in APP_EXTS and APP_NAME.fullmatch(name):
            out.append(name)
    return out


def parse_upload(handler):
    n = int(handler.headers.get("Content-Length") or 0)
    if n <= 0 or n > MAX_UPLOAD: return None, "File is empty or larger than 2 MB", {}
    ctype = handler.headers.get("Content-Type", "")
    if "multipart/form-data" not in ctype: return None, "Use multipart file upload", {}
    raw = handler.rfile.read(n)
    msg = BytesParser(policy=email_default).parsebytes((b"Content-Type: " + ctype.encode() + b"\r\n\r\n" + raw))
    fields = {}
    for part in msg.iter_parts():
        fn = part.get_filename()
        if fn:
            fn = os.path.basename(fn)
            return fn, part.get_payload(decode=True) or b"", fields
        name = part.get_param("name", header="content-disposition")
        if name:
            fields[name] = (part.get_payload(decode=True) or b"").decode("utf-8", "replace")
    return None, "No file selected", fields


# ---------- html helpers ----------
def bar(p):
    p = max(0, min(100, int(p)))
    c = "linear-gradient(90deg,#22d3ee,#8b5cf6)" if p < 70 else ("#fbbf24" if p < 90 else "#f87171")
    return "<div class=bar><i style='width:%d%%;background:%s'></i></div>" % (p, c)


def tile(label, value, pct=None, sub=""):
    return ("<div class=tile><div class=tl>%s</div><div class=tv>%s</div>%s<div class=ts>%s</div></div>"
            % (esc(label), esc(value), bar(pct) if pct is not None else "", esc(sub)))


def aform(csrf, act, inner, nxt="/bots", cls=""):
    return ("<form method=post action=/action class='%s'><input type=hidden name=csrf value='%s'>"
            "<input type=hidden name=act value='%s'><input type=hidden name=next value='%s'>%s</form>"
            % (cls, esc(csrf), esc(act), esc(nxt), inner))


def abtn(csrf, act, label, cls="", nxt="/", extra=""):
    return aform(csrf, act, "%s<button class='btn %s'>%s</button>" % (extra, cls, esc(label)), nxt, "inline")


def field(label, name, value="", typ="text", ph=""):
    return ("<label>%s</label><input type=%s name=%s value='%s' placeholder='%s' autocomplete=off>"
            % (esc(label), typ, name, esc(value), esc(ph)))


def bot_controls(name, csrf, nxt, conf):
    c, out = conf[name], []
    if configured(name, c):
        if bot_running(name):
            out.append(abtn(csrf, "bot:restart:" + name, "Restart", "sm", nxt))
            out.append(abtn(csrf, "bot:stop:" + name, "Stop", "sm dng", nxt))
        else:
            out.append(abtn(csrf, "bot:start:" + name, "Start", "sm pri", nxt))
            if c.get("enabled"):
                out.append(abtn(csrf, "bot:stop:" + name, "Stop", "sm dng", nxt))
    out.append("<a class='btn ghost sm' href='/botlog?b=%s'>Logs</a>" % name)
    return "".join(out)


# ---------- HTTP handler ----------
class H(BaseHTTPRequestHandler):
    server_version = "turbopanel"
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

    def flash_redirect(self, s, kind, msg, nxt):
        with LOCK:
            s[1]["flash"] = (kind, msg)
        self.redirect(nxt)

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
        err = "<div class='flash bad'>%s</div>" % esc(error) if error else ""
        body = ("<div class=auth><div class=authbox><div class='brand' style='justify-content:center'>%s"
                "<span class=logo>TURBO</span></div><div class='mut ctr'>Sign in to your server panel</div>%s"
                "<div class=card><form method=post action=/login>"
                "<label>Username</label><input type=text name=u autocomplete=username required>"
                "<label>Password</label><input type=password name=p autocomplete=current-password required>"
                "<button class='btn pri wide'>Sign in</button></form></div></div></div>" % (BOLT, err))
        self.out(200, page("TURBO Panel - Login", body))

    def dashboard(self, s):
        csrf = s[1]["csrf"]
        st, conf = stats(), bconf_load()
        mp = st["mem_used"] * 100 / st["mem_total"]
        dp = st["disk_used"] * 100 / st["disk_total"]
        cpu = st["load1"] * 100 / st["cores"]
        tiles = (tile("CPU load", "%.2f" % st["load1"], cpu, "%d cores · %s" % (st["cores"], st["load"]))
                 + tile("Memory", "%d%%" % mp, mp, "%s / %s" % (human(st["mem_used"]), human(st["mem_total"])))
                 + tile("Disk /", "%d%%" % dp, dp, "%s / %s" % (human(st["disk_used"]), human(st["disk_total"])))
                 + tile("Uptime", st["uptime"], None, st["os"]))
        bots = ""
        for n in BOTS:
            label, cls = bot_status(n, conf)
            bots += ("<div class=row><span><b>%s</b> <span class='pill %s'>%s</span></span><span class=acts>%s</span></div>"
                     % (esc(BOTS[n]["title"]), cls, esc(label), bot_controls(n, csrf, "/", conf)))
        bots += "<div class=row><a href='/bots'>Bot settings &rarr;</a></div>"
        rows = ""
        for n in SERVICES:
            state = svc_state(n)
            cls = "ok" if state == "active" else ("mut" if state in ("inactive", "unknown") else "bad")
            btn = abtn(csrf, "restart:" + n, "Restart", "sm", "/") if n in RESTARTABLE else ""
            rows += ("<div class=row><span><b>%s</b> <span class='pill %s'>%s</span></span>"
                     "<span class=acts><a class='btn ghost sm' href='/logs?svc=%s'>Logs</a>%s</span></div>"
                     % (esc(n), cls, esc(state), esc(n), btn))
        reboot = aform(csrf, "reboot", "<label style='display:inline'><input type=checkbox name=confirm value=yes required> "
                       "confirm reboot</label> <button class='btn dng sm'>Reboot server</button>", "/", "inline")
        body = ("<h1>%s</h1><div class=mut>%s</div><div class=grid>%s</div>"
                "<h2>Bots</h2><div class=card>%s</div><h2>Services</h2><div class=card>%s</div>"
                "<h2>Actions</h2><div class=card><div class=acts>%s %s <a class='btn ghost sm' href='/'>Refresh</a></div></div>"
                % (esc(st["host"]), esc(st["os"]), tiles, bots, rows,
                   abtn(csrf, "check_updates", "Check updates", "sm", "/"), reboot))
        users = users_load()
        user_rows = "".join("<div class=row><span>%s</span><span class=acts><form method=post action=/action class=inline><input type=hidden name=csrf value='%s'><input type=hidden name=act value='remove_user'><input type=hidden name=username value='%s'><button class='btn dng sm'>Remove</button></form></span></div>" % (esc(u), esc(csrf), esc(u)) for u in sorted(users)) or "<div class=mut>No users created.</div>"
        body += "<h2>User accounts</h2><div class=card><form method=post action=/action><input type=hidden name=csrf value='%s'><input type=hidden name=act value='create_user'>%s%s<button class='btn pri'>Create user</button></form>%s</div>" % (esc(csrf), field("Username", "new_user", "", "text", "e.g. botuser"), field("Password (min 10 characters)", "new_password", "", "password", ""), user_rows)
        self.out(200, layout(s, "TURBO Panel", body, "dash"))

    def bots_page(self, s):
        csrf, sid = s[1]["csrf"], s[0]
        conf = bconf_load()
        tg, ub = conf["tgbot"], conf["userbot"]
        # --- Telegram bot card
        lab, cls = bot_status("tgbot", conf)
        who = ("Token <code>%s</code>%s" % (esc(mask(tg["token"])), (" · @" + esc(tg["username"])) if tg.get("username") else "")
               if tg.get("token") else "No token yet")
        admins = ", ".join(str(x) for x in tg.get("admins", []))
        tgc = ("<h2>Telegram Bot</h2><div class=card><div class=row><span><span class='pill %s'>%s</span> &nbsp;<span class=mut>%s</span></span>"
               "<span class=acts>%s</span></div>" % (cls, esc(lab), who, bot_controls("tgbot", csrf, "/bots", conf)))
        tgc += aform(csrf, "tg_save", field("Bot token (from @BotFather)", "token", "", "password",
                                            "Leave empty to keep the current token")
                     + field("Admin Telegram IDs (comma separated)", "admins", admins, "text", "e.g. 123456789")
                     + "<button class='btn pri'>Save</button>")
        tgc += ("<div class=mut style='margin-top:10px;font-size:13px'>Start the bot, send <code>/id</code> to it to get your ID, "
                "then add that ID above as admin. Admins can use <code>/status /ip /services</code>.</div>")
        if tg.get("token"):
            tgc += "<div style='margin-top:10px'>%s</div>" % abtn(csrf, "tg_clear", "Remove token", "sm dng", "/bots")
        tgc += "</div>"
        # --- Userbot card
        lab, cls = bot_status("userbot", conf)
        tl = telethon_ok()
        who = ("Logged in: <b>%s</b>" % esc(ub.get("name") or ub.get("phone") or "session")) if ub.get("session") else "Not logged in"
        ubc = ("<h2>Userbot</h2><div class=card><div class=row><span><span class='pill %s'>%s</span> &nbsp;<span class=mut>%s</span></span>"
               "<span class=acts>%s</span></div>" % (cls, esc(lab), who, bot_controls("userbot", csrf, "/bots", conf)))
        if not tl:
            ubc += ("<div class='flash bad'>Telethon is not installed. In the terminal menu choose "
                    "14 &rarr; Install userbot support.</div>")
        ubc += ("<details %s><summary>API credentials (my.telegram.org)</summary>" % ("" if ub.get("api_id") else "open")
                + aform(csrf, "ub_save", field("API ID", "api_id", "", "text", ub.get("api_id") and mask(ub["api_id"], 2) or "e.g. 1234567")
                        + field("API hash", "api_hash", "", "password", ub.get("api_hash") and mask(ub["api_hash"], 3) or "32 characters")
                        + field("Session string (optional - skip it to log in with your phone)", "session", "", "password", "")
                        + "<button class='btn'>Save credentials</button>") + "</details>")
        lg = LOGINS.get(sid)
        if lg and time.time() - lg["t"] > 600:
            LOGINS.pop(sid, None)
            lg = None
        if ub.get("session"):
            ubc += "<div style='margin-top:8px'>%s</div>" % abtn(csrf, "ub_logout", "Log out account", "sm dng", "/bots")
        elif not (ub.get("api_id") and ub.get("api_hash")):
            ubc += "<div class=mut>Save API ID + hash first, then log in with your phone number.</div>"
        elif lg and lg["stage"] == "code":
            ubc += ("<h2>Enter login code</h2>" + aform(csrf, "ub_code", field("Code sent to %s" % lg["phone"], "code", "", "text", "12345")
                    + "<button class='btn pri'>Confirm</button>") + abtn(csrf, "ub_cancel", "Cancel", "ghost sm", "/bots"))
        elif lg and lg["stage"] == "2fa":
            ubc += ("<h2>Two-step password</h2>" + aform(csrf, "ub_2fa", field("Your Telegram 2FA password", "password", "", "password", "")
                    + "<button class='btn pri'>Log in</button>") + abtn(csrf, "ub_cancel", "Cancel", "ghost sm", "/bots"))
        else:
            ubc += ("<h2>Log in with phone</h2>" + aform(csrf, "ub_send", field("Phone number (with country code)", "phone", "", "text", "+959...")
                    + "<button class='btn pri'>Send code</button>"))
        ubc += "</div>"
        self.out(200, layout(s, "TURBO Panel - Bots", "<h1>Bots</h1><div class=mut>Run and manage your Telegram bot and userbot.</div>" + tgc + ubc, "bots"))

    def files_page(self, s, notice=""):
        username = s[1]["user"]
        csrf = s[1]["csrf"]
        rows = ""
        for name in app_list(username):
            running = app_running(username, name)
            status = "running" if running else "stopped"
            actions = (aform(csrf, "app:stop:" + name, "<button class='btn dng sm'>Stop</button>", "/files", "inline") if running else
                       aform(csrf, "app:start:" + name, "<button class='btn pri sm'>Run</button>", "/files", "inline"))
            actions += " <a class='btn ghost sm' href='/applog?n=%s'>Log</a>" % esc(name)
            rows += "<div class=row><span><b>%s</b> <span class='pill %s'>%s</span></span><span class=acts>%s</span></div>" % (esc(name), "ok" if running else "mut", status, actions)
        if not rows: rows = "<div class=mut>No uploaded .py or .js files yet.</div>"
        st = stats(); mp = st["mem_used"] * 100 / st["mem_total"]; dp = st["disk_used"] * 100 / st["disk_total"]
        tiles = tile("CPU load", "%.2f" % st["load1"], min(100, st["load1"] * 100 / st["cores"]), "%d cores" % st["cores"]) + tile("RAM", "%d%%" % mp, mp, "%s / %s" % (human(st["mem_used"]), human(st["mem_total"]))) + tile("Disk", "%d%%" % dp, dp, "%s / %s" % (human(st["disk_used"]), human(st["disk_total"])))
        body = "<h1>My Apps</h1><div class=mut>Logged in as %s. Python and JavaScript apps; allowed requirements install in a private virtual environment.</div><div class=grid>%s</div>" % (esc(username), tiles)
        body += "<h2>Upload bot file</h2><div class=card><form method=post action=/upload enctype='multipart/form-data'><input type=hidden name=csrf value='%s'><label>Bot file or requirements.txt (max 2 MB)</label><input type=file name=file accept='.py,.js,.txt' required><button class='btn pri'>Upload</button></form></div>" % esc(csrf)
        req = app_path(username, "requirements.txt")
        if req and os.path.isfile(req):
            body += "<h2>Dependencies</h2><div class=card><div class=mut>Blocked: opencv-python, numpy, ddddocr, aiohttp</div>%s</div>" % aform(csrf, "install_requirements", "<button class='btn pri'>Install allowed dependencies</button>", "/files", "inline")
        body += "<h2>Uploaded files</h2><div class=card>%s</div>" % rows
        return self.out(200, layout(s, "My Apps", body, "files"))

    def app_log(self, s, name):
        path = app_path(s[1]["user"], name)
        if not path: return self.out(404, layout(s, "Not found", "<p>Not found</p>"))
        return self.out(200, layout(s, "App log", "<h1>%s log</h1><pre>%s</pre><a class='btn' href='/files'>Back</a>" % (esc(name), esc(tail(path + ".log", 200))), "files"))

    # ----- routes -----
    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/login":
            return self.login_page()
        s = self.sess()
        if not s:
            return self.redirect("/login")
        q = parse_qs(u.query)
        if u.path == "/":
            return self.dashboard(s) if s[1].get("role") == "admin" else self.files_page(s)
        if u.path == "/files":
            return self.files_page(s)
        if u.path == "/applog":
            return self.app_log(s, q.get("n", [""])[0])
        if u.path == "/bots":
            if s[1].get("role") != "admin": return self.out(403, page("Forbidden", "<p>Admin only</p>"))
            return self.bots_page(s)
        if u.path == "/logs":
            if s[1].get("role") != "admin": return self.out(403, page("Forbidden", "<p>Admin only</p>"))
            svc = q.get("svc", [""])[0]
            if svc not in SERVICES:
                return self.out(404, layout(s, "Not found", "<p>Not found</p>"))
            log = run(["journalctl", "-u", svc, "-n", "100", "--no-pager"], 15)
            return self.out(200, layout(s, "Logs", "<h1>%s logs</h1><pre>%s</pre><a class='btn' href='/'>Back</a>" % (esc(svc), esc(log or "(empty)"))))
        if u.path == "/botlog":
            if s[1].get("role") != "admin": return self.out(403, page("Forbidden", "<p>Admin only</p>"))
            b = q.get("b", [""])[0]
            if b not in BOTS:
                return self.out(404, layout(s, "Not found", "<p>Not found</p>"))
            return self.out(200, layout(s, "Logs", "<h1>%s log</h1><pre>%s</pre><a class='btn' href='/bots'>Back</a> <a class='btn ghost' href='/botlog?b=%s'>Refresh</a>"
                                        % (esc(BOTS[b]["title"]), esc(tail(BOTS[b]["log"])), b), "bots"))
        self.out(404, layout(s, "Not found", "<p>Not found</p>"))

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/upload":
            s = self.sess()
            if not s: return self.redirect("/login")
            fn, data, fields = parse_upload(self)
            if fields.get("csrf") != s[1]["csrf"]:
                return self.out(403, layout(s, "Forbidden", "<p>Invalid CSRF token</p>", "files"))
            if isinstance(data, str): return self.out(400, layout(s, "Upload", "<p>%s</p><a class='btn' href='/files'>Back</a>" % esc(data), "files"))
            if not fn or (fn != "requirements.txt" and (os.path.splitext(fn)[1].lower() not in APP_EXTS or not APP_NAME.fullmatch(fn))):
                return self.out(400, layout(s, "Upload", "<p>Only safe .py or .js filenames are allowed.</p><a class='btn' href='/files'>Back</a>", "files"))
            path2 = app_path(s[1]["user"], fn)
            with open(path2, "wb") as f: f.write(data)
            os.chmod(path2, 0o700)
            return self.redirect("/files")
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
                LOGINS.pop(s[0], None)
            return self.redirect("/login", [("Set-Cookie", "sid=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict")])
        if path == "/action":
            return self.do_action(d, s)
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
        login_user, role = d.get("u", ""), ""
        ok_u = hmac.compare_digest(login_user.encode(), str(conf.get("user", "")).encode())
        ok_p = ok_u and hmac.compare_digest(hash_pw(d.get("p", ""), conf["salt"]), conf["hash"])
        if not ok_p:
            rec = users_load().get(login_user)
            if rec and rec.get("salt") and rec.get("hash"):
                ok_p = hmac.compare_digest(hash_pw(d.get("p", ""), rec["salt"]), rec["hash"])
                if ok_p: role = "user"
        else:
            role = "admin"
        if not ok_p:
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
            SESSIONS[tok] = {"exp": now + SESSION_TTL, "csrf": csrf, "user": login_user, "role": role}
        cookie = "sid=%s; Path=/; HttpOnly; SameSite=Strict; Max-Age=%d%s" % (
            tok, SESSION_TTL, "; Secure" if self.secure() else "")
        sys.stderr.write("LOGIN OK from %s\n" % ip)
        self.redirect("/", [("Set-Cookie", cookie)])

    def do_action(self, d, s):
        act = d.get("act", "")
        if act.startswith("app:"):
            if len(act.split(":")) != 3: return self.out(400, page("Bad request", "<p>Unknown app action</p>"))
            _, op, name = act.split(":", 2)
            if op == "start": ok_a, msg = app_start(s[1]["user"], name)
            elif op == "stop": app_stop(s[1]["user"], name); ok_a, msg = True, name + " stopped"
            else: return self.out(400, page("Bad request", "<p>Unknown app action</p>"))
            return self.flash_redirect(s, "ok" if ok_a else "bad", msg, "/files")
        if act == "install_requirements":
            ok_i, msg = install_requirements(s[1]["user"])
            return self.flash_redirect(s, "ok" if ok_i else "bad", msg, "/files")
        if s[1].get("role") != "admin": return self.out(403, page("Forbidden", "<p>Admin only</p>"))
        if act == "create_user":
            ok_u, msg = user_add(d.get("new_user", "").strip(), d.get("new_password", ""))
            return self.flash_redirect(s, "ok" if ok_u else "bad", msg, "/")
        if act == "remove_user":
            ok_u, msg = user_remove(d.get("username", ""))
            return self.flash_redirect(s, "ok" if ok_u else "bad", msg, "/")
        if act.split(":")[0] in ("bot", "tg_save", "tg_clear", "ub_save", "ub_send", "ub_code", "ub_2fa", "ub_cancel", "ub_logout"):
            return self.bot_action(act, d, s)
        if act.startswith("restart:") and act[8:] in RESTARTABLE:
            name = act[8:]
            cmd = ["systemctl", "restart", name] if HAS_SYSTEMD else ["service", name, "restart"]
            out = run(cmd, 60) or "Restart command sent."
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
        self.out(200, layout(s, "Result", "<h1>Result</h1><pre>%s</pre><a class='btn' href='/'>Back</a>" % esc(out)))

    def bot_action(self, act, d, s):
        nxt = d.get("next") if d.get("next") in ("/", "/bots") else "/bots"
        sid = s[0]

        def done(ok, msg):
            return self.flash_redirect(s, "ok" if ok else "bad", msg, nxt)

        parts = act.split(":")
        if parts[0] == "bot":
            if len(parts) != 3 or parts[2] not in BOTS or parts[1] not in ("start", "stop", "restart"):
                return self.out(400, page("Bad request", "<p>Unknown action</p>"))
            name, title = parts[2], BOTS[parts[2]]["title"]
            if parts[1] == "stop":
                bot_stop(name)
                return done(True, "%s stopped" % title)
            ok, m = bot_start(name) if parts[1] == "start" else bot_restart(name)
            return done(ok, "%s: %s" % (title, m))

        conf = bconf_load()
        tg, ub = conf["tgbot"], conf["userbot"]
        if act == "tg_save":
            token, admins = d.get("token", "").strip(), parse_admins(d.get("admins", ""))
            if admins is None:
                return done(False, "Admin IDs must be numbers separated by commas")
            upd, note = {"admins": admins}, ""
            if token:
                if not re.fullmatch(r"\d{5,12}:[A-Za-z0-9_-]{30,60}", token):
                    return done(False, "That does not look like a bot token")
                uname, err, fatal = tg_getme(token)
                if fatal:
                    return done(False, err)
                upd.update(token=token, username=uname or None)
                note = " (@%s)" % uname if uname else " - " + err
            bconf_update("tgbot", **upd)
            if token and bot_running("tgbot"):
                bot_restart("tgbot")
            return done(True, "Saved" + note)
        if act == "tg_clear":
            bot_stop("tgbot")
            bconf_update("tgbot", token=None, username=None)
            return done(True, "Token removed")
        if act == "ub_save":
            api_id = d.get("api_id", "").strip() or str(ub.get("api_id") or "")
            api_hash = d.get("api_hash", "").strip().lower() or ub.get("api_hash") or ""
            sess = d.get("session", "").strip()
            if not re.fullmatch(r"\d{3,12}", api_id) or not re.fullmatch(r"[0-9a-f]{32}", api_hash):
                return done(False, "API ID (digits) and API hash (32 hex characters) are required")
            if sess and not re.fullmatch(r"[A-Za-z0-9_=+/\-]{40,2000}", sess):
                return done(False, "That does not look like a Telethon session string")
            upd = {"api_id": api_id, "api_hash": api_hash}
            if sess:
                upd.update(session=sess, name="(session string)")
            bconf_update("userbot", **upd)
            if sess and bot_running("userbot"):
                bot_restart("userbot")
            return done(True, "Credentials saved")
        if act == "ub_send":
            if not (ub.get("api_id") and ub.get("api_hash")):
                return done(False, "Save API ID and API hash first")
            phone = re.sub(r"[\s\-()]", "", d.get("phone", ""))
            phone = phone if phone.startswith("+") else "+" + phone
            if not re.fullmatch(r"\+\d{6,15}", phone):
                return done(False, "Invalid phone number")
            res = ub_helper("--login-send", {"api_id": int(ub["api_id"]), "api_hash": ub["api_hash"], "phone": phone})
            if not res.get("ok"):
                return done(False, res.get("error", "Could not send the code"))
            with LOCK:
                LOGINS[sid] = {"phone": phone, "hash": res["hash"], "session": res["session"], "stage": "code", "t": time.time()}
            return done(True, "Code sent - check your Telegram app (or SMS)")
        if act in ("ub_code", "ub_2fa"):
            lg = LOGINS.get(sid)
            if not lg or time.time() - lg["t"] > 600:
                return done(False, "Login expired - request a new code")
            payload = {"api_id": int(ub["api_id"]), "api_hash": ub["api_hash"], "phone": lg["phone"],
                       "hash": lg["hash"], "session": lg["session"]}
            if act == "ub_code":
                payload["code"] = re.sub(r"\D", "", d.get("code", ""))
                if not 4 <= len(payload["code"]) <= 8:
                    return done(False, "Enter the numeric code")
                res = ub_helper("--login-code", payload)
            else:
                payload["password"] = d.get("password", "")
                res = ub_helper("--login-2fa", payload)
            if res.get("ok"):
                bconf_update("userbot", session=res["session"], phone=lg["phone"], name=res.get("name") or lg["phone"])
                with LOCK:
                    LOGINS.pop(sid, None)
                return done(True, "Logged in as %s - press Start" % (res.get("name") or lg["phone"]))
            if res.get("need_2fa"):
                with LOCK:
                    lg.update(stage="2fa", session=res["session"])
                return done(True, "This account has two-step verification - enter your password")
            if "expired" in res.get("error", "").lower():
                with LOCK:
                    LOGINS.pop(sid, None)
            return done(False, res.get("error", "Login failed"))
        if act == "ub_cancel":
            with LOCK:
                LOGINS.pop(sid, None)
            return done(True, "Cancelled")
        if act == "ub_logout":
            bot_stop("userbot")
            if ub.get("session") and ub.get("api_id") and ub.get("api_hash"):
                ub_helper("--logout", {"api_id": int(ub["api_id"]), "api_hash": ub["api_hash"], "session": ub["session"]}, 25)
            bconf_update("userbot", session=None, name=None, phone=None)
            return done(True, "Logged out")
        return self.out(400, page("Bad request", "<p>Unknown action</p>"))


def cli_bots_status():
    conf = bconf_load()
    for n, info in BOTS.items():
        pid = read_pid(n)
        state = "running (pid %d)" % pid if pid and pid_ok(pid, n) else "stopped"
        print("%-13s %s%s" % (info["title"], state, "" if configured(n, conf[n]) else "  [not set up]"))
    print("Telethon      %s" % ("installed" if telethon_ok() else "not installed"))


def main():
    a = sys.argv
    if len(a) >= 3 and a[1] == "--set-password":
        return cli_set_password(a[2])
    if len(a) >= 3 and a[1] == "--set-port":
        return cli_set_port(a[2])
    if len(a) >= 2 and a[1] == "--bots-status":
        return cli_bots_status()
    if len(a) >= 2 and a[1] == "--bots-stop":
        for n in BOTS:
            bot_stop(n, disable=False)
        return
    conf = load_conf()
    if "hash" not in conf:
        print("No password configured. Run the panel menu to set one.")
        sys.exit(1)
    threading.Thread(target=watchdog, daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", int(conf.get("port", 8080))), H)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
PYEOF
  chmod 700 "$WP_APP"
  wp_write_bot tgbot.py <<'TGEOF'
#!/usr/bin/env python3
# TURBO-BUILTIN  (delete this marker line if you replace this file with your own bot - updates will then leave it alone)
"""TURBO Telegram bot: plain Bot API long polling, standard library only."""
import html, json, os, shutil, signal, subprocess, sys, time
import urllib.error, urllib.parse, urllib.request

CONF = os.environ.get("TURBO_BOTS_CONF", "/etc/vps-webpanel/bots.json")
SERVICES = ["cloudflared", "nginx", "docker", "ssh", "ufw", "fail2ban"]
PROCS = {"cloudflared": "cloudflared", "nginx": "nginx", "docker": "dockerd", "ssh": "sshd", "fail2ban": "fail2ban-server"}
TOKEN = ""


def log(*a):
    msg = " ".join(str(x) for x in a)
    if TOKEN:
        msg = msg.replace(TOKEN, "***")
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, flush=True)


def load():
    try:
        with open(CONF) as f:
            return json.load(f).get("tgbot", {})
    except Exception:
        return {}


def api(method, params=None, timeout=15):
    data = urllib.parse.urlencode(params or {}).encode()
    req = urllib.request.Request("https://api.telegram.org/bot%s/%s" % (TOKEN, method), data=data)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def send(chat, text):
    try:
        api("sendMessage", {"chat_id": chat, "text": text, "parse_mode": "HTML", "disable_web_page_preview": "true"})
    except Exception as e:
        log("send failed:", e.__class__.__name__, e)


def human(n):
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return "%.1f %s" % (n, u)
        n /= 1024.0
    return "%.1f PB" % n


def sysinfo():
    mem = {}
    for line in open("/proc/meminfo"):
        k, v = line.split(":", 1)
        mem[k] = int(v.split()[0]) * 1024
    total = mem["MemTotal"]
    used = total - mem.get("MemAvailable", mem.get("MemFree", 0))
    du = shutil.disk_usage("/")
    up = int(float(open("/proc/uptime").read().split()[0]))
    load_ = " ".join(open("/proc/loadavg").read().split()[:3])
    return ("⚡ <b>%s</b>\n🕒 Up: %dd %dh %dm\n📈 Load: %s (%d cores)\n🧠 RAM: %s / %s (%d%%)\n💾 Disk: %s / %s (%d%%)"
            % (html.escape(os.uname().nodename), up // 86400, up % 86400 // 3600, up % 3600 // 60, load_, os.cpu_count() or 1,
               human(used), human(total), used * 100 // total, human(du.used), human(du.total), du.used * 100 // du.total))


def svc_state(name):
    try:
        if os.path.isdir("/run/systemd/system"):
            return subprocess.run(["systemctl", "is-active", name], capture_output=True, text=True, timeout=5).stdout.strip() or "unknown"
        proc = PROCS.get(name)
        return "unknown" if not proc else ("active" if subprocess.run(["pgrep", "-x", proc], capture_output=True, timeout=5).returncode == 0 else "inactive")
    except Exception:
        return "unknown"


def public_ip():
    try:
        with urllib.request.urlopen("https://api.ipify.org", timeout=6) as r:
            return r.read().decode().strip()
    except Exception:
        return "N/A"


HELP = ("⚡ <b>TURBO bot</b>\n\n/id - show your Telegram ID\n/ping - check the bot\n"
        "\n<b>Admin only</b>\n/status - server status\n/ip - public IP\n/services - service states")


def handle(msg):
    text = (msg.get("text") or "").strip()
    if not text.startswith("/"):
        return
    cmd = text.split()[0].split("@")[0].lower()
    uid = (msg.get("from") or {}).get("id")
    chat = msg["chat"]["id"]
    if cmd in ("/start", "/help"):
        send(chat, HELP)
    elif cmd == "/id":
        send(chat, "Your ID: <code>%s</code>\nChat ID: <code>%s</code>" % (uid, chat))
    elif cmd == "/ping":
        send(chat, "🏓 pong")
    elif cmd in ("/status", "/ip", "/services"):
        admins = [int(x) for x in load().get("admins", [])]
        if uid not in admins:
            return send(chat, "⛔ Not authorized. Ask the owner to add your ID (<code>%s</code>) in the TURBO panel." % uid)
        if cmd == "/status":
            send(chat, sysinfo())
        elif cmd == "/ip":
            send(chat, "🌐 <code>%s</code>" % public_ip())
        else:
            lines = []
            for n in SERVICES:
                st = svc_state(n)
                lines.append("%s <b>%s</b>: %s" % ("🟢" if st == "active" else "⚪", n, st))
            send(chat, "\n".join(lines))


def main():
    global TOKEN
    TOKEN = load().get("token", "")
    if not TOKEN:
        log("No bot token configured")
        sys.exit(3)
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
    try:
        me = api("getMe")["result"]
    except urllib.error.HTTPError as e:
        log("getMe failed: HTTP", e.code)
        sys.exit(3 if e.code in (401, 404) else 1)
    except Exception as e:
        log("getMe failed:", e.__class__.__name__)
        sys.exit(1)
    log("TURBO bot started as @%s" % me.get("username"))
    offset, fails = None, 0
    while True:
        try:
            params = {"timeout": 25, "allowed_updates": json.dumps(["message"])}
            if offset:
                params["offset"] = offset
            for u in api("getUpdates", params, timeout=35).get("result", []):
                offset = u["update_id"] + 1
                if "message" in u:
                    try:
                        handle(u["message"])
                    except Exception as e:
                        log("handler error:", repr(e))
            fails = 0
        except urllib.error.HTTPError as e:
            if e.code in (401, 404):
                log("Token was revoked")
                sys.exit(3)
            fails += 1
            log("poll error: HTTP", e.code)
            time.sleep(min(30, 2 * fails))
        except Exception as e:
            fails += 1
            log("poll error:", e.__class__.__name__)
            time.sleep(min(30, 2 * fails))


if __name__ == "__main__":
    main()
TGEOF
  wp_write_bot userbot.py <<'UBEOF'
#!/usr/bin/env python3
# TURBO-BUILTIN  (delete this marker line if you replace this file with your own userbot - updates will then leave it alone)
"""TURBO userbot (Telethon). Modes: --run (default), and JSON-over-stdin login helpers used by the web panel."""
import asyncio, html, json, os, shutil, sys, time

CONF = os.environ.get("TURBO_BOTS_CONF", "/etc/vps-webpanel/bots.json")
NO_TELETHON = "Telethon is not installed - use terminal menu 14 > Install userbot support"


def log(*a):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), *a, flush=True)


def load():
    try:
        with open(CONF) as f:
            return json.load(f).get("userbot", {})
    except Exception:
        return {}


def friendly(e):
    n = type(e).__name__
    msgs = {"PhoneNumberInvalidError": "Invalid phone number", "ApiIdInvalidError": "Invalid API ID / API hash",
            "PhoneCodeInvalidError": "Wrong code", "PhoneCodeExpiredError": "Code expired - request a new one",
            "PasswordHashInvalidError": "Wrong 2FA password", "PhoneNumberBannedError": "This phone number is banned",
            "PhoneNumberFloodError": "Too many attempts - try again later", "AuthKeyUnregisteredError": "Session is no longer valid"}
    if n == "FloodWaitError":
        return "Too many attempts - wait %s seconds" % getattr(e, "seconds", "a while")
    return msgs.get(n, "%s: %s" % (n, str(e)[:120]))


def human(n):
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return "%.1f %s" % (n, u)
        n /= 1024.0
    return "%.1f PB" % n


def sysinfo():
    mem = {}
    for line in open("/proc/meminfo"):
        k, v = line.split(":", 1)
        mem[k] = int(v.split()[0]) * 1024
    total = mem["MemTotal"]
    used = total - mem.get("MemAvailable", mem.get("MemFree", 0))
    du = shutil.disk_usage("/")
    up = int(float(open("/proc/uptime").read().split()[0]))
    return ("⚡ <b>%s</b>\nUp: %dd %dh %dm\nLoad: %s\nRAM: %s / %s (%d%%)\nDisk: %s / %s (%d%%)"
            % (html.escape(os.uname().nodename), up // 86400, up % 86400 // 3600, up % 3600 // 60,
               " ".join(open("/proc/loadavg").read().split()[:3]), human(used), human(total), used * 100 // total,
               human(du.used), human(du.total), du.used * 100 // du.total))


# ---------- login helpers (stdin JSON -> stdout JSON) ----------
def client_for(d, session=""):
    from telethon import TelegramClient
    from telethon.sessions import StringSession
    return TelegramClient(StringSession(session), int(d["api_id"]), d["api_hash"])


async def display_name(c):
    me = await c.get_me()
    return " ".join(x for x in (me.first_name, me.last_name) if x) or me.username or str(me.id)


async def login_send(d):
    c = client_for(d)
    await c.connect()
    try:
        sent = await c.send_code_request(d["phone"])
        return {"ok": True, "hash": sent.phone_code_hash, "session": c.session.save()}
    finally:
        await c.disconnect()


async def login_code(d):
    from telethon.errors import SessionPasswordNeededError
    c = client_for(d, d["session"])
    await c.connect()
    try:
        try:
            await c.sign_in(phone=d["phone"], code=d["code"], phone_code_hash=d["hash"])
        except SessionPasswordNeededError:
            return {"ok": False, "need_2fa": True, "session": c.session.save()}
        return {"ok": True, "session": c.session.save(), "name": await display_name(c)}
    finally:
        await c.disconnect()


async def login_2fa(d):
    c = client_for(d, d["session"])
    await c.connect()
    try:
        await c.sign_in(password=d["password"])
        return {"ok": True, "session": c.session.save(), "name": await display_name(c)}
    finally:
        await c.disconnect()


async def logout(d):
    c = client_for(d, d["session"])
    await c.connect()
    try:
        await c.log_out()
    finally:
        await c.disconnect()
    return {"ok": True}


# ---------- the userbot itself ----------
def run_bot():
    c = load()
    try:
        from telethon import events
    except ImportError:
        log(NO_TELETHON)
        sys.exit(3)
    if not (c.get("api_id") and c.get("api_hash") and c.get("session")):
        log("Userbot is not logged in")
        sys.exit(3)

    async def amain():
        client = client_for(c, c["session"])
        await client.connect()
        if not await client.is_user_authorized():
            log("Session is no longer valid - log in again from the panel")
            sys.exit(3)
        name = await display_name(client)

        @client.on(events.NewMessage(outgoing=True, pattern=r"(?i)^\.(ping|alive|id|status|help)\s*$"))
        async def on_cmd(ev):
            cmd = ev.raw_text.strip().lower().lstrip(".")
            if cmd == "ping":
                t = time.time()
                await ev.edit("🏓 ...")
                await ev.edit("🏓 Pong! <b>%d ms</b>" % ((time.time() - t) * 1000), parse_mode="html")
            elif cmd == "alive":
                await ev.edit("⚡ <b>TURBO userbot</b> is alive", parse_mode="html")
            elif cmd == "id":
                r = await ev.get_reply_message()
                txt = "Chat ID: <code>%s</code>" % ev.chat_id
                if r is not None:
                    txt += "\nUser ID: <code>%s</code>" % r.sender_id
                await ev.edit(txt, parse_mode="html")
            elif cmd == "status":
                await ev.edit(sysinfo(), parse_mode="html")
            else:
                await ev.edit("⚡ <b>TURBO userbot</b>\n<code>.ping .alive .id .status .help</code>", parse_mode="html")

        log("TURBO userbot running as", name)
        await client.run_until_disconnected()

    asyncio.run(amain())


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--run"
    if mode == "--run":
        return run_bot()
    fns = {"--login-send": login_send, "--login-code": login_code, "--login-2fa": login_2fa, "--logout": logout}
    try:
        res = asyncio.run(fns[mode](json.loads(sys.stdin.read() or "{}")))
    except ImportError:
        res = {"ok": False, "error": NO_TELETHON}
    except Exception as e:
        res = {"ok": False, "error": friendly(e)}
    print(json.dumps(res))


if __name__ == "__main__":
    main()
UBEOF
}

# Telethon (userbot engine) lives in its own virtualenv so it never touches system Python.
wp_install_userbot_deps() {
  warn "Use the web panel requirements.txt installer for allowed packages."
  warn "Blocked: opencv-python, numpy, ddddocr, aiohttp; transitive matches are refused too."
  return 1
}

wp_set_password() {
  local u pw1 pw2
  read -rp "  Admin username [admin]: " u; u=${u:-admin}
  if [[ ! $u =~ ^[A-Za-z0-9_.-]{3,32}$ ]]; then err "Invalid username (3-32 chars: letters, digits, _ . -)"; return 1; fi
  read -rsp "  Password (min 10 characters): " pw1; echo
  read -rsp "  Repeat password: " pw2; echo
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
  title "TURBO Web Panel · Install"
  command -v python3 >/dev/null || spin_run "Installing python3" apt-get install -y python3
  command -v curl >/dev/null || spin_run "Installing curl" apt-get install -y curl
  command -v pgrep >/dev/null || { apt-get update -y >/dev/null 2>&1; spin_run "Installing procps" apt-get install -y procps; }
  wp_stop
  wp_write_app
  ok "Panel files written"

  local port def ub
  def=$(wp_pick_port)
  read -rp "  Panel port (listens on localhost only) [$def]: " port; port=${port:-$def}
  if [[ ! $port =~ ^[0-9]+$ ]] || (( port<1024 || port>65535 )); then err "Invalid port"; pause; return; fi
  if port_in_use "$port"; then err "Port $port is already used by another program. Choose a different port."; pause; return; fi
  python3 "$WP_APP" --set-port "$port" || { pause; return; }

  wp_set_password || { pause; return; }

  warn "Only allowed requirements are installed. Blocked: opencv-python, numpy, ddddocr, aiohttp."

  if have_systemd; then
  cat > /etc/systemd/system/${WP_SVC}.service <<EOF
[Unit]
Description=TURBO Web Panel
After=network.target

[Service]
ExecStart=$(command -v python3) $WP_APP
Restart=always
RestartSec=3
# keep the bots running when only the panel restarts (the panel re-adopts them)
KillMode=process
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
    have_systemd || info "It keeps running after you close this terminal."
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
  echo -e "  ${BOLD}Connect your domain via Cloudflare Tunnel${NC}"
  echo -e "  ${CYAN}1${NC} Zero Trust › Networks › Tunnels › (your tunnel) › Edit"
  echo -e "  ${CYAN}2${NC} Published application / Public hostname › Add"
  echo -e "      ${GREY}Subdomain${NC} : panel   ${GREY}(example)${NC}"
  echo -e "      ${GREY}Domain   ${NC} : choose your domain"
  echo -e "      ${GREY}Type     ${NC} : HTTP"
  echo -e "      ${GREY}URL      ${NC} : ${BOLD}localhost:${port}${NC}"
  echo -e "  ${CYAN}3${NC} Save, then open https://panel.yourdomain.com"
  echo
  echo -e "  ${YELLOW}Security tip:${NC} In Zero Trust › Access › Applications,"
  echo "  add an Access policy (email OTP / Google login) for this hostname."
  echo "  Cloudflare will then verify visitors before they reach the panel login."
  if [[ $(cf_state) != active ]]; then
    echo
    warn "cloudflared is not running. Connect your Tunnel token first via menu 13."
  fi
}

wp_menu() {
  while true; do
    header
    title "TURBO Web Panel + Bots"
    if wp_installed; then
      local st
      st=$(wp_state)
      [[ $st == active ]] && st="${GREEN}running${NC}" || st="${RED}${st:-stopped}${NC}"
      echo -e "  Status: $st   ${GREY}Local: http://127.0.0.1:$(wp_port)${NC}"
    else
      echo -e "  Status: ${YELLOW}not installed${NC}"
    fi
    echo
    opt 1 "Install / Reinstall"
    opt 2 "Show status"
    opt 3 "Change admin password"
    opt 4 "Restart"
    opt 5 "Show logs (includes login attempts)"
    opt 6 "Cloudflare Tunnel setup help"
    opt 7 "Update panel code (keeps config)"
    opt 8 "Install userbot support (Telethon)"
    opt 9 "Bots status"
    opt 10 "Uninstall"
    opt 0 "Back"
    echo
    read -rp "$PROMPT" c
    case $c in
      1) wp_install ;;
      2) wp_status; pause ;;
      3) if wp_installed; then wp_set_password && wp_restart && ok "All sessions have been logged out"; else err "Install the panel first"; fi; pause ;;
      4) wp_restart; ok "Restarted"; pause ;;
      5) wp_logs; pause ;;
      6) wp_tunnel_help; pause ;;
      7) if wp_installed; then wp_write_app && wp_restart && ok "Updated"; else err "Install the panel first"; fi; pause ;;
      8) warn "Use the web panel requirements.txt installer. Blocked packages are never installed."; pause ;;
      9) if wp_installed; then echo; python3 "$WP_APP" --bots-status | sed 's/^/  /'; else err "Install the panel first"; fi; pause ;;
      10)
        read -rp "  Remove web panel and bots (config + sessions are deleted)? (yes/no): " a
        if [[ $a == yes ]]; then
          wp_installed && python3 "$WP_APP" --bots-stop
          wp_stop
          if have_systemd; then
            systemctl disable "$WP_SVC" 2>/dev/null
            rm -f /etc/systemd/system/${WP_SVC}.service
            systemctl daemon-reload
          fi
          rm -rf "$WP_DIR" /etc/vps-webpanel "$WP_LOG" /var/log/turbo-tgbot.log* /var/log/turbo-userbot.log*
          ok "Removed. Also delete the hostname in the Cloudflare Dashboard."
        fi
        pause ;;
      0) return ;;
      *) err "Invalid choice"; sleep 1 ;;
    esac
  done
}

# ---------- Main menu ----------
MENU=(
  "System Info" "System Update" "Basic Tools" "Firewall (UFW)" "SSH & Users" "Nginx + SSL" "Docker Install"
  "Swap Setup" "Backup" "Monitor" "Network Check" "Reboot" "Cloudflare Tunnel" "Web Panel + Bots"
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

printf "  ${GREY}Loading TURBO…${NC}\r"
get_ip
main_menu
