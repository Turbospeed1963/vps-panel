#!/usr/bin/env python3
# =====================================================
#  TURBO CHANNEL - Userbot Web Panel · V 2.6
#  Developer: TURBO   ·   Telegram: https://t.me/arsar2027
#
#  - Access-key login (no passwords). Admin issues keys; shown once.
#  - Coins: 2 coin = 1 day · keys carry an expiry · renew with coins
#  - Users see only their own bots, logs and files; admin sees everything
#  - Quota per user: RAM 256 MB · CPU 0.5 core · Disk 1024 MB
#      HARD via cgroup v2 when available, otherwise SOFT (watchdog)
#  - Every bot runs as its own OS user (tbpb_<id>)
#  - Scanner: 3 hosting/malware violations = automatic ban
#  - Telegram bot lives in tbp_bot.py (separate process). This app only
#    exposes a LOCAL /internal API, protected by a shared secret.
#  - POLICY: opencv-python*, numpy, ddddocr are NEVER installed
#  Listens on 127.0.0.1 only. Publish via Cloudflare Tunnel.
#
#  CLI:
#    sudo python3 app.py --set-password admin        # admin key (shown once)
#    echo "<TOKEN>" | sudo python3 app.py --bot-token  # stored in config.json
#    sudo python3 app.py --bot-admin <tg_id>
#    sudo python3 app.py --bot-channel @arsar2027
#    sudo python3 app.py --panel-url https://panel.example.com
#    sudo python3 app.py --ref-reward 2
#    sudo python3 app.py --bot-status
#    sudo python3 app.py                             # run panel
# =====================================================
import ast, getpass, hashlib, hmac, html, json, os, pwd, re, resource, secrets, shutil, signal, subprocess, sys, threading, time, traceback
from http.cookies import CookieError, SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

VERSION = "2.6"
PANEL_NAME = "TURBO CHANNEL"
DEVELOPER = "TURBO"
TG_HANDLE = "@arsar2027"
TG_URL = "https://t.me/arsar2027"

HOME = os.environ.get("TBP_HOME", "/opt/tb-panel")
CONF = os.path.join(HOME, "config.json")
BOTS = os.path.join(HOME, "bots")
PORT = int(os.environ.get("TBP_PORT", "8787"))
MB = 1024 * 1024
DAY = 86400
COIN_PER_DAY = 2
DAY_OPTIONS = (1, 3, 7)
KEY_COOLDOWN = DAY              # non-admin users: one key issue per 24 h
QUOTA_RAM_MB = 256
QUOTA_CPU = 0.5
QUOTA_DISK_MB = 1024
STRIKE_LIMIT = 3
MAX_UPLOAD = 2 * MB
SESSION_TTL = 8 * 3600
MAX_FAILS, LOCK_SECS = 5, 300
MAX_RESTARTS = 5
CG_ROOT = "/sys/fs/cgroup"
CG_BASE = os.path.join(CG_ROOT, "tbp")
IS_ROOT = os.geteuid() == 0

SESSIONS, FAILS, PROCS = {}, {}, {}
LOCK = threading.RLock()

# ---- policy: never installed ----
BLOCK_EXACT = {"numpy", "ddddocr"}
BLOCK_PREFIX = ("opencv",)
CONSTRAINTS = "\n".join(["numpy<0", "ddddocr<0", "opencv-python<0", "opencv-python-headless<0",
                         "opencv-contrib-python<0", "opencv-contrib-python-headless<0"]) + "\n"

PY_MAP = {"cv2": "opencv-python", "PIL": "pillow", "bs4": "beautifulsoup4", "dotenv": "python-dotenv",
          "yaml": "pyyaml", "socks": "pysocks", "nacl": "pynacl", "dateutil": "python-dateutil",
          "telegram": "python-telegram-bot"}
BANNED_PY_MODULES = {"pty", "telnetlib", "sh"}
BANNED_JS_MODULES = {"child_process", "node:child_process"}
NODE_BUILTIN = {"assert", "buffer", "child_process", "cluster", "console", "constants", "crypto", "dgram",
                "diagnostics_channel", "dns", "domain", "events", "fs", "http", "http2", "https", "inspector",
                "module", "net", "os", "path", "perf_hooks", "process", "punycode", "querystring", "readline",
                "repl", "stream", "string_decoder", "sys", "timers", "tls", "trace_events", "tty", "url", "util",
                "v8", "vm", "wasi", "worker_threads", "zlib"}
JS_RE = [re.compile(r"""require\(\s*['"]([^'"]+)['"]\s*\)"""),
         re.compile(r"""\bfrom\s+['"]([^'"]+)['"]"""),
         re.compile(r"""\bimport\s*\(\s*['"]([^'"]+)['"]\s*\)"""),
         re.compile(r"""^\s*import\s+['"]([^'"]+)['"]""", re.M)]
PKG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
BID_RE = r"[0-9a-f]{12}"
NAME_RE = re.compile(r"[a-z0-9_.-]{3,32}")
KEY_RE = re.compile(r"tbp_([0-9a-f]{8})\.([A-Za-z0-9_-]{40,64})")
TOKEN_RE = re.compile(r"\d{5,12}:[A-Za-z0-9_-]{30,60}")
CHANNEL_RE = re.compile(r"@[A-Za-z][A-Za-z0-9_]{4,}")

# ---- code scanner rules: (category, regex), checked line by line ----
RULES = [
    ("hosting", r"\b(tb-panel|vps-panel|vps-webpanel|TBP_HOME|TBP_PORT|config\.json|meta\.json)\b|/opt/(tb-panel|vps-webpanel)"),
    ("hosting", r"\bbots/|\bbot\.log\b"),
    ("hosting", r"\b(systemctl|journalctl|cloudflared|iptables|nginx|sshd|ufw)\b|/etc/(shadow|sudoers|passwd|ssh/|tbp/)"),
    ("hosting", r"\b(subprocess|os\.system|os\.popen|os\.spawn\w*|Popen|check_output|check_call|child_process|execSync|execFile|spawn|nohup|setsid)\b.*\b(python3?|node|npm|npx|bash|sh|nohup|setsid)\b"),
    ("malware", r"/dev/(tcp|udp)/|\bbash\s+-i\b|\b(nc|ncat|netcat|socat)\b.*\s-(e|c)\b|\bmkfifo\b"),
    ("malware", r"\brm\s+-rf\s+/(\s|$|\*)|\bmkfs(\.\w+)?\b|\bdd\s+if=|:\(\)\s*\{"),
    ("malware", r"xmrig|stratum\+|minexmr|nanopool|nicehash|cryptonight|coinhive"),
    ("malware", r"\b(curl|wget)\b[^|\n]*\|\s*(sudo\s+)?(sh|bash)\b"),
    ("malware", r"\b(exec|eval)\s*\(.*(b64decode|base64|zlib\.decompress|marshal\.loads|codecs\.decode|fromhex|atob\(|Buffer\.from)"),
    ("malware", r"\bchmod\s+(\+s|u\+s)\b"),
]
RULES_C = [(cat, re.compile(rx, re.I)) for cat, rx in RULES]


# =====================================================
#  Small helpers
# =====================================================
def esc(s):
    return html.escape(str(s), quote=True)


def pct(a, b):
    return max(0, min(100, int(a * 100 / b))) if b else 0


def human(n):
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return "%.1f %s" % (n, u)
        n /= 1024.0
    return "%.1f PB" % n


def fmt_time(ts):
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(ts or 0))


def run_cmd(cmd, cwd=None, timeout=900):
    try:
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL,
                           env=dict(os.environ, DEBIAN_FRONTEND="noninteractive", PIP_NO_INPUT="1"))
        return r.returncode, (r.stdout + r.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, "Timed out"
    except FileNotFoundError:
        return 127, "Command not found: %s" % cmd[0]


def read_json(p, default):
    try:
        with open(p, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, type(default)) else default
    except Exception:
        return default


def write_json(p, obj):
    os.makedirs(os.path.dirname(p), mode=0o700, exist_ok=True)
    tmp = p + ".tmp"
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False)
    os.replace(tmp, p)


def read_text(p):
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.read()


def read_file(p, default=""):
    try:
        with open(p) as f:
            return f.read()
    except OSError:
        return default


def _write(p, s):
    with open(p, "w") as f:
        f.write(s)


# =====================================================
#  Config, accounts, keys, coins
# =====================================================
def conf_load():
    return read_json(CONF, {})


def users_load():
    conf = conf_load()
    users = conf.get("users")
    if isinstance(users, dict):
        return users
    if conf.get("user"):
        return {conf["user"]: new_record("admin")}
    return {}


def users_mutate(fn):
    """Atomic read-modify-write of config.json (users + bot settings live together)."""
    with LOCK:
        conf = conf_load()
        users = conf.get("users")
        if not isinstance(users, dict):
            users = users_load()
        res = fn(users)
        conf["users"] = users
        write_json(CONF, conf)
        return res


def bot_cfg():
    b = conf_load().get("bot")
    return b if isinstance(b, dict) else {}


def bot_cfg_update(**kw):
    with LOCK:
        conf = conf_load()
        b = conf.get("bot") if isinstance(conf.get("bot"), dict) else {}
        for k, v in kw.items():
            if v is None:
                b.pop(k, None)
            else:
                b[k] = v
        conf["bot"] = b
        write_json(CONF, conf)


def ensure_internal_secret():
    if not bot_cfg().get("internal_secret"):
        bot_cfg_update(internal_secret=secrets.token_urlsafe(32))


def key_digest(secret):
    return hashlib.sha256(secret.encode("utf-8")).hexdigest()


def issue_key(rec):
    kid = secrets.token_hex(4)
    secret = secrets.token_urlsafe(32)
    rec.pop("salt", None)
    rec.pop("hash", None)
    rec.update(key_id=kid, key_hash=key_digest(secret), key_issued_at=time.time())
    return "tbp_%s.%s" % (kid, secret)


def find_by_key(users, key):
    m = KEY_RE.fullmatch((key or "").strip())
    if not m:
        return None, None
    kid, secret = m.group(1), m.group(2)
    digest = key_digest(secret)
    for name, rec in users.items():
        if rec.get("key_id") == kid and hmac.compare_digest(digest, rec.get("key_hash", "")):
            return name, rec
    return None, None


def has_key(rec):
    return bool(rec.get("key_id") and rec.get("key_hash"))


def key_wait_left(rec):
    """Seconds left before a non-admin user may issue a new key. 0 = allowed now."""
    if rec.get("role") == "admin":
        return 0
    last = float(rec.get("key_issued_at") or 0)
    return max(0, int(last + KEY_COOLDOWN - time.time()))


def fmt_wait(sec):
    mins = max(1, (int(sec) + 59) // 60)
    h, m = divmod(mins, 60)
    return "%dh %dm" % (h, m) if h else "%d min" % m


def new_record(role):
    return {"role": role, "disabled": False, "created": time.time(), "strikes": 0,
            "coins": 0, "expires": 0, "refs": 0}


def valid_name(n):
    return bool(NAME_RE.fullmatch(n))


def active_admins(users):
    return [n for n, r in users.items() if r.get("role") == "admin" and not r.get("disabled") and has_key(r)]


def owner_role(owner):
    return users_load().get(owner, {}).get("role", "user")


def is_expired(rec):
    if rec.get("role") == "admin":
        return False
    exp = float(rec.get("expires") or 0)
    return exp > 0 and exp < time.time()


def time_left_text(rec):
    exp = float(rec.get("expires") or 0)
    if exp <= 0:
        return "not started"
    left = exp - time.time()
    if left <= 0:
        return "expired on " + fmt_time(exp)
    return "%dd %dh left (until %s)" % (int(left // DAY), int((left % DAY) // 3600), fmt_time(exp))


def add_strike(name):
    def fn(users):
        rec = users.get(name)
        if not rec:
            return 0, False
        rec["strikes"] = int(rec.get("strikes", 0)) + 1
        banned = False
        if rec["strikes"] >= STRIKE_LIMIT and rec.get("role") != "admin" and not rec.get("disabled"):
            rec["disabled"] = True
            banned = True
        return rec["strikes"], banned
    strikes, banned = users_mutate(fn)
    if banned:
        for m in list_bots(owner=name):
            stop_bot(m["id"])
        kill_sessions(name)
    return strikes, banned


def add_coins(name, amount):
    def fn(users):
        rec = users.get(name)
        if not rec:
            return None
        rec["coins"] = max(0, int(rec.get("coins", 0)) + amount)
        return rec["coins"]
    return users_mutate(fn)


def tg_account(uid, ref=None):
    """Creates the panel account for a Telegram user (name: tg<id>) if missing.
    `ref` is the inviter's Telegram ID, only used for brand-new accounts."""
    name = "tg%d" % int(uid)

    def fn(users):
        if name in users:
            return
        rec = new_record("user")
        rec.update(tg_id=int(uid))
        if ref:
            rr = "tg%d" % int(ref)
            if rr != name and rr in users:
                rec["ref_by"] = rr
        users[name] = rec
    users_mutate(fn)
    return name


def ref_reward():
    try:
        return max(0, min(100, int(bot_cfg().get("ref_reward", COIN_PER_DAY))))
    except (TypeError, ValueError):
        return COIN_PER_DAY


def apply_reward(name):
    """Pays the inviter once. Returns inviter's Telegram ID when paid, else None."""
    amount = ref_reward()

    def fn(users):
        r = users.get(name)
        if amount <= 0 or not r or not r.get("ref_by") or r.get("ref_done"):
            return None
        r["ref_done"] = True
        inv = users.get(r["ref_by"])
        if not inv or inv.get("disabled"):
            return None
        inv["coins"] = int(inv.get("coins", 0)) + amount
        inv["refs"] = int(inv.get("refs", 0)) + 1
        return inv.get("tg_id")
    return users_mutate(fn)


def purchase(name, days):
    """Spends coins for `days`, extends expiry, issues a key on first purchase.
    Returns (status, message, key_or_None)."""
    now = time.time()

    def fn(users):
        rec = users.get(name)
        if not rec:
            return "bad", "Account not found - press /start first", None
        if rec.get("disabled"):
            return "bad", "Account is banned - contact the admin", None
        cost = days * COIN_PER_DAY
        coins = int(rec.get("coins", 0))
        if coins < cost:
            return "bad", "Not enough coins: %d needed, you have %d." % (cost, coins), None
        base = max(float(rec.get("expires") or 0), now)
        rec["coins"] = coins - cost
        rec["expires"] = base + days * DAY
        key = None
        if not has_key(rec):
            key = issue_key(rec)
        return ("ok", "Added %d day(s). Coins left: %d · expires %s"
                % (days, rec["coins"], fmt_time(rec["expires"])), key)
    return users_mutate(fn)


def reissue(name):
    def fn(users):
        rec = users.get(name)
        if not rec or rec.get("disabled"):
            return "bad", "Account unavailable", None
        if float(rec.get("expires") or 0) <= time.time():
            return "bad", "No active time. Buy days first.", None
        wait = key_wait_left(rec)
        if wait > 0:
            return "bad", "Key can be issued once per day. Try again in %s." % fmt_wait(wait), None
        return "ok", "New key issued. The old key no longer works.", issue_key(rec)
    return users_mutate(fn)


def public_info(name):
    rec = users_load().get(name, {})
    return {"coins": int(rec.get("coins", 0)), "time_left": time_left_text(rec),
            "has_key": has_key(rec), "disabled": bool(rec.get("disabled")),
            "strikes": int(rec.get("strikes", 0)), "refs": int(rec.get("refs", 0)),
            "wait_left": key_wait_left(rec), "expires": float(rec.get("expires") or 0)}


def internal_dispatch(path, body):
    """Only reachable through H.internal_api (local + shared secret checked)."""
    if path == "/internal/meta":
        un = str(body.get("username") or "")
        if re.fullmatch(r"[A-Za-z0-9_]{3,64}", un):
            bot_cfg_update(username=un)
            return {"ok": True}
        return {"ok": False, "error": "bad username"}
    try:
        tg = int(body.get("tg_id"))
    except (TypeError, ValueError):
        return {"ok": False, "error": "tg_id required"}
    name = "tg%d" % tg
    if path == "/internal/user":
        ref = body.get("ref")
        ref = int(ref) if str(ref or "").isdigit() else None
        tg_account(tg, ref)
        return {"ok": True, "user": public_info(name)}
    if path == "/internal/info":
        return {"ok": True, "user": public_info(name) if name in users_load() else None}
    if path == "/internal/buy":
        try:
            days = int(body.get("days"))
        except (TypeError, ValueError):
            return {"ok": False, "error": "days required"}
        if days not in DAY_OPTIONS:
            return {"ok": False, "error": "invalid days"}
        status, msg, key = purchase(name, days)
        if status == "ok" and key:
            kill_sessions(name)
        return {"ok": status == "ok", "msg": msg, "key": key}
    if path == "/internal/reissue":
        status, msg, key = reissue(name)
        if status == "ok":
            kill_sessions(name)
        return {"ok": status == "ok", "msg": msg, "key": key}
    if path == "/internal/reward":
        return {"ok": True, "inviter_tg": apply_reward(name), "amount": ref_reward()}
    if path == "/internal/addcoin":
        try:
            amount = int(body.get("amount"))
        except (TypeError, ValueError):
            return {"ok": False, "error": "amount required"}
        if amount == 0 or abs(amount) > 100000:
            return {"ok": False, "error": "bad amount"}
        if name not in users_load():
            return {"ok": False, "error": "account not found"}
        return {"ok": True, "coins": add_coins(name, amount)}
    return {"ok": False, "error": "unknown endpoint"}


def stats():
    mem = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, v = line.split(":", 1)
            mem[k] = int(v.split()[0]) * 1024
    total = mem.get("MemTotal", 1)
    avail = mem.get("MemAvailable", mem.get("MemFree", 0))
    du = shutil.disk_usage("/")
    up = float(open("/proc/uptime").read().split()[0])
    load = open("/proc/loadavg").read().split()[:3]
    d, rem = divmod(int(up), 86400)
    h, rem = divmod(rem, 3600)
    return {"host": os.uname().nodename, "cores": os.cpu_count() or 1, "load": load, "load1": float(load[0]),
            "mem_used": total - avail, "mem_total": total, "disk_used": du.used, "disk_total": du.total,
            "uptime": "%dd %dh %dm" % (d, h, rem // 60)}


# =====================================================
#  Bot storage
# =====================================================
def bdir(bid):
    return os.path.join(BOTS, bid)


def workdir(bid):
    return os.path.join(BOTS, bid, "work")


def meta_load(bid):
    return read_json(os.path.join(bdir(bid), "meta.json"), {})


def meta_save(bid, m):
    write_json(os.path.join(bdir(bid), "meta.json"), m)


def meta_update(bid, **kw):
    with LOCK:
        m = meta_load(bid)
        if not m:
            return {}
        m.update(kw)
        meta_save(bid, m)
        return m


def list_bots(owner=None):
    out = []
    if os.path.isdir(BOTS):
        for bid in os.listdir(BOTS):
            m = meta_load(bid)
            if m.get("id") == bid and (owner is None or m.get("owner") == owner):
                out.append(m)
    return sorted(out, key=lambda x: x.get("created", 0), reverse=True)


def can_access(s, m):
    return s["role"] == "admin" or m.get("owner") == s["user"]


# ---------- per-bot OS user ----------
def bot_user(bid):
    return "tbpb_" + bid


def bot_pw(bid):
    if not IS_ROOT:
        return None
    try:
        return pwd.getpwnam(bot_user(bid))
    except KeyError:
        return None


def ensure_bot_user(bid):
    if not IS_ROOT:
        return None
    pw = bot_pw(bid)
    if pw:
        return pw
    run_cmd(["useradd", "-r", "-M", "-d", "/nonexistent", "-s", "/usr/sbin/nologin", bot_user(bid)], timeout=60)
    return bot_pw(bid)


def drop_bot_user(bid):
    if bot_pw(bid):
        run_cmd(["userdel", bot_user(bid)], timeout=60)


def _chown(p, uid, gid):
    if IS_ROOT:
        try:
            os.chown(p, uid, gid)
        except OSError:
            pass


def harden(bid):
    """Root owns the bot folder and secrets; the bot's own user can only read its
    source and write its work/ folder."""
    d = bdir(bid)
    m = meta_load(bid)
    pw = bot_pw(bid)
    gid = pw.pw_gid if pw else 0
    _chown(d, 0, gid)
    os.chmod(d, 0o750 if pw else 0o755)
    for name in os.listdir(d):
        p = os.path.join(d, name)
        if os.path.islink(p):
            continue
        if name == "work":
            if pw:
                _chown(p, pw.pw_uid, pw.pw_gid)
            os.chmod(p, 0o700)
            continue
        if os.path.isdir(p):
            _chown(p, 0, 0)
            os.chmod(p, 0o755)
            continue
        if name == m.get("file") or name in ("constraints.txt", "package.json"):
            _chown(p, 0, gid)
            os.chmod(p, 0o640 if pw else 0o644)
        else:
            _chown(p, 0, 0)
            os.chmod(p, 0o600)


def prep_workdir(bid):
    w = workdir(bid)
    os.makedirs(w, mode=0o700, exist_ok=True)
    pw = bot_pw(bid)
    if pw:
        _chown(w, pw.pw_uid, pw.pw_gid)
    os.chmod(w, 0o700)


# =====================================================
#  Quota: RAM 256 MB · CPU 0.5 core · Disk 1024 MB
# =====================================================
def dir_size(p):
    total = 0
    for root, _, files in os.walk(p):
        for f in files:
            try:
                total += os.lstat(os.path.join(root, f)).st_size
            except OSError:
                pass
    return total


def user_disk(owner):
    return sum(dir_size(bdir(m["id"])) for m in list_bots(owner))


def proc_rss(pid):
    try:
        with open("/proc/%d/status" % pid) as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1]) * 1024
    except OSError:
        pass
    return 0


def cg_dir(owner):
    return os.path.join(CG_BASE, "u-" + hashlib.sha1(owner.encode()).hexdigest()[:12])


def cg_ready_host():
    return IS_ROOT and os.path.exists(os.path.join(CG_ROOT, "cgroup.controllers"))


def cg_setup(owner):
    if not cg_ready_host():
        return None
    try:
        os.makedirs(CG_BASE, exist_ok=True)
        _write(os.path.join(CG_ROOT, "cgroup.subtree_control"), "+cpu +memory")
        _write(os.path.join(CG_BASE, "cgroup.subtree_control"), "+cpu +memory")
        d = cg_dir(owner)
        os.makedirs(d, exist_ok=True)
        _write(os.path.join(d, "memory.max"), str(QUOTA_RAM_MB * MB))
        _write(os.path.join(d, "memory.swap.max"), "0")
        _write(os.path.join(d, "cpu.max"), "%d 100000" % int(QUOTA_CPU * 100000))
        return d
    except OSError:
        return None


def hard_mode(owner):
    return os.path.exists(os.path.join(cg_dir(owner), "memory.max"))


def owner_ram_used(owner):
    cur = read_file(os.path.join(cg_dir(owner), "memory.current"), "").strip()
    if cur.isdigit():
        return int(cur)
    total = 0
    for m in list_bots(owner):
        if m.get("pid") and is_running(m["id"], m):
            total += proc_rss(m["pid"])
    return total


def tile(label, value, p=None, sub=""):
    bar = ""
    if p is not None:
        bar = "<div class=bar><i style='width:%d%%;background:%s'></i></div>" % (p, bar_color(p))
    return ("<div class=tile><div class=tl>%s</div><div class=tv>%s</div>%s<div class=ts>%s</div></div>"
            % (esc(label), esc(value), bar, esc(sub)))


def quota_tiles(owner):
    ram = owner_ram_used(owner)
    disk = user_disk(owner)
    mode = "HARD · cgroup v2" if hard_mode(owner) else "SOFT · watchdog"
    return (tile("RAM quota", "%s / %d MB" % (human(ram), QUOTA_RAM_MB), pct(ram, QUOTA_RAM_MB * MB), mode)
            + tile("CPU quota", "%.1f core" % QUOTA_CPU, None, "%d%% of one core" % int(QUOTA_CPU * 100))
            + tile("Disk quota", "%s / %d MB" % (human(disk), QUOTA_DISK_MB), pct(disk, QUOTA_DISK_MB * MB),
                   "bots · venv · packages"))


def sub_tiles(rec):
    exp = float(rec.get("expires") or 0)
    now = time.time()
    if exp <= 0:
        val, sub = "Not started", "buy days in Telegram"
    elif exp <= now:
        val, sub = "Expired", "renew in Telegram"
    else:
        left = exp - now
        val = "%dd %dh" % (int(left // DAY), int((left % DAY) // 3600))
        sub = "until " + fmt_time(exp)
    return (tile("Time left", val, None, sub)
            + tile("Coins", str(int(rec.get("coins", 0))), None, "%d coin = 1 day" % COIN_PER_DAY))


# =====================================================
#  Code scanner
# =====================================================
def analyze(kind, src):
    viol = []
    for n, line in enumerate(src.splitlines(), 1):
        for cat, rx in RULES_C:
            if rx.search(line):
                viol.append("line %d [%s] %s" % (n, cat, line.strip()[:70]))
                break
    if kind == "py":
        try:
            tree = ast.parse(src)
        except SyntaxError as e:
            raise ValueError("Syntax error at line %s: %s" % (e.lineno, e.msg))
        mods = set()
        for node in ast.walk(tree):
            names = []
            if isinstance(node, ast.Import):
                names = [a.name for a in node.names]
            elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
                names = [node.module]
            for nm in names:
                top = nm.split(".")[0]
                mods.add(top)
                if top in BANNED_PY_MODULES:
                    viol.append("line %d [hosting] import '%s' is not allowed" % (node.lineno, nm))
        std = sys.stdlib_module_names
        imports = sorted({PY_MAP.get(m, m) for m in mods if m not in std and not m.startswith("_")})
    else:
        specs = set()
        for rx in JS_RE:
            specs.update(rx.findall(src))
        for s in specs:
            if s in BANNED_JS_MODULES:
                viol.append("[hosting] require('%s') is not allowed" % s)
        pk = set()
        for s in specs:
            if s.startswith((".", "/", "node:")) or s in NODE_BUILTIN:
                continue
            p = "/".join(s.split("/")[:2]) if s.startswith("@") else s.split("/")[0]
            if p and not p.startswith("-"):
                pk.add(p)
        imports = sorted(pk)
    return viol, imports


def blocked(name):
    n = name.lower().replace("_", "-")
    return n in BLOCK_EXACT or n.startswith(BLOCK_PREFIX)


def split_blocked(names):
    ok, bad = [], []
    for n in names:
        (bad if blocked(n) else ok).append(n)
    return ok, bad


# =====================================================
#  Installers
# =====================================================
def apt_install(pkgs):
    if not IS_ROOT:
        return False, "Root is required to install: " + " ".join(pkgs)
    run_cmd(["apt-get", "update", "-y"], timeout=600)
    rc, out = run_cmd(["apt-get", "install", "-y"] + pkgs, timeout=900)
    return rc == 0, out[-400:]


def ensure_venv(d):
    vdir = os.path.join(d, "venv")
    py = os.path.join(vdir, "bin", "python3")
    if os.path.exists(py):
        return py, ""
    rc, out = run_cmd([sys.executable, "-m", "venv", vdir], timeout=300)
    if rc != 0:
        shutil.rmtree(vdir, ignore_errors=True)
        ok, aout = apt_install(["python3-venv"])
        if not ok:
            return None, "python3-venv install failed: " + aout
        rc, out = run_cmd([sys.executable, "-m", "venv", vdir], timeout=300)
        if rc != 0:
            shutil.rmtree(vdir, ignore_errors=True)
            return None, "venv creation failed: " + out[-300:]
    return py, ""


def pip_error(out):
    low = out.lower()
    if "resolutionimpossible" in low and any(w in low for w in ("numpy", "opencv", "ddddocr")):
        return "Blocked by policy: a dependency needs numpy / opencv / ddddocr, which this panel never installs."
    return out[-500:] or "pip failed"


def install_py(d, pkgs, say):
    py, err = ensure_venv(d)
    if not py:
        return False, err
    cons = os.path.join(d, "constraints.txt")
    try:
        os.unlink(cons)
    except FileNotFoundError:
        pass
    _write(cons, CONSTRAINTS)
    if not pkgs:
        return True, ""
    say("Installing Python packages...")
    rc, out = run_cmd([py, "-m", "pip", "install", "--disable-pip-version-check", "-c", cons] + pkgs, cwd=d, timeout=1200)
    if rc != 0:
        return False, pip_error(out)
    return True, ""


def install_js(d, pkgs, say):
    if not (shutil.which("node") and shutil.which("npm")):
        say("Installing Node.js...")
        ok, out = apt_install(["nodejs", "npm"])
        if not ok or not shutil.which("node"):
            return False, "Node.js install failed: " + out
    pj = os.path.join(d, "package.json")
    if not os.path.exists(pj):
        write_json(pj, {"name": "turbo-bot", "private": True})
    if not pkgs:
        return True, ""
    say("Installing JavaScript packages...")
    rc, out = run_cmd(["npm", "install", "--no-audit", "--no-fund", "--ignore-scripts", "--loglevel=error"] + pkgs,
                      cwd=d, timeout=1200)
    return (rc == 0), ("" if rc == 0 else out[-500:])


def install_worker(bid, autostart):
    ready = False
    try:
        m = meta_load(bid)
        if not m:
            return
        d = bdir(bid)
        if IS_ROOT:
            ensure_bot_user(bid)
        src = read_text(os.path.join(d, m["file"]))
        viol, detected = analyze(m["kind"], src)
        if viol:
            meta_update(bid, status="error", msg="Blocked by code scanner: " + viol[0][:150],
                        violations=viol[:20], installed=[], blocked=[])
            return
        wanted = sorted(set(detected) | set(m.get("extra", [])))
        good, bad = split_blocked(wanted)
        meta_update(bid, msg="Scanning imports...", deps=wanted, blocked=bad, violations=[])

        def say(t):
            meta_update(bid, msg=t)

        if m["kind"] == "py":
            ok, err = install_py(d, good, say)
        else:
            ok, err = install_js(d, good, say)
        harden(bid)
        if not ok:
            meta_update(bid, status="error", msg=err or "Install failed", installed=[])
            return
        owner = m.get("owner", "")
        if owner_role(owner) != "admin" and user_disk(owner) > QUOTA_DISK_MB * MB:
            meta_update(bid, status="error", installed=[],
                        msg="Disk quota exceeded (%d MB) - delete some bots first" % QUOTA_DISK_MB)
            return
        note = "Ready" + (" · skipped by policy: " + ", ".join(bad) if bad else "")
        meta_update(bid, status="ready", msg=note, installed=good)
        ready = True
    except ValueError as e:
        meta_update(bid, status="error", msg=str(e)[:300], installed=[])
    except Exception as e:
        traceback.print_exc()
        meta_update(bid, status="error", msg="Unexpected error: %s" % str(e)[:200], installed=[])
    if ready and autostart:
        ok, msg = start_bot(bid)
        if not ok:
            meta_update(bid, msg=msg)


# =====================================================
#  Process control
# =====================================================
def is_running(bid, m):
    p = PROCS.get(bid)
    if p is not None:
        if p.poll() is None:
            return True
        PROCS.pop(bid, None)
    pid = m.get("pid")
    if not pid:
        return False
    try:
        cwd = os.path.realpath(os.readlink("/proc/%d/cwd" % pid))
    except OSError:
        return False
    return cwd in (os.path.realpath(bdir(bid)), os.path.realpath(workdir(bid)))


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _child_limits():
    def apply():
        try:
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
            fsz = QUOTA_DISK_MB * MB
            resource.setrlimit(resource.RLIMIT_FSIZE, (fsz, fsz))
            resource.setrlimit(resource.RLIMIT_NOFILE, (1024, 1024))
            resource.setrlimit(resource.RLIMIT_NPROC, (256, 256))
        except (ValueError, OSError):
            pass
    return apply


def start_bot(bid, manual=True):
    with LOCK:
        m = meta_load(bid)
        if not m:
            return False, "Bot not found"
        if m.get("status") != "ready":
            return False, m.get("msg") or "Not ready yet"
        if is_running(bid, m):
            return True, "Already running"
        owner = m.get("owner", "")
        orec = users_load().get(owner, {})
        is_user = orec.get("role", "user") != "admin"
        if is_user:
            if is_expired(orec):
                return False, "Subscription expired - buy days in the Telegram bot"
            if user_disk(owner) > QUOTA_DISK_MB * MB:
                return False, "Disk quota exceeded (%d MB)" % QUOTA_DISK_MB
            if owner_ram_used(owner) >= QUOTA_RAM_MB * MB:
                return False, "RAM quota reached (%d MB) - stop another bot first" % QUOTA_RAM_MB
        pw = bot_pw(bid)
        if IS_ROOT and not pw:
            pw = ensure_bot_user(bid)
            if not pw:
                return False, "Could not create sandbox user for this bot"
        cg = cg_setup(owner) if (IS_ROOT and is_user) else None
        harden(bid)
        prep_workdir(bid)
        d = bdir(bid)
        target = os.path.join(d, m["file"])
        if m["kind"] == "py":
            cmd = [os.path.join(d, "venv", "bin", "python3"), target]
        else:
            cmd = [shutil.which("node") or "node", target]
        logp = os.path.join(d, "bot.log")
        try:
            if os.path.getsize(logp) > 5 * MB:
                os.replace(logp, logp + ".1")
        except OSError:
            pass
        env = {"PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"), "HOME": workdir(bid),
               "LANG": "C.UTF-8", "PYTHONUNBUFFERED": "1", "PYTHONDONTWRITEBYTECODE": "1"}
        kw = {"preexec_fn": _child_limits()}
        if pw:
            kw.update(user=pw.pw_uid, group=pw.pw_gid, extra_groups=[])
        try:
            fd = os.open(logp, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            with os.fdopen(fd, "ab") as lf:
                lf.write(("\n=== start %s ===\n" % time.strftime("%Y-%m-%d %H:%M:%S")).encode())
                p = subprocess.Popen(cmd, cwd=workdir(bid), env=env, stdin=subprocess.DEVNULL, stdout=lf,
                                     stderr=subprocess.STDOUT, start_new_session=True, **kw)
        except OSError as e:
            return False, "Could not start: %s" % str(e)[:200]
        if cg:
            try:
                _write(os.path.join(cg, "cgroup.procs"), str(p.pid))
            except OSError:
                pass
        PROCS[bid] = p
        m.update(pid=p.pid, started=time.time())
        if manual:
            m.update(enabled=True, restarts=0)
        meta_save(bid, m)
    time.sleep(2)
    if p.poll() is not None:
        PROCS.pop(bid, None)
        meta_update(bid, pid=None, enabled=False)
        return False, "Exited right away (code %s) - open Logs" % p.returncode
    return True, "Started"


def stop_bot(bid):
    with LOCK:
        m = meta_load(bid)
        pid = m.get("pid")
        p = PROCS.pop(bid, None)
        if m:
            meta_update(bid, enabled=False, pid=None)
    if pid:
        for sig, tries in ((signal.SIGTERM, 50), (signal.SIGKILL, 30)):
            try:
                os.killpg(pid, sig)
            except OSError:
                pass
            for _ in range(tries):
                if p is not None:
                    p.poll()
                if not alive(pid):
                    return
                time.sleep(0.1)
    if p is not None:
        p.poll()


def state_of(m):
    st = m.get("status")
    if st == "installing":
        return "Installing", "info"
    if st == "error":
        return "Error", "bad"
    if is_running(m["id"], m):
        return "Running", "ok"
    if m.get("enabled"):
        return "Restarting", "warn"
    return "Stopped", "mut"


def enforce_policies():
    users = users_load()
    # 1) expired subscriptions: stop their bots
    for m in list_bots():
        rec = users.get(m.get("owner", ""), {})
        if is_expired(rec) and is_running(m["id"], m):
            stop_bot(m["id"])
            meta_update(m["id"], msg="Subscription expired - buy days in the Telegram bot")
    # 2) RAM quota: stop the newest bot of an over-quota user
    groups = {}
    for m in list_bots():
        o = m.get("owner", "")
        if users.get(o, {}).get("role") != "admin":
            groups.setdefault(o, []).append(m)
    for owner, bots in groups.items():
        if owner_ram_used(owner) <= QUOTA_RAM_MB * MB:
            continue
        running = [b for b in bots if is_running(b["id"], b)]
        if not running:
            continue
        newest = max(running, key=lambda b: b.get("started", 0))
        stop_bot(newest["id"])
        meta_update(newest["id"], msg="RAM quota (%d MB) exceeded - stopped" % QUOTA_RAM_MB)


def watchdog():
    time.sleep(3)
    while True:
        try:
            enforce_policies()
            users = users_load()
            for m in list_bots():
                bid = m["id"]
                if m.get("status") != "ready" or not m.get("enabled"):
                    continue
                if is_expired(users.get(m.get("owner", ""), {})):
                    continue
                with LOCK:
                    mm = meta_load(bid)
                    if is_running(bid, mm):
                        if mm.get("restarts") and time.time() - mm.get("started", 0) > 300:
                            meta_update(bid, restarts=0)
                        continue
                    if mm.get("restarts", 0) >= MAX_RESTARTS:
                        meta_update(bid, enabled=False, msg="Stopped: crashed too many times - open Logs")
                        continue
                    meta_update(bid, restarts=mm.get("restarts", 0) + 1)
                start_bot(bid, manual=False)
        except Exception:
            traceback.print_exc()
        time.sleep(10)


def kill_sessions(name, keep=None):
    with LOCK:
        for t in [t for t, v in SESSIONS.items() if v.get("user") == name and t != keep]:
            SESSIONS.pop(t, None)


def tunnel_up():
    try:
        return subprocess.run(["pgrep", "-x", "cloudflared"], capture_output=True, timeout=5).returncode == 0
    except Exception:
        return False


def bot_up():
    try:
        return subprocess.run(["pgrep", "-f", "tbp_bot.py"], capture_output=True, timeout=5).returncode == 0
    except Exception:
        return False


def tail(path, n=100):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 256 * 1024))
            text = f.read().decode("utf-8", "replace")
        return "\n".join(text.splitlines()[-n:]) or "(no output yet)"
    except FileNotFoundError:
        return "(no log yet)"
    except OSError as e:
        return "Error: %s" % e


def colorize(text):
    out = []
    for line in text.splitlines():
        if re.search(r"Traceback|Error|Exception|CRITICAL", line):
            cls = "err"
        elif re.search(r"Warning|WARN", line):
            cls = "warn"
        elif line.startswith("=== "):
            cls = "sep"
        else:
            cls = ""
        out.append("<span class='%s'>%s</span>" % (cls, esc(line)))
    return "\n".join(out)


# =====================================================
#  Multipart / form parsing
# =====================================================
def parse_multipart(raw, boundary):
    fields, files = {}, {}
    delim = b"--" + boundary
    for part in raw.split(delim)[1:]:
        if part.startswith(b"--"):
            break
        if part.startswith(b"\r\n"):
            part = part[2:]
        if part.endswith(b"\r\n"):
            part = part[:-2]
        head, sep, data = part.partition(b"\r\n\r\n")
        if not sep:
            continue
        hdr = head.decode("utf-8", "replace")
        nm = re.search(r'name="([^"]*)"', hdr)
        if not nm:
            continue
        fn = re.search(r'filename="([^"]*)"', hdr)
        if fn:
            files[nm.group(1)] = (fn.group(1), data)
        else:
            fields[nm.group(1)] = data.decode("utf-8", "replace")
    return fields, files


def parse_body(raw, ctype):
    if ctype.startswith("multipart/form-data"):
        mt = re.search(r'boundary="?([^";]+)"?', ctype)
        if not mt:
            return {}, {}
        return parse_multipart(raw, mt.group(1).encode())
    fields = {k: v[0] for k, v in parse_qs(raw.decode("utf-8", "replace"), keep_blank_values=True).items()}
    return fields, {}


# =====================================================
#  UI
# =====================================================
CSS = """
:root{color-scheme:dark;--bg:#05060d;--panel:rgba(18,20,38,.6);--panel2:rgba(26,29,54,.72);--line:rgba(140,150,230,.16);--txt:#eef0ff;--mut:#9097bf;--c1:#22d3ee;--c2:#a78bfa;--c3:#f472b6;--ok:#34d399;--bad:#fb7185;--warn:#fbbf24;--info:#60a5fa}
*{box-sizing:border-box}html,body{margin:0}
body{font:15px/1.6 "Inter",system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;color:var(--txt);min-height:100vh;
background:radial-gradient(1000px 600px at 90% -10%,rgba(167,139,250,.25),transparent 60%),radial-gradient(900px 600px at -10% 10%,rgba(34,211,238,.18),transparent 55%),radial-gradient(700px 500px at 60% 120%,rgba(244,114,182,.14),transparent 60%),var(--bg);background-attachment:fixed}
a{color:inherit}
.wrap{max-width:1040px;margin:0 auto;padding:0 16px 56px}
.topbar{position:sticky;top:0;z-index:5;backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px);background:rgba(7,8,18,.72);border-bottom:1px solid var(--line);margin:0 -16px 18px;padding:12px 16px;display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap}
.brand{display:flex;align-items:center;gap:10px;text-decoration:none}
.badge{width:36px;height:36px;border-radius:12px;background:linear-gradient(135deg,var(--c1),var(--c2) 55%,var(--c3));display:grid;place-items:center;box-shadow:0 6px 22px rgba(167,139,250,.35)}
.badge svg{width:18px;height:18px;fill:#0b0b1a}
.bname{font-weight:900;letter-spacing:.14em;font-size:15px;background:linear-gradient(90deg,var(--c1),var(--c2),var(--c3));-webkit-background-clip:text;background-clip:text;color:transparent}
.bsub{color:var(--mut);font-size:10.5px;letter-spacing:.2em;text-transform:uppercase}
.menu{display:flex;gap:6px;align-items:center;flex-wrap:wrap}
.menu a{color:var(--mut);text-decoration:none;padding:7px 13px;border-radius:999px;font-weight:600;font-size:13.5px;transition:.15s}
.menu a:hover{color:#fff;background:rgba(255,255,255,.06)}
.menu a.on{color:#fff;background:linear-gradient(90deg,rgba(34,211,238,.2),rgba(167,139,250,.24));box-shadow:inset 0 0 0 1px rgba(167,139,250,.45)}
.menu a.tg{color:#7dd3fc}
.who{color:var(--mut);font-size:12px;padding:0 6px}
.hero{padding:10px 2px 4px}
h1{font-size:26px;margin:0 0 2px;letter-spacing:-.01em}
.sec{font-size:11.5px;letter-spacing:.18em;text-transform:uppercase;color:var(--mut);margin:28px 0 12px;display:flex;align-items:center;gap:10px}
.sec:after{content:"";flex:1;height:1px;background:var(--line)}
.card{background:var(--panel);border:1px solid var(--line);border-radius:20px;padding:18px;box-shadow:0 10px 40px rgba(0,0,0,.28);backdrop-filter:blur(8px)}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:14px}
.tile{background:var(--panel2);border:1px solid var(--line);border-radius:18px;padding:16px;position:relative;overflow:hidden}
.tile:before{content:"";position:absolute;left:0;right:0;top:0;height:2px;background:linear-gradient(90deg,var(--c1),var(--c2),var(--c3))}
.tl{color:var(--mut);font-size:11px;text-transform:uppercase;letter-spacing:.14em}
.tv{font-size:21px;font-weight:800;margin:4px 0 2px;letter-spacing:-.01em}
.ts{color:var(--mut);font-size:12px}
.bar{height:7px;border-radius:99px;background:rgba(255,255,255,.06);overflow:hidden;margin:10px 0 6px}
.bar i{display:block;height:100%;border-radius:99px}
.bots{display:grid;gap:10px}
.botrow{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;padding:14px 16px;border-radius:16px;background:var(--panel2);border:1px solid var(--line);transition:.15s;text-decoration:none}
.botrow:hover{border-color:rgba(167,139,250,.45);transform:translateY(-1px)}
.name{font-weight:700;font-size:16px}
.kv{color:var(--mut);font-size:13px}.kv b{color:var(--txt)}
.mut{color:var(--mut)}
.acts{display:flex;gap:6px;flex-wrap:wrap;align-items:center}
.pill{display:inline-flex;align-items:center;gap:6px;padding:2px 10px;border-radius:999px;font-size:12px;font-weight:700;border:1px solid}
.pill:before{content:"";width:7px;height:7px;border-radius:50%;background:currentColor;box-shadow:0 0 8px currentColor}
.pill.ok{color:var(--ok);border-color:rgba(52,211,153,.4);background:rgba(52,211,153,.1)}
.pill.bad{color:var(--bad);border-color:rgba(251,113,133,.4);background:rgba(251,113,133,.1)}
.pill.warn{color:var(--warn);border-color:rgba(251,191,36,.4);background:rgba(251,191,36,.1)}
.pill.info{color:var(--info);border-color:rgba(96,165,250,.4);background:rgba(96,165,250,.1)}
.pill.mut{color:var(--mut);border-color:var(--line)}
.tag2{display:inline-block;padding:2px 9px;margin:3px;border-radius:8px;background:rgba(167,139,250,.14);color:#ddd6fe;font:13px ui-monospace,Menlo,Consolas,monospace}
.tag2.blk{background:rgba(251,191,36,.12);color:#fde68a;text-decoration:line-through}
button,.btn{font:inherit;font-weight:600;padding:8px 14px;border-radius:11px;border:1px solid var(--line);background:rgba(255,255,255,.05);color:var(--txt);cursor:pointer;text-decoration:none;display:inline-block;transition:transform .08s,filter .15s}
button:hover,.btn:hover{filter:brightness(1.15)}
button:active,.btn:active{transform:scale(.97)}
button:disabled,.btn:disabled{opacity:.5;cursor:not-allowed;filter:none}
.btn.pri{border:0;color:#0b0b1a;background:linear-gradient(90deg,var(--c1),var(--c2));box-shadow:0 6px 22px rgba(34,211,238,.25)}
.btn.ok{background:rgba(52,211,153,.15);border-color:rgba(52,211,153,.45);color:#a7f3d0}
.btn.dng{background:rgba(251,113,133,.14);border-color:rgba(251,113,133,.45);color:#fecdd3}
.btn.ghost{background:transparent}.btn.sm{padding:5px 11px;font-size:13px}.wide{width:100%}
input[type=text],input[type=password],input[type=number],select{font:inherit;width:100%;padding:11px 13px;margin:5px 0 12px;border-radius:11px;border:1px solid var(--line);background:rgba(7,8,20,.8);color:var(--txt)}
input:focus,select:focus{outline:2px solid rgba(34,211,238,.45);border-color:transparent}
label{display:block;font-size:13px;color:var(--mut);font-weight:600}
.mini{display:inline-flex;gap:5px;align-items:center;font-weight:500;color:var(--mut);margin-left:4px}
.drop{display:block;border:2px dashed rgba(167,139,250,.45);border-radius:16px;padding:22px;text-align:center;cursor:pointer;background:rgba(167,139,250,.05);margin-bottom:12px;color:var(--mut)}
.drop:hover{border-color:var(--c1);background:rgba(34,211,238,.06)}
.drop input{display:block;margin:10px auto 0;color:var(--txt)}
.chk{display:flex;align-items:center;gap:8px;font-weight:500;color:var(--txt);margin-bottom:14px}
.chk input{width:16px;height:16px;accent-color:var(--c2)}
.flash{padding:11px 15px;border-radius:14px;border:1px solid;font-weight:600;margin:12px 0}
.flash.ok{color:#a7f3d0;border-color:rgba(52,211,153,.45);background:rgba(52,211,153,.1)}
.flash.bad{color:#fecdd3;border-color:rgba(251,113,133,.45);background:rgba(251,113,133,.1)}
.reveal{border:1px solid rgba(251,191,36,.45);background:rgba(251,191,36,.08);border-radius:16px;padding:14px;margin:12px 0}
.reveal code{display:block;margin-top:8px;padding:10px;border-radius:10px;background:rgba(3,4,12,.85);font-size:15px;letter-spacing:.04em;word-break:break-all;color:#fde68a}
pre.log{white-space:pre-wrap;word-break:break-word;background:rgba(3,4,12,.85);border:1px solid var(--line);border-radius:14px;padding:14px;font:12.5px/1.5 ui-monospace,Menlo,Consolas,monospace;color:#cbd5e1;max-height:60vh;overflow:auto;margin:0}
.log .err{color:#fda4af}.log .warn{color:#fde68a}.log .sep{color:var(--c1);font-weight:700}
.empty{color:var(--mut);text-align:center;padding:24px}
.ugrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:14px}
.ucard{background:var(--panel2);border:1px solid var(--line);border-radius:18px;padding:16px;display:flex;flex-direction:column;gap:6px}
.uhead{display:flex;justify-content:space-between;gap:10px;align-items:flex-start;flex-wrap:wrap}
.ubars{margin-top:6px}
.mbar{height:6px;border-radius:99px;background:rgba(255,255,255,.06);overflow:hidden;margin:4px 0 8px}
.mbar i{display:block;height:100%;border-radius:99px}
.auth{min-height:88vh;display:flex;align-items:center;justify-content:center}
.authbox{width:100%;max-width:400px}.center{text-align:center}
.spin{display:inline-block;animation:sp 1s linear infinite}@keyframes sp{to{transform:rotate(360deg)}}
form{margin:0}.inline{display:inline}
footer{margin-top:34px;text-align:center;color:var(--mut);font-size:12px;letter-spacing:.06em;line-height:1.9}
footer a{color:#7dd3fc;text-decoration:none}
"""

BOLT_SVG = "<svg viewBox='0 0 24 24'><path d='M13 2 4 14h6l-1 8 9-12h-6z'/></svg>"


def bar_color(p):
    if p < 70:
        return "linear-gradient(90deg,#22d3ee,#a78bfa)"
    if p < 90:
        return "linear-gradient(90deg,#fbbf24,#f97316)"
    return "linear-gradient(90deg,#fb7185,#f472b6)"


def mini_bar(p):
    return "<div class=mbar><i style='width:%d%%;background:%s'></i></div>" % (p, bar_color(p))


def page(title, body, refresh=0):
    meta = "<meta http-equiv=refresh content='%d'>" % refresh if refresh else ""
    return ("<!doctype html><html lang=en><head><meta charset=utf-8>"
            "<meta name=viewport content='width=device-width,initial-scale=1'>"
            "<meta name=robots content='noindex,nofollow'>" + meta +
            "<title>" + esc(title) + "</title><style>" + CSS + "</style></head>"
            "<body><div class=wrap>" + body + "</div></body></html>")


def footer():
    return ("<footer>" + esc(PANEL_NAME) + " · V " + esc(VERSION) + "<br>Developer <b>" + esc(DEVELOPER) +
            "</b> · Telegram <a href='" + TG_URL + "' target=_blank rel=noopener>" + esc(TG_HANDLE) + " ↗</a></footer>")


def layout(s, title, body, active="", refresh=0):
    with LOCK:
        fl = s.pop("flash", None)
    flash = "<div class='flash %s'>%s</div>" % (fl[0], esc(fl[1])) if fl else ""
    links = [("dash", "/", "Dashboard")]
    if s["role"] == "admin":
        links.append(("users", "/users", "Users"))
    links.append(("acct", "/account", "Account"))
    nav = "".join("<a class='%s' href='%s'>%s</a>" % ("on" if k == active else "", h, t) for k, h, t in links)
    nav += "<a class=tg href='%s' target=_blank rel=noopener>Channel ↗</a>" % TG_URL
    top = ("<header class=topbar>"
           "<a class=brand href='/'><span class=badge>" + BOLT_SVG + "</span>"
           "<span><div class=bname>" + esc(PANEL_NAME) + "</div><div class=bsub>Userbot Panel</div></span></a>"
           "<nav class=menu>" + nav +
           "<span class=who>" + esc(s["user"]) + " · " + esc(s["role"]) + "</span>"
           "<form method=post action=/logout><input type=hidden name=csrf value='" + esc(s["csrf"]) + "'>"
           "<button class='btn ghost sm'>Logout</button></form></nav></header>")
    return page(title, top + flash + body + footer(), refresh)


def reveal_box(s):
    with LOCK:
        rv = s.pop("reveal", None)
    if not rv:
        return ""
    return ("<div class=reveal><b>Access key for " + esc(rv[0]) + "</b> "
            "<span class=mut>— copy it now, it will not be shown again</span>"
            "<code>" + esc(rv[1]) + "</code></div>")


def bot_row(m, show_owner):
    label, cls = state_of(m)
    bid = m["id"]
    owner = (" · owner " + esc(m.get("owner", ""))) if show_owner else ""
    return ("<a class=botrow href='/bot/%s'>"
            "<div><div class=name>%s</div><div class=kv>%s%s · %s</div></div>"
            "<div class=acts><span class='pill %s'>%s</span></div></a>"
            % (bid, esc(m.get("name", "")), esc(m.get("kind", "").upper()), owner, esc(m.get("msg", "")),
               cls, esc(label)))


def upload_card(csrf):
    return ("<div class=card><form method=post action=/upload enctype=multipart/form-data>"
            "<input type=hidden name=csrf value='" + esc(csrf) + "'>"
            "<label class=drop>Choose a <b>.py</b> or <b>.js</b> bot file (max 2 MB)"
            "<input type=file name=file accept='.py,.js' required></label>"
            "<label class=chk><input type=checkbox name=autostart value=1 checked> Start automatically after install</label>"
            "<button class='btn pri wide'>Upload &amp; install packages</button>"
            "<div class=kv style='margin-top:12px'>Never installed here: "
            "<span class='tag2 blk'>opencv-python</span><span class='tag2 blk'>numpy</span><span class='tag2 blk'>ddddocr</span></div>"
            "<div class=kv style='margin-top:8px'>Rejected automatically: bot-hosting code, server control, "
            "shell / reverse shell, miners and obfuscated exec. 3 violations = account ban.</div>"
            "</form></div>")


def act_form(csrf, bid, act, label, cls, inner=""):
    return ("<form class=inline method=post action=/action>"
            "<input type=hidden name=csrf value='" + esc(csrf) + "'>"
            "<input type=hidden name=id value='" + bid + "'>"
            "<input type=hidden name=act value='" + act + "'>" + inner +
            "<button class='btn " + cls + "'>" + esc(label) + "</button></form> ")


def ufm(csrf, act, user, label, cls, inner=""):
    return ("<form class=inline method=post action=/users/action>"
            "<input type=hidden name=csrf value='" + esc(csrf) + "'>"
            "<input type=hidden name=user value='" + esc(user) + "'>"
            "<input type=hidden name=act value='" + act + "'>" + inner +
            "<button class='btn " + cls + "'>" + esc(label) + "</button></form> ")


def coin_form(csrf, user):
    return ("<form class=inline method=post action=/users/action>"
            "<input type=hidden name=csrf value='" + esc(csrf) + "'>"
            "<input type=hidden name=user value='" + esc(user) + "'>"
            "<input type=hidden name=act value='coins'>"
            "<input type=number name=amount value=2 min=-100000 max=100000 style='width:96px;margin:0;padding:6px 8px'>"
            "<button class='btn sm'>Add coins</button></form> ")


def ucard(name, r, csrf, me, nbots, ram, disk):
    is_admin = r.get("role") == "admin"
    banned = bool(r.get("disabled"))
    head = ("<div class=uhead><div><div class=name>" + esc(name) + "</div>"
            "<div class=kv>created " + fmt_time(r.get("created")) + "</div></div>"
            "<div class=acts>" + ("<span class='pill info'>admin</span>" if is_admin else "<span class='pill mut'>user</span>") +
            ("<span class='pill bad'>banned</span>" if banned else "<span class='pill ok'>active</span>") +
            ("" if has_key(r) else "<span class='pill warn'>no key</span>") + "</div></div>")
    tg = (" · tg <b>%s</b>" % esc(r["tg_id"])) if r.get("tg_id") else ""
    flags = ("<div class=kv>bots <b>%d</b> · strikes <b>%d/%d</b>%s</div>"
             % (nbots, int(r.get("strikes", 0)), STRIKE_LIMIT, tg))
    money = ("<div class=kv>🪙 <b>%d</b> coins · ⏳ %s</div>"
             % (int(r.get("coins", 0)), esc("no expiry" if is_admin else time_left_text(r))))
    if is_admin:
        ram_txt, disk_txt, bars = "no limit", "no limit", ""
    else:
        ram_p, disk_p = pct(ram, QUOTA_RAM_MB * MB), pct(disk, QUOTA_DISK_MB * MB)
        ram_txt = "%s / %d MB" % (human(ram), QUOTA_RAM_MB)
        disk_txt = "%s / %d MB" % (human(disk), QUOTA_DISK_MB)
        bars = mini_bar(ram_p) + mini_bar(disk_p)
    quotas = ("<div class=ubars><div class=kv>RAM <b>%s</b> · CPU <b>%s</b></div>%s"
              "<div class=kv>Disk <b>%s</b></div></div>"
              % (ram_txt, "no limit" if is_admin else "0.5 core", bars, disk_txt))
    if me:
        acts = "<span class=kv>(you — use Account page)</span>"
    else:
        acts = coin_form(csrf, name)
        acts += ufm(csrf, "reset", name, "New key", "sm")
        acts += ufm(csrf, "toggle", name, "Unban" if banned else "Ban", "sm" if banned else "sm dng")
        acts += ufm(csrf, "role", name, "Make user" if is_admin else "Make admin", "sm")
        acts += ufm(csrf, "delete", name, "Delete", "sm dng",
                    "<label class=mini><input type=checkbox name=confirm value=yes required> confirm</label>")
    return ("<div class=ucard>" + head + flags + money + quotas +
            "<div class=acts style='margin-top:8px'>" + acts + "</div></div>")


# =====================================================
#  HTTP handler
# =====================================================
class H(BaseHTTPRequestHandler):
    server_version = "TURBO"
    sys_version = ""

    def log_message(self, *a):
        pass

    def ip(self):
        return self.client_address[0]

    def secure(self):
        return "https" in (self.headers.get("X-Forwarded-Proto", "") + self.headers.get("Cf-Visitor", ""))

    def _sec_headers(self):
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cache-Control", "no-store")

    def send_html(self, code, body, extra=None):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self._sec_headers()
        for k, v in (extra or []):
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def send_json(self, code, obj):
        data = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self._sec_headers()
        self.end_headers()
        self.wfile.write(data)

    def go(self, to, extra=None):
        self.send_response(303)
        self.send_header("Location", to)
        self.send_header("Content-Length", "0")
        self._sec_headers()
        for k, v in (extra or []):
            self.send_header(k, v)
        self.end_headers()

    def flash_go(self, s, kind, msg, to):
        with LOCK:
            s["flash"] = (kind, msg)
        self.go(to)

    def sess(self):
        try:
            c = SimpleCookie(self.headers.get("Cookie", ""))
        except CookieError:
            return None
        m = c.get("sid")
        if not m:
            return None
        with LOCK:
            s = SESSIONS.get(m.value)
            if not s or s["exp"] <= time.time():
                SESSIONS.pop(m.value, None)
                return None
        rec = users_load().get(s["user"])
        if not rec or rec.get("disabled") or not has_key(rec) or is_expired(rec):
            with LOCK:
                SESSIONS.pop(m.value, None)
            return None
        s["role"] = rec.get("role", "user")
        return s

    def _error(self):
        traceback.print_exc()
        try:
            self.send_html(500, page("Error", "<h1>Something went wrong</h1><p class=mut>Check the panel log.</p>"))
        except Exception:
            pass

    # ----- internal API (bot ⇄ panel) -----
    def internal_api(self, path, raw):
        # Requests that came through Cloudflare Tunnel carry these headers -> refuse
        if self.headers.get("CF-Ray") or self.headers.get("CF-Connecting-IP") or self.headers.get("X-Forwarded-For"):
            return self.send_json(403, {"ok": False, "error": "forbidden"})
        if self.client_address[0] != "127.0.0.1":
            return self.send_json(403, {"ok": False, "error": "forbidden"})
        want = bot_cfg().get("internal_secret") or ""
        got = self.headers.get("X-Bot-Secret", "") or ""
        if not want or not hmac.compare_digest(got.encode(), want.encode()):
            return self.send_json(403, {"ok": False, "error": "bad secret"})
        try:
            body = json.loads(raw.decode("utf-8") or "{}")
            if not isinstance(body, dict):
                raise ValueError("not an object")
        except Exception:
            return self.send_json(400, {"ok": False, "error": "bad json"})
        self.send_json(200, internal_dispatch(path, body))

    # ----- GET -----
    def do_GET(self):
        try:
            self._get()
        except Exception:
            self._error()

    def _get(self):
        path = urlparse(self.path).path
        if path == "/login":
            return self.login_page()
        s = self.sess()
        if not s:
            return self.go("/login")
        if path == "/":
            return self.dash(s)
        if path == "/account":
            return self.account_page(s)
        if path == "/users":
            if s["role"] != "admin":
                return self.send_html(403, layout(s, "Forbidden", "<h1>Admins only</h1>", "dash"))
            return self.users_page(s)
        mt = re.fullmatch(r"/bot/(" + BID_RE + r")(/log)?", path)
        if mt:
            bid = mt.group(1)
            m = meta_load(bid)
            if not m or m.get("id") != bid or not can_access(s, m):
                return self.send_html(404, layout(s, "Not found", "<h1>Bot not found</h1>", "dash"))
            if mt.group(2):
                return self.log_page(s, m, bid)
            return self.bot_page(s, m, bid)
        self.send_html(404, layout(s, "Not found", "<h1>Not found</h1>", "dash"))

    # ----- POST -----
    def do_POST(self):
        try:
            self._post()
        except Exception:
            self._error()

    def _post(self):
        path = urlparse(self.path).path
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        if path.startswith("/internal/"):
            if n > 65536:
                return self.send_json(413, {"ok": False, "error": "too large"})
            raw = self.rfile.read(n) if n > 0 else b""
            return self.internal_api(path, raw)
        limit = MAX_UPLOAD + 65536 if path == "/upload" else 65536
        if n > limit:
            return self.send_html(413, page("Too large", "<p class=center>Request too large (max 2 MB).</p>"))
        raw = self.rfile.read(n) if n > 0 else b""
        fields, files = parse_body(raw, self.headers.get("Content-Type", ""))
        if path == "/login":
            return self.do_login(fields)
        s = self.sess()
        if not s:
            return self.go("/login")
        if not hmac.compare_digest(fields.get("csrf", "").encode(), s["csrf"].encode()):
            return self.send_html(403, page("Forbidden", "<p class=center>Form expired. Reload the page and try again.</p>"))
        if path == "/logout":
            with LOCK:
                SESSIONS.pop(s["tok"], None)
            return self.go("/login", [("Set-Cookie", "sid=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict")])
        if path == "/upload":
            return self.do_upload(s, fields, files)
        if path == "/action":
            return self.do_action(s, fields)
        if path == "/users/action":
            return self.do_user_action(s, fields)
        if path == "/account/key":
            return self.do_own_key(s, fields)
        self.send_html(404, layout(s, "Not found", "<h1>Not found</h1>", "dash"))

    # ----- auth -----
    def login_page(self, err=""):
        e = "<div class='flash bad'>%s</div>" % esc(err) if err else ""
        bu = bot_cfg().get("username")
        bot = ""
        if bu:
            bot = ("<p class='center mut' style='font-size:13px;margin:10px 0 0'>Get or renew your key in Telegram: "
                   "<a href='https://t.me/%s' target=_blank rel=noopener style='color:#7dd3fc'>@%s</a></p>"
                   % (esc(bu), esc(bu)))
        body = ("<div class=auth><div class=authbox>"
                "<div class=center><span class=badge style='display:inline-grid;width:56px;height:56px;border-radius:18px'>"
                + BOLT_SVG.replace("<svg", "<svg style='width:28px;height:28px;fill:#0b0b1a'") +
                "</span><h1 style='margin-top:14px'>" + esc(PANEL_NAME) + "</h1>"
                "<p class='center mut' style='margin-top:0'>Userbot control panel · enter your access key</p>" + bot + "</div>" + e +
                "<div class=card><form method=post action=/login>"
                "<label>Access key</label>"
                "<input type=password name=key autocomplete=off autocapitalize=off spellcheck=false required placeholder='tbp_...'>"
                "<button class='btn pri wide'>Sign in</button></form>"
                "<p class='mut center' style='font-size:12.5px;margin:14px 0 0'>No key? Ask the admin on "
                "<a href='" + TG_URL + "' target=_blank rel=noopener style='color:#7dd3fc'>" + esc(TG_HANDLE) + "</a></p>"
                "</div>" + footer() + "</div></div>")
        self.send_html(200, page("TURBO CHANNEL · Login", body))

    def do_login(self, f):
        ip, now = self.ip(), time.time()
        with LOCK:
            if len(FAILS) > 5000:
                FAILS.clear()
            until = FAILS.get(ip, [0, 0])[1]
        if until > now:
            return self.send_html(429, page("Locked", "<p class=center>Too many attempts. Wait a few minutes.</p>"))
        name, rec = find_by_key(users_load(), f.get("key", ""))
        if not name or rec.get("disabled"):
            with LOCK:
                c, until = FAILS.get(ip, [0, 0])
                c += 1
                if c >= MAX_FAILS:
                    c, until = 0, now + LOCK_SECS
                FAILS[ip] = [c, until]
            sys.stderr.write("LOGIN FAILED from %s\n" % ip)
            time.sleep(1)
            return self.login_page("Invalid or disabled access key")
        if is_expired(rec):
            return self.login_page("Your key has expired. Renew it in the Telegram bot.")
        tok, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(24)
        with LOCK:
            FAILS.pop(ip, None)
            for k in [k for k, v in SESSIONS.items() if v["exp"] <= now]:
                SESSIONS.pop(k, None)
            SESSIONS[tok] = {"exp": now + SESSION_TTL, "csrf": csrf, "flash": None, "tok": tok,
                             "user": name, "role": rec.get("role", "user"), "reveal": None}
        cookie = "sid=%s; Path=/; HttpOnly; SameSite=Strict; Max-Age=%d%s" % (
            tok, SESSION_TTL, "; Secure" if self.secure() else "")
        sys.stderr.write("LOGIN OK %s from %s\n" % (name, ip))
        self.go("/", [("Set-Cookie", cookie)])

    # ----- pages -----
    def dash(self, s):
        admin = s["role"] == "admin"
        rec = users_load().get(s["user"], {})
        if admin:
            st = stats()
            mp = pct(st["mem_used"], st["mem_total"])
            dp = pct(st["disk_used"], st["disk_total"])
            cores = st["cores"]
            tun = "<span class='pill %s'>Tunnel %s</span>" % ("ok" if tunnel_up() else "bad", "up" if tunnel_up() else "down")
            bu = bot_cfg().get("username")
            bp = "<span class='pill %s'>Telegram bot %s</span>" % (("ok", "@" + esc(bu)) if (bu and bot_up()) else ("bad", "off"))
            top = ("<div class=kv style='margin-top:8px;display:flex;gap:8px;flex-wrap:wrap'>" + tun + bp + "</div>"
                   "<div class=grid style='margin-top:14px'>"
                   + tile("CPU load", "%.2f" % st["load1"], min(100, int(st["load1"] * 100 / cores)),
                          "%d cores · %s" % (cores, " ".join(st["load"])))
                   + tile("Memory", "%d%%" % mp, mp, "%s / %s" % (human(st["mem_used"]), human(st["mem_total"])))
                   + tile("Disk /", "%d%%" % dp, dp, "%s / %s" % (human(st["disk_used"]), human(st["disk_total"])))
                   + tile("Uptime", st["uptime"], None, st["host"]) + "</div>")
            bots = list_bots()
            heading = "All bots"
            sub = "Server health &amp; every userbot on this VPS"
        else:
            top = "<div class=grid style='margin-top:8px'>" + sub_tiles(rec) + quota_tiles(s["user"]) + "</div>"
            bots = list_bots(owner=s["user"])
            heading = "Your bots"
            sub = "Your time, coins, resources and userbots"
        rows = "".join(bot_row(m, admin) for m in bots) or "<div class=empty>No bots yet. Upload one below ↓</div>"
        body = ("<div class=hero><h1>Welcome, " + esc(s["user"]) + "</h1><div class=mut>" + sub + "</div></div>"
                "<div class=sec>Overview</div>" + top +
                "<div class=sec>" + heading + "</div><div class=card><div class=bots>" + rows + "</div></div>"
                "<div class=sec>Upload a bot</div>" + upload_card(s["csrf"]))
        self.send_html(200, layout(s, "TURBO CHANNEL · Dashboard", body, "dash"))

    def bot_page(self, s, m, bid):
        csrf = s["csrf"]
        label, cls = state_of(m)
        running = label == "Running"
        installing = m.get("status") == "installing"
        btns = ""
        if m.get("status") == "ready":
            if running:
                btns += act_form(csrf, bid, "restart", "Restart", "sm")
                btns += act_form(csrf, bid, "stop", "Stop", "sm dng")
            else:
                btns += act_form(csrf, bid, "start", "▶ Start", "sm ok")
        btns += act_form(csrf, bid, "reinstall", "Reinstall packages", "sm")
        btns += act_form(csrf, bid, "delete", "Delete", "sm dng",
                         "<label class=mini><input type=checkbox name=confirm value=yes required> confirm</label>")
        spin = "<span class=spin>◌</span> " if installing else ""
        pills = "".join("<span class=tag2>%s</span>" % esc(p) for p in m.get("installed", [])) or "<span class=mut>none</span>"
        blk = "".join("<span class='tag2 blk'>%s</span>" % esc(p) for p in m.get("blocked", []))
        blk_note = ("<div class=kv style='margin-top:10px'>Skipped by policy (never installed):</div>" + blk) if blk else ""
        viol = m.get("violations") or []
        viol_html = ""
        if viol:
            viol_html = ("<div class=sec>Scanner findings</div><div class=card><pre class=log>"
                         + esc("\n".join(viol)) + "</pre></div>")
        extra_form = ("<form method=post action=/action>"
                      "<input type=hidden name=csrf value='" + esc(csrf) + "'>"
                      "<input type=hidden name=id value='" + bid + "'>"
                      "<input type=hidden name=act value='extra'>"
                      "<label>Extra packages (names only, space separated)</label>"
                      "<input type=text name=extra value='" + esc(" ".join(m.get("extra", []))) + "' placeholder='e.g. aiohttp requests'>"
                      "<button class='btn pri'>Save &amp; reinstall</button></form>")
        logs = colorize(tail(os.path.join(bdir(bid), "bot.log"), 40))
        refresh = 3 if installing else 0
        body = ("<h1>" + esc(m.get("name", "")) + "</h1>"
                "<div class=mut>" + esc(m.get("kind", "").upper()) + " bot · owner <b>" + esc(m.get("owner", "")) +
                "</b> · id " + bid + "</div>"
                "<div class=sec>Status</div><div class=card>"
                "<div style='display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:10px'>"
                "<div>" + spin + "<span class='pill " + cls + "'>" + esc(label) + "</span></div>"
                "<div class=kv>PID <b>" + esc(m.get("pid") or "-") + "</b></div></div>"
                "<div class=kv style='margin-top:8px'>" + esc(m.get("msg", "")) + "</div>"
                "<div class=acts style='margin-top:12px'>" + btns + "</div></div>"
                "<div class=sec>Packages</div><div class=card>" + pills + blk_note + "</div>"
                + viol_html +
                "<div class=sec>Extra packages</div><div class=card>" + extra_form + "</div>"
                "<div class=sec>Logs</div><div class=acts style='margin-bottom:8px'>"
                "<a class=btn href='/bot/" + bid + "/log'>Full log</a><a class=btn href='/bot/" + bid + "'>Refresh</a></div>"
                "<pre class=log>" + logs + "</pre>"
                "<div style='margin-top:18px'><a class=btn href='/'>← Dashboard</a></div>")
        self.send_html(200, layout(s, "TURBO CHANNEL · " + m.get("name", ""), body, "dash", refresh))

    def log_page(self, s, m, bid):
        label, _ = state_of(m)
        refresh = 5 if label == "Running" or m.get("status") == "installing" else 0
        body = ("<h1>Logs · " + esc(m.get("name", "")) + "</h1><div class=mut>Last 300 lines · errors highlighted</div>"
                "<div class=acts style='margin:14px 0'><a class=btn href='/bot/" + bid + "'>← Back</a>"
                "<a class=btn href='/bot/" + bid + "/log'>Refresh</a></div>"
                "<pre class=log>" + colorize(tail(os.path.join(bdir(bid), "bot.log"), 300)) + "</pre>")
        self.send_html(200, layout(s, "TURBO CHANNEL · Logs", body, "dash", refresh))

    def account_page(self, s):
        rec = users_load().get(s["user"], {})
        wait = key_wait_left(rec)
        head = ("<div class=hero><h1>Account</h1><div class=mut>Signed in as <b>" + esc(s["user"]) + "</b> · "
                + esc(s["role"]) + "</div></div>" + reveal_box(s))
        if s["role"] != "admin":
            head += ("<div class=sec>My time &amp; resources</div><div class=grid>"
                     + sub_tiles(rec) + quota_tiles(s["user"]) + "</div>")
        if wait > 0:
            key_box = ("<p class=mut style='margin-top:0'>Key ထုတ်ခွင့် တစ်နေ့ တစ်ကြိမ်သာ ရှိပါတယ်။ "
                       "<b>%s</b> အကြာမှ ထုတ်လို့ရပါမယ်။</p>"
                       "<button class='btn wide' disabled>Generate new key (locked)</button>" % esc(fmt_wait(wait)))
        else:
            key_box = ("<p class=mut style='margin-top:0'>Lost your key? Generate a new one. Your old key and your other "
                       "sessions stop working immediately. <b>Once per 24 hours.</b></p>"
                       "<form method=post action=/account/key>"
                       "<input type=hidden name=csrf value='" + esc(s["csrf"]) + "'>"
                       "<label class=chk><input type=checkbox name=confirm value=yes required> I understand my current key will stop working</label>"
                       "<button class='btn pri wide'>Generate new key</button></form>")
        body = head + "<div class=sec>My access key</div><div class=card>" + key_box + "</div>"
        self.send_html(200, layout(s, "TURBO CHANNEL · Account", body, "acct"))

    def users_page(self, s):
        users = users_load()
        csrf = s["csrf"]
        cards = ""
        for name in sorted(users):
            r = users[name]
            nb = len(list_bots(owner=name))
            ram = owner_ram_used(name) if r.get("role") != "admin" else 0
            disk = user_disk(name) if r.get("role") != "admin" else 0
            cards += ucard(name, r, csrf, name == s["user"], nb, ram, disk)
        create = ("<div class=card><form method=post action=/users/action>"
                  "<input type=hidden name=csrf value='" + esc(csrf) + "'>"
                  "<input type=hidden name=act value='create'>"
                  "<label>Username (a-z, 0-9, _ . - · 3-32 chars)</label>"
                  "<input type=text name=user autocomplete=off required>"
                  "<label>Role</label><select name=role><option value=user>User</option><option value=admin>Admin</option></select>"
                  "<button class='btn pri wide'>Create account &amp; generate key</button></form></div>")
        body = ("<div class=hero><h1>Users</h1><div class=mut>Quota per user: RAM "
                + str(QUOTA_RAM_MB) + " MB · CPU " + str(QUOTA_CPU) + " core · Disk " + str(QUOTA_DISK_MB) + " MB · "
                + str(COIN_PER_DAY) + " coin = 1 day</div></div>"
                + reveal_box(s) + "<div class=sec>Accounts</div><div class=ugrid>" + cards + "</div>"
                "<div class=sec>New account</div>" + create)
        self.send_html(200, layout(s, "TURBO CHANNEL · Users", body, "users"))

    # ----- actions -----
    def do_upload(self, s, f, files):
        up = files.get("file")
        if not up or not up[0]:
            return self.flash_go(s, "bad", "No file selected", "/")
        fname, data = up
        if len(data) > MAX_UPLOAD:
            return self.flash_go(s, "bad", "File is larger than 2 MB", "/")
        base = os.path.basename(fname)[:80]
        ext = os.path.splitext(base)[1].lower()
        if ext not in (".py", ".js"):
            return self.flash_go(s, "bad", "Only .py or .js files are allowed", "/")
        if b"\x00" in data:
            return self.flash_go(s, "bad", "Not a text file", "/")
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            return self.flash_go(s, "bad", "File must be UTF-8 text", "/")
        if s["role"] != "admin" and user_disk(s["user"]) + len(data) > QUOTA_DISK_MB * MB:
            return self.flash_go(s, "bad", "Disk quota exceeded (%d MB) - delete a bot first" % QUOTA_DISK_MB, "/")
        kind = "py" if ext == ".py" else "js"
        try:
            viol, _ = analyze(kind, text)
        except ValueError as e:
            return self.flash_go(s, "bad", str(e), "/")
        if viol:
            strikes, banned = add_strike(s["user"])
            if banned:
                return self.flash_go(s, "bad", "Account banned after %d violations - contact the admin" % STRIKE_LIMIT, "/")
            return self.flash_go(s, "bad", "Blocked by code scanner (%d/%d): %s"
                                 % (strikes, STRIKE_LIMIT, viol[0][:120]), "/")

        bid = secrets.token_hex(6)
        d = bdir(bid)
        os.makedirs(d, mode=0o755)
        fname_on_disk = "bot" + ext
        with open(os.path.join(d, fname_on_disk), "wb") as fh:
            fh.write(data)
        m = {"id": bid, "name": base, "file": fname_on_disk, "kind": kind, "status": "installing",
             "msg": "Queued", "installed": [], "blocked": [], "deps": [], "extra": [], "violations": [],
             "owner": s["user"], "pid": None, "enabled": False, "restarts": 0, "created": time.time()}
        with LOCK:
            meta_save(bid, m)
        harden(bid)
        autostart = bool(f.get("autostart"))
        threading.Thread(target=install_worker, args=(bid, autostart), daemon=True).start()
        self.go("/bot/" + bid)

    def do_action(self, s, f):
        bid, act = f.get("id", ""), f.get("act", "")
        if not re.fullmatch(BID_RE, bid):
            return self.flash_go(s, "bad", "Bad bot id", "/")
        m = meta_load(bid)
        if not m or m.get("id") != bid or not can_access(s, m):
            return self.flash_go(s, "bad", "Bot not found", "/")
        back = "/bot/" + bid
        if act == "start":
            ok, msg = start_bot(bid)
            return self.flash_go(s, "ok" if ok else "bad", msg, back)
        if act == "stop":
            stop_bot(bid)
            return self.flash_go(s, "ok", "Stopped", back)
        if act == "restart":
            stop_bot(bid)
            ok, msg = start_bot(bid)
            return self.flash_go(s, "ok" if ok else "bad", msg, back)
        if act in ("reinstall", "extra"):
            if act == "extra":
                names = [x for x in re.split(r"[\s,]+", f.get("extra", "")) if x]
                bad = [x for x in names if not PKG_RE.match(x)]
                if bad:
                    return self.flash_go(s, "bad", "Invalid package name: " + ", ".join(bad)[:120], back)
                if len(names) > 30:
                    return self.flash_go(s, "bad", "Too many packages (max 30)", back)
                extra = sorted(set(names))
            else:
                extra = m.get("extra", [])
            was_on = bool(m.get("enabled"))
            stop_bot(bid)
            meta_update(bid, extra=extra, status="installing", msg="Queued", installed=[], blocked=[], violations=[])
            threading.Thread(target=install_worker, args=(bid, was_on), daemon=True).start()
            return self.flash_go(s, "ok", "Installing packages - this can take a few minutes", back)
        if act == "delete":
            if f.get("confirm") != "yes":
                return self.flash_go(s, "bad", "Tick 'confirm' to delete", back)
            stop_bot(bid)
            shutil.rmtree(bdir(bid), ignore_errors=True)
            drop_bot_user(bid)
            return self.flash_go(s, "ok", "Bot deleted", "/")
        return self.flash_go(s, "bad", "Unknown action", back)

    def do_user_action(self, s, f):
        if s["role"] != "admin":
            return self.flash_go(s, "bad", "Admins only", "/")
        act = f.get("act", "")
        name = f.get("user", "").strip().lower()
        back = "/users"

        if act == "create":
            role = f.get("role", "user")
            if not valid_name(name):
                return self.flash_go(s, "bad", "Invalid username (3-32 chars: a-z, 0-9, _ . -)", back)
            if role not in ("user", "admin"):
                role = "user"

            def create(users):
                if name in users:
                    return None
                users[name] = new_record(role)
                return issue_key(users[name])
            key = users_mutate(create)
            if key is None:
                return self.flash_go(s, "bad", "Username already exists", back)
            if role != "admin":
                cg_setup(name)
            with LOCK:
                s["reveal"] = (name, key)
            return self.flash_go(s, "ok", "Account created - key shown below (once)", back)

        users = users_load()
        if name not in users:
            return self.flash_go(s, "bad", "User not found", back)

        if act == "coins":
            try:
                amount = int(f.get("amount", "0"))
            except ValueError:
                return self.flash_go(s, "bad", "Amount must be a whole number", back)
            if amount == 0 or abs(amount) > 100000:
                return self.flash_go(s, "bad", "Amount must be between -100000 and 100000 (not 0)", back)
            new = add_coins(name, amount)
            return self.flash_go(s, "ok", "%s now has %d coins" % (name, new), back)

        if name == s["user"]:
            return self.flash_go(s, "bad", "Use the Account page for your own key", back)
        rec = users[name]
        admins_on = active_admins(users)
        is_last_admin = rec.get("role") == "admin" and name in admins_on and len(admins_on) == 1

        if act == "reset":
            key = users_mutate(lambda u: issue_key(u[name]))
            kill_sessions(name)
            with LOCK:
                s["reveal"] = (name, key)
            return self.flash_go(s, "ok", "New key generated - give it to the user (shown once)", back)

        if act == "toggle":
            if not rec.get("disabled") and is_last_admin:
                return self.flash_go(s, "bad", "Cannot ban the last active admin", back)

            def toggle(u):
                u[name]["disabled"] = not u[name].get("disabled")
                if not u[name]["disabled"]:
                    u[name]["strikes"] = 0
                return u[name]["disabled"]
            banned = users_mutate(toggle)
            if banned:
                for m in list_bots(owner=name):
                    stop_bot(m["id"])
                kill_sessions(name)
                return self.flash_go(s, "ok", "Banned " + name, back)
            return self.flash_go(s, "ok", "Unbanned " + name + " (strikes reset)", back)

        if act == "role":
            new_role = "user" if rec.get("role") == "admin" else "admin"
            if new_role == "user" and is_last_admin:
                return self.flash_go(s, "bad", "Cannot demote the last active admin", back)

            def setrole(u):
                u[name]["role"] = new_role
            users_mutate(setrole)
            return self.flash_go(s, "ok", name + " is now " + new_role, back)

        if act == "delete":
            if f.get("confirm") != "yes":
                return self.flash_go(s, "bad", "Tick 'confirm' to delete", back)
            if is_last_admin:
                return self.flash_go(s, "bad", "Cannot delete the last active admin", back)
            for m in list_bots(owner=name):
                stop_bot(m["id"])
                shutil.rmtree(bdir(m["id"]), ignore_errors=True)
                drop_bot_user(m["id"])

            def drop(u):
                u.pop(name, None)
            users_mutate(drop)
            kill_sessions(name)
            d = cg_dir(name)
            if os.path.isdir(d):
                try:
                    os.rmdir(d)
                except OSError:
                    pass
            return self.flash_go(s, "ok", "Account and its bots deleted", back)

        return self.flash_go(s, "bad", "Unknown action", back)

    def do_own_key(self, s, f):
        if f.get("confirm") != "yes":
            return self.flash_go(s, "bad", "Tick the confirmation box first", "/account")
        result = {"ok": False, "msg": ""}

        def fn(users):
            rec = users.get(s["user"])
            if not rec or rec.get("disabled"):
                result["msg"] = "Account unavailable"
                return None
            wait = key_wait_left(rec)
            if wait > 0:
                result["msg"] = "Key can be issued once per day. Try again in %s." % fmt_wait(wait)
                return None
            result["ok"] = True
            return issue_key(rec)

        key = users_mutate(fn)
        if not result["ok"]:
            return self.flash_go(s, "bad", result["msg"], "/account")
        kill_sessions(s["user"], keep=s["tok"])
        with LOCK:
            s["reveal"] = (s["user"], key)
        self.go("/account")


# =====================================================
#  CLI
# =====================================================
def cli_new_key(name):
    name = name.strip().lower()
    if not valid_name(name):
        sys.exit("Invalid username (3-32 chars: a-z, 0-9, _ . -)")

    def fn(users):
        if name not in users:
            users[name] = new_record("admin")
        rec = users[name]
        rec["disabled"] = False
        return rec.get("role"), issue_key(rec)
    role, key = users_mutate(fn)
    print("")
    print("Access key for '%s' (role: %s) - shown ONCE, save it now:" % (name, role))
    print(key)
    print("")


def read_input(prompt, secret=False):
    if sys.stdin.isatty():
        return getpass.getpass(prompt) if secret else input(prompt)
    return sys.stdin.read().strip()


def cli_bot_token():
    t = read_input("Bot token (from @BotFather): ", secret=True)
    if not TOKEN_RE.fullmatch(t or ""):
        sys.exit("That does not look like a bot token")
    bot_cfg_update(token=t)
    print("Bot token saved (config.json, root only).")


def cli_bot_admin(x):
    if not x.isdigit():
        sys.exit("Telegram ID must be a number")
    ids = set(int(i) for i in bot_cfg().get("admins", []) if str(i).isdigit())
    ids.add(int(x))
    bot_cfg_update(admins=sorted(ids))
    print("Admins: %s" % ", ".join(str(i) for i in sorted(ids)))


def cli_bot_set(key, val):
    if key == "channel" and not CHANNEL_RE.fullmatch(val):
        sys.exit("Channel must look like @username")
    if key == "panel_url" and not val.startswith("https://"):
        sys.exit("Panel URL must start with https://")
    bot_cfg_update(**{key: val})
    print("%s saved" % key)


def cli_ref_reward(v):
    if not v.isdigit() or int(v) > 100:
        sys.exit("Reward must be a number between 0 and 100")
    bot_cfg_update(ref_reward=int(v))
    print("Referral reward: %s coin per invite" % v)


def cli_bot_status():
    b = dict(bot_cfg())
    b["token"] = "set" if b.get("token") else "not set"
    b["internal_secret"] = "set" if b.get("internal_secret") else "not set"
    print(json.dumps(b, indent=2, ensure_ascii=False))


# =====================================================
#  Entry point
# =====================================================
def main():
    if sys.version_info < (3, 10):
        sys.exit("TURBO CHANNEL needs Python 3.10 or newer")
    a = sys.argv
    cmd = a[1] if len(a) > 1 else ""
    if cmd in ("--set-password", "--new-key") and len(a) == 3:
        os.makedirs(HOME, mode=0o700, exist_ok=True)
        return cli_new_key(a[2])
    if cmd == "--bot-token":
        os.makedirs(HOME, mode=0o700, exist_ok=True)
        return cli_bot_token()
    if cmd == "--bot-admin" and len(a) == 3:
        os.makedirs(HOME, mode=0o700, exist_ok=True)
        return cli_bot_admin(a[2])
    if cmd == "--bot-channel" and len(a) == 3:
        os.makedirs(HOME, mode=0o700, exist_ok=True)
        return cli_bot_set("channel", a[2])
    if cmd == "--panel-url" and len(a) == 3:
        os.makedirs(HOME, mode=0o700, exist_ok=True)
        return cli_bot_set("panel_url", a[2])
    if cmd == "--ref-reward" and len(a) == 3:
        os.makedirs(HOME, mode=0o700, exist_ok=True)
        return cli_ref_reward(a[2])
    if cmd == "--bot-status":
        return cli_bot_status()

    os.makedirs(BOTS, mode=0o711, exist_ok=True)
    if IS_ROOT:
        os.chmod(HOME, 0o711)
        os.chmod(BOTS, 0o711)
    users = users_load()
    admins = active_admins(users)
    if not admins:
        sys.exit("No active admin key. Run: sudo python3 app.py --set-password admin")
    first_admin = sorted(admins)[0]
    for m in list_bots():
        upd = {}
        if not m.get("owner"):
            upd["owner"] = first_admin
        if m.get("status") == "installing":
            upd.update(status="error", msg="Interrupted - click 'Reinstall packages'")
        if upd:
            meta_update(m["id"], **upd)
        if IS_ROOT:
            ensure_bot_user(m["id"])
            harden(m["id"])
    if IS_ROOT:
        for name, rec in users.items():
            if rec.get("role") != "admin":
                cg_setup(name)
        if not cg_ready_host():
            print("NOTE: cgroup v2 not available - RAM/CPU quota runs in SOFT mode", flush=True)
    else:
        print("NOTE: not running as root - bots run as this user; quotas are SOFT", flush=True)

    ensure_internal_secret()
    print("Telegram bot runs as separate service: tb-bot", flush=True)

    threading.Thread(target=watchdog, daemon=True).start()
    print("TURBO CHANNEL V %s · Userbot Web Panel · http://127.0.0.1:%d" % (VERSION, PORT), flush=True)
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
