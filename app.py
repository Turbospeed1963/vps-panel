#!/usr/bin/env python3
# =====================================================
#  TBP - Userbot Web Panel v2.1  (single file, Python 3.10+ stdlib only)
#  - Key login (no passwords): admin issues one access key per user, shown once
#  - Users upload .py / .js bots; packages auto-installed per bot
#  - Code scanner rejects bot-hosting, server-control and malware patterns
#  - Bots run as unprivileged system user 'tbpbot' when panel runs as root
#  - POLICY: opencv-python*, numpy, ddddocr are NEVER installed
#  Listens on 127.0.0.1 only. Publish via Cloudflare Tunnel.
#  Admin key:  sudo python3 app.py --set-password admin   (same as --new-key admin)
#  Run:        sudo python3 app.py   ->  http://127.0.0.1:8787
# =====================================================
import ast, hashlib, hmac, html, json, os, pwd, re, secrets, shutil, signal, subprocess, sys, threading, time, traceback
from http.cookies import CookieError, SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

VERSION = "2.1"
HOME = os.environ.get("TBP_HOME", "/opt/tb-panel")
CONF = os.path.join(HOME, "config.json")
BOTS = os.path.join(HOME, "bots")
PORT = int(os.environ.get("TBP_PORT", "8787"))
BOT_USER = "tbpbot"
BOT_RUN_AS = None              # set at startup when running as root
MAX_UPLOAD = 2 * 1024 * 1024
SESSION_TTL = 8 * 3600
MAX_FAILS, LOCK_SECS = 5, 300
MAX_RESTARTS = 5

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

# ---- code scanner rules: (category, regex), checked line by line ----
RULES = [
    ("hosting", r"\b(tb-panel|vps-panel|vps-webpanel|TBP_HOME|TBP_PORT|config\.json|meta\.json)\b|/opt/(tb-panel|vps-webpanel)"),
    ("hosting", r"\bbots/|\bbot\.log\b"),
    ("hosting", r"\b(systemctl|journalctl|cloudflared|iptables|nginx|sshd|ufw)\b|/etc/(shadow|sudoers|passwd|ssh/)"),
    ("hosting", r"\b(subprocess|os\.system|os\.popen|os\.spawn\w*|Popen|check_output|check_call|child_process|execSync|execFile|spawn|nohup|setsid)\b.*\b(python3?|node|npm|npx|bash|sh|nohup|setsid)\b"),
    ("malware", r"/dev/(tcp|udp)/|\bbash\s+-i\b|\b(nc|ncat|netcat|socat)\b.*\s-(e|c)\b|\bmkfifo\b"),
    ("malware", r"\brm\s+-rf\s+/(\s|$|\*)|\bmkfs(\.\w+)?\b|\bdd\s+if=|:\(\)\s*\{"),
    ("malware", r"xmrig|stratum\+|minexmr|nanopool|nicehash|cryptonight|coinhive"),
    ("malware", r"\b(curl|wget)\b[^|\n]*\|\s*(sudo\s+)?(sh|bash)\b"),
    ("malware", r"\b(exec|eval)\s*\(.*(b64decode|base64|zlib\.decompress|marshal\.loads|codecs\.decode|fromhex|atob\(|Buffer\.from)"),
    ("malware", r"\bchmod\s+(\+s|u\+s)\b"),
]
RULES_C = [(cat, re.compile(rx, re.I)) for cat, rx in RULES]


# ---------- policy helpers ----------
def blocked(name):
    n = name.lower().replace("_", "-")
    return n in BLOCK_EXACT or n.startswith(BLOCK_PREFIX)


def split_blocked(names):
    ok, bad = [], []
    for n in names:
        (bad if blocked(n) else ok).append(n)
    return ok, bad


# ---------- small helpers ----------
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
        os.unlink(tmp)                      # never write through a leftover symlink
    except FileNotFoundError:
        pass
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False)
    os.replace(tmp, p)


def read_text(p):
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.read()


# ---------- access keys / accounts ----------
def key_digest(secret):
    return hashlib.sha256(secret.encode("utf-8")).hexdigest()


def issue_key(rec):
    """Creates a new key for the account record (in place). Returns the full key once."""
    kid = secrets.token_hex(4)               # public id, used for lookup
    secret = secrets.token_urlsafe(32)       # private part, never stored
    rec.pop("salt", None)
    rec.pop("hash", None)
    rec.update(key_id=kid, key_hash=key_digest(secret))
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


def new_record(role):
    return {"role": role, "disabled": False, "created": time.time()}


def valid_name(n):
    return bool(NAME_RE.fullmatch(n))


def users_load():
    conf = read_json(CONF, {})
    users = conf.get("users")
    if isinstance(users, dict):
        return users
    if conf.get("user"):                      # migrate v1 single-admin config (no key yet)
        return {conf["user"]: new_record("admin")}
    return {}


def users_save(users):
    write_json(CONF, {"users": users})


def active_admins(users):
    return [n for n, r in users.items() if r.get("role") == "admin" and not r.get("disabled") and has_key(r)]


def cli_new_key(name):
    name = name.strip().lower()
    if not valid_name(name):
        sys.exit("Invalid username (3-32 chars: a-z, 0-9, _ . -)")
    users = users_load()
    if name not in users:
        users[name] = new_record("admin")
    rec = users[name]
    rec["disabled"] = False
    key = issue_key(rec)
    users_save(users)
    print("")
    print("Access key for '%s' (role: %s) - shown ONCE, save it now:" % (name, rec.get("role")))
    print(key)
    print("")


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


# ---------- bot storage ----------
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


def harden(bid):
    """Root owns everything in the bot folder; only work/ is writable by the bot user."""
    d = bdir(bid)
    os.chmod(d, 0o755)
    for name in os.listdir(d):
        p = os.path.join(d, name)
        if os.path.islink(p) or os.path.isdir(p):
            continue
        secret = name == "meta.json" or name.startswith("bot.log") or name == "meta.json.tmp"
        os.chmod(p, 0o600 if secret else 0o644)


def prep_workdir(bid):
    w = workdir(bid)
    os.makedirs(w, mode=0o700, exist_ok=True)
    if BOT_RUN_AS and os.geteuid() == 0:
        pw = pwd.getpwnam(BOT_RUN_AS)
        os.chown(w, pw.pw_uid, pw.pw_gid)
    os.chmod(w, 0o700)


# ---------- code scanner ----------
def analyze(kind, src):
    """Returns (violations, imports). Raises ValueError on Python syntax errors."""
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


# ---------- installers ----------
def apt_install(pkgs):
    if os.geteuid() != 0:
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
    with open(cons, "w") as f:
        f.write(CONSTRAINTS)
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
        write_json(pj, {"name": "tbp-bot", "private": True})
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
        if ok:
            note = "Ready" + (" · skipped by policy: " + ", ".join(bad) if bad else "")
            meta_update(bid, status="ready", msg=note, installed=good)
            ready = True
        else:
            meta_update(bid, status="error", msg=err or "Install failed", installed=[])
        harden(bid)
    except ValueError as e:
        meta_update(bid, status="error", msg=str(e)[:300], installed=[])
    except Exception as e:
        traceback.print_exc()
        meta_update(bid, status="error", msg="Unexpected error: %s" % str(e)[:200], installed=[])
    if ready and autostart:
        ok, msg = start_bot(bid)
        if not ok:
            meta_update(bid, msg=msg)


# ---------- process control ----------
def ensure_bot_user():
    if os.geteuid() != 0:
        return None
    try:
        pwd.getpwnam(BOT_USER)
    except KeyError:
        run_cmd(["useradd", "-r", "-M", "-d", "/nonexistent", "-s", "/usr/sbin/nologin", BOT_USER], timeout=60)
        try:
            pwd.getpwnam(BOT_USER)
        except KeyError:
            return None
    return BOT_USER


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


def start_bot(bid, manual=True):
    with LOCK:
        m = meta_load(bid)
        if not m:
            return False, "Bot not found"
        if m.get("status") != "ready":
            return False, m.get("msg") or "Not ready yet"
        if is_running(bid, m):
            return True, "Already running"
        as_root = os.geteuid() == 0
        if as_root and not BOT_RUN_AS:
            return False, "Sandbox user '%s' missing - bots will not run as root" % BOT_USER
        d = bdir(bid)
        harden(bid)
        prep_workdir(bid)
        target = os.path.join(d, m["file"])
        if m["kind"] == "py":
            cmd = [os.path.join(d, "venv", "bin", "python3"), target]
        else:
            cmd = [shutil.which("node") or "node", target]
        logp = os.path.join(d, "bot.log")
        try:
            if os.path.getsize(logp) > 5 * 1024 * 1024:
                os.replace(logp, logp + ".1")
        except OSError:
            pass
        env = {"PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"), "HOME": workdir(bid),
               "LANG": "C.UTF-8", "PYTHONUNBUFFERED": "1", "PYTHONDONTWRITEBYTECODE": "1"}
        kw = {"user": BOT_RUN_AS, "group": BOT_RUN_AS} if (as_root and BOT_RUN_AS) else {}
        try:
            fd = os.open(logp, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            with os.fdopen(fd, "ab") as lf:
                lf.write(("\n=== start %s ===\n" % time.strftime("%Y-%m-%d %H:%M:%S")).encode())
                p = subprocess.Popen(cmd, cwd=workdir(bid), env=env, stdin=subprocess.DEVNULL, stdout=lf,
                                     stderr=subprocess.STDOUT, start_new_session=True, **kw)
        except OSError as e:
            return False, "Could not start: %s" % str(e)[:200]
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


def watchdog():
    time.sleep(3)
    while True:
        try:
            for m in list_bots():
                bid = m["id"]
                if m.get("status") != "ready" or not m.get("enabled"):
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


# ---------- multipart / form parsing ----------
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


# ---------- UI ----------
CSS = """
:root{color-scheme:dark;--bg:#07070f;--card:rgba(20,22,40,.72);--line:rgba(120,130,200,.18);--txt:#eef0ff;--mut:#8b90b8;--c1:#22d3ee;--c2:#a78bfa;--c3:#f472b6;--ok:#34d399;--bad:#fb7185;--warn:#fbbf24;--info:#60a5fa}
*{box-sizing:border-box}html,body{margin:0}
body{font:15px/1.55 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;color:var(--txt);min-height:100vh;background:radial-gradient(900px 500px at 95% -10%,rgba(167,139,250,.28),transparent 60%),radial-gradient(800px 480px at -10% 0,rgba(34,211,238,.22),transparent 55%),radial-gradient(600px 400px at 50% 110%,rgba(244,114,182,.15),transparent 60%),var(--bg);background-attachment:fixed}
main{max-width:900px;margin:0 auto;padding:16px 16px 48px}
header.top{display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:10px;margin-bottom:8px}
.brand{display:flex;align-items:baseline;gap:10px}
.logo{font-weight:900;font-size:22px;letter-spacing:.2em;background:linear-gradient(90deg,var(--c1),var(--c2),var(--c3));-webkit-background-clip:text;background-clip:text;color:transparent}
.tag{color:var(--mut);font-size:12px;letter-spacing:.14em;text-transform:uppercase}
nav{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
nav a{color:var(--mut);text-decoration:none;padding:6px 12px;border-radius:999px;font-weight:600;font-size:14px}
nav a.on{color:#fff;background:rgba(167,139,250,.2);box-shadow:inset 0 0 0 1px rgba(167,139,250,.5)}
h1{font-size:22px;margin:14px 0 4px}
h2{font-size:12px;letter-spacing:.14em;text-transform:uppercase;color:var(--mut);margin:26px 0 10px}
.mut{color:var(--mut)}.kv{color:var(--mut);font-size:13px}.kv b{color:var(--txt)}
.card{background:var(--card);border:1px solid var(--line);border-radius:18px;padding:16px;margin:10px 0;box-shadow:0 8px 30px rgba(0,0,0,.25)}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px;margin:14px 0}
.tile{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:14px}
.tl{color:var(--mut);font-size:11px;text-transform:uppercase;letter-spacing:.12em}
.tv{font-size:22px;font-weight:800;margin:2px 0}.ts{color:var(--mut);font-size:12px}
.bar{height:6px;border-radius:99px;background:rgba(255,255,255,.06);overflow:hidden;margin:8px 0 6px}
.bar i{display:block;height:100%;border-radius:99px}
.row{display:flex;justify-content:space-between;align-items:center;gap:10px;flex-wrap:wrap;padding:12px 0;border-bottom:1px solid var(--line)}
.row:last-child{border-bottom:0}
.name{font-weight:700;font-size:16px}
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
.btn.pri{border:0;color:#0b0b1a;background:linear-gradient(90deg,var(--c1),var(--c2));box-shadow:0 6px 20px rgba(34,211,238,.25)}
.btn.ok{background:rgba(52,211,153,.15);border-color:rgba(52,211,153,.45);color:#a7f3d0}
.btn.dng{background:rgba(251,113,133,.14);border-color:rgba(251,113,133,.45);color:#fecdd3}
.btn.ghost{background:transparent}.btn.sm{padding:5px 11px;font-size:13px}.wide{width:100%}
input[type=text],input[type=password],select{font:inherit;width:100%;padding:11px 13px;margin:5px 0 12px;border-radius:11px;border:1px solid var(--line);background:rgba(7,8,20,.8);color:var(--txt);font-family:ui-monospace,Menlo,Consolas,monospace}
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
.auth{min-height:88vh;display:flex;align-items:center;justify-content:center}
.authbox{width:100%;max-width:380px}.center{text-align:center}
.spin{display:inline-block;animation:sp 1s linear infinite}@keyframes sp{to{transform:rotate(360deg)}}
form{margin:0}.inline{display:inline}
footer{margin-top:30px;text-align:center;color:var(--mut);font-size:12px;letter-spacing:.12em}
"""


def page(title, body, refresh=0):
    meta = "<meta http-equiv=refresh content='%d'>" % refresh if refresh else ""
    return ("<!doctype html><html lang=en><head><meta charset=utf-8>"
            "<meta name=viewport content='width=device-width,initial-scale=1'>"
            "<meta name=robots content='noindex,nofollow'>" + meta +
            "<title>" + esc(title) + "</title><style>" + CSS + "</style></head>"
            "<body><main>" + body + "</main></body></html>")


def layout(s, title, body, active="", refresh=0):
    with LOCK:
        fl = s.pop("flash", None)
    flash = "<div class='flash %s'>%s</div>" % (fl[0], esc(fl[1])) if fl else ""
    links = [("dash", "/", "Dashboard")]
    if s["role"] == "admin":
        links.append(("users", "/users", "Users"))
    links.append(("acct", "/account", "Account"))
    nav = "".join("<a class='%s' href='%s'>%s</a>" % ("on" if k == active else "", h, t) for k, h, t in links)
    top = ("<header class=top><div class=brand><span class=logo>TBP</span><span class=tag>Userbot Panel</span></div>"
           "<nav>" + nav + "<span class=kv>" + esc(s["user"]) + " · " + esc(s["role"]) + "</span>"
           "<form method=post action=/logout><input type=hidden name=csrf value='" + esc(s["csrf"]) + "'>"
           "<button class='btn ghost sm'>Logout</button></form></nav></header>")
    foot = "<footer>TBP v%s</footer>" % VERSION
    return page(title, top + flash + body + foot, refresh)


def reveal_box(s):
    with LOCK:
        rv = s.pop("reveal", None)
    if not rv:
        return ""
    return ("<div class=reveal><b>Access key for " + esc(rv[0]) + "</b> "
            "<span class=mut>— copy it now, it will not be shown again</span>"
            "<code>" + esc(rv[1]) + "</code></div>")


def tile(label, value, p=None, sub=""):
    bar = ""
    if p is not None:
        c = "linear-gradient(90deg,#22d3ee,#a78bfa)" if p < 70 else ("#fbbf24" if p < 90 else "#fb7185")
        bar = "<div class=bar><i style='width:%d%%;background:%s'></i></div>" % (p, c)
    return ("<div class=tile><div class=tl>%s</div><div class=tv>%s</div>%s<div class=ts>%s</div></div>"
            % (esc(label), esc(value), bar, esc(sub)))


def bot_row(m, show_owner):
    label, cls = state_of(m)
    bid = m["id"]
    owner = (" · owner " + esc(m.get("owner", ""))) if show_owner else ""
    return ("<div class=row><div><div class=name><a href='/bot/%s' style='color:inherit;text-decoration:none'>%s</a></div>"
            "<div class=kv>%s%s · %s</div></div><div class=acts><span class='pill %s'>%s</span>"
            "<a class='btn sm' href='/bot/%s'>Open</a></div></div>"
            % (bid, esc(m.get("name", "")), esc(m.get("kind", "").upper()), owner, esc(m.get("msg", "")),
               cls, esc(label), bid))


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
            "shell/reverse-shell, miners and obfuscated exec.</div>"
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


# ---------- HTTP handler ----------
class H(BaseHTTPRequestHandler):
    server_version = "TBP"
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
        if not rec or rec.get("disabled") or not has_key(rec):
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
        body = ("<div class=auth><div class=authbox><div class=center><span class=logo>TBP</span></div>"
                "<p class='center mut'>Enter your access key</p>" + e +
                "<div class=card><form method=post action=/login>"
                "<label>Access key</label>"
                "<input type=password name=key autocomplete=off autocapitalize=off spellcheck=false required placeholder='tbp_...'>"
                "<button class='btn pri wide'>Sign in</button></form>"
                "<p class='mut center' style='font-size:12px;margin-top:12px'>No key? Ask the admin.</p>"
                "</div></div></div>")
        self.send_html(200, page("TBP · Login", body))

    def do_login(self, f):
        ip, now = self.ip(), time.time()
        with LOCK:
            if len(FAILS) > 5000:
                FAILS.clear()
            until = FAILS.get(ip, [0, 0])[1]
        if until > now:
            return self.send_html(429, page("Locked", "<p class=center>Too many attempts. Wait a few minutes.</p>"))
        users = users_load()
        name, rec = find_by_key(users, f.get("key", ""))
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
        tiles = ""
        if admin:
            st = stats()
            mp = pct(st["mem_used"], st["mem_total"])
            dp = pct(st["disk_used"], st["disk_total"])
            cores = st["cores"]
            tiles = ("<div class=grid>"
                     + tile("CPU load", "%.2f" % st["load1"], min(100, int(st["load1"] * 100 / cores)),
                            "%d cores · %s" % (cores, " ".join(st["load"])))
                     + tile("Memory", "%d%%" % mp, mp, "%s / %s" % (human(st["mem_used"]), human(st["mem_total"])))
                     + tile("Disk /", "%d%%" % dp, dp, "%s / %s" % (human(st["disk_used"]), human(st["disk_total"])))
                     + tile("Uptime", st["uptime"], None, st["host"]) + "</div>")
        bots = list_bots() if admin else list_bots(owner=s["user"])
        rows = "".join(bot_row(m, admin) for m in bots) or "<div class=empty>No bots yet. Upload one below ↓</div>"
        heading = "All bots" if admin else "Your bots"
        body = ("<h1>Dashboard</h1><div class=mut>" + ("Server health &amp; all userbots" if admin else "Your userbots") + "</div>"
                + tiles + "<h2>" + heading + "</h2><div class=card>" + rows + "</div>"
                "<h2>Upload a bot</h2>" + upload_card(s["csrf"]))
        self.send_html(200, layout(s, "TBP · Dashboard", body, "dash"))

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
            viol_html = ("<h2>Scanner findings</h2><div class=card><pre class=log>" + esc("\n".join(viol)) + "</pre></div>")
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
                "<h2>Status</h2><div class=card>"
                "<div class=row><div>" + spin + "<span class='pill " + cls + "'>" + esc(label) + "</span></div>"
                "<div class=kv>PID <b>" + esc(m.get("pid") or "-") + "</b></div></div>"
                "<div class=kv style='margin-top:8px'>" + esc(m.get("msg", "")) + "</div>"
                "<div class=acts style='margin-top:12px'>" + btns + "</div></div>"
                "<h2>Packages</h2><div class=card>" + pills + blk_note + "</div>"
                + viol_html +
                "<h2>Extra packages</h2><div class=card>" + extra_form + "</div>"
                "<h2>Logs</h2><div class=acts style='margin-bottom:8px'>"
                "<a class=btn href='/bot/" + bid + "/log'>Full log</a><a class=btn href='/bot/" + bid + "'>Refresh</a></div>"
                "<pre class=log>" + logs + "</pre>"
                "<div style='margin-top:16px'><a class=btn href='/'>← Dashboard</a></div>")
        self.send_html(200, layout(s, "TBP · " + m.get("name", ""), body, "dash", refresh))

    def log_page(self, s, m, bid):
        label, _ = state_of(m)
        refresh = 5 if label == "Running" or m.get("status") == "installing" else 0
        body = ("<h1>Logs · " + esc(m.get("name", "")) + "</h1><div class=mut>Last 300 lines · errors highlighted</div>"
                "<div class=acts style='margin:14px 0'><a class=btn href='/bot/" + bid + "'>← Back</a>"
                "<a class=btn href='/bot/" + bid + "/log'>Refresh</a></div>"
                "<pre class=log>" + colorize(tail(os.path.join(bdir(bid), "bot.log"), 300)) + "</pre>")
        self.send_html(200, layout(s, "TBP · Logs", body, "dash", refresh))

    def account_page(self, s):
        body = ("<h1>Account</h1><div class=mut>Signed in as <b>" + esc(s["user"]) + "</b> · " + esc(s["role"]) + "</div>"
                + reveal_box(s) +
                "<h2>My access key</h2><div class=card>"
                "<p class=mut style='margin-top:0'>Lost your key? Generate a new one. Your old key and your other "
                "sessions stop working immediately.</p>"
                "<form method=post action=/account/key>"
                "<input type=hidden name=csrf value='" + esc(s["csrf"]) + "'>"
                "<label class=chk><input type=checkbox name=confirm value=yes required> I understand my current key will stop working</label>"
                "<button class='btn pri wide'>Generate new key</button></form></div>")
        self.send_html(200, layout(s, "TBP · Account", body, "acct"))

    def users_page(self, s):
        users = users_load()
        counts = {}
        for m in list_bots():
            counts[m.get("owner")] = counts.get(m.get("owner"), 0) + 1
        csrf = s["csrf"]
        rows = ""
        for name in sorted(users):
            r = users[name]
            me = name == s["user"]
            is_admin = r.get("role") == "admin"
            disabled = bool(r.get("disabled"))
            badge = "<span class='pill info'>admin</span>" if is_admin else "<span class='pill mut'>user</span>"
            status = "<span class='pill bad'>disabled</span>" if disabled else "<span class='pill ok'>active</span>"
            if not has_key(r):
                status += " <span class='pill warn'>no key</span>"
            if me:
                acts = "<span class=kv>(you — use Account page)</span>"
            else:
                acts = ufm(csrf, "reset", name, "New key", "sm")
                acts += ufm(csrf, "toggle", name, "Enable" if disabled else "Disable", "sm" if disabled else "sm dng")
                acts += ufm(csrf, "role", name, "Make user" if is_admin else "Make admin", "sm")
                acts += ufm(csrf, "delete", name, "Delete", "sm dng",
                            "<label class=mini><input type=checkbox name=confirm value=yes required> confirm</label>")
            rows += ("<div class=row><div><div class=name>" + esc(name) + " " + badge + "</div>"
                     "<div class=kv>bots: <b>" + str(counts.get(name, 0)) + "</b> · created " + fmt_time(r.get("created")) +
                     "</div></div><div class=acts>" + status + " " + acts + "</div></div>")
        create = ("<div class=card><form method=post action=/users/action>"
                  "<input type=hidden name=csrf value='" + esc(csrf) + "'>"
                  "<input type=hidden name=act value='create'>"
                  "<label>Username (a-z, 0-9, _ . - · 3-32 chars)</label>"
                  "<input type=text name=user autocomplete=off required>"
                  "<label>Role</label><select name=role><option value=user>User</option><option value=admin>Admin</option></select>"
                  "<button class='btn pri wide'>Create account &amp; generate key</button></form></div>")
        body = ("<h1>Users</h1><div class=mut>Create accounts, issue access keys, disable or delete users</div>"
                + reveal_box(s) + "<h2>Accounts</h2><div class=card>" + rows + "</div>"
                "<h2>New account</h2>" + create)
        self.send_html(200, layout(s, "TBP · Users", body, "users"))

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
        kind = "py" if ext == ".py" else "js"
        try:
            viol, _ = analyze(kind, text)
        except ValueError as e:
            return self.flash_go(s, "bad", str(e), "/")
        if viol:
            return self.flash_go(s, "bad", "Blocked by code scanner: " + viol[0][:150], "/")

        bid = secrets.token_hex(6)
        fname_on_disk = "bot" + ext
        d = bdir(bid)
        os.makedirs(d, mode=0o755)
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
            return self.flash_go(s, "ok", "Bot deleted", "/")
        return self.flash_go(s, "bad", "Unknown action", back)

    def do_user_action(self, s, f):
        if s["role"] != "admin":
            return self.flash_go(s, "bad", "Admins only", "/")
        act = f.get("act", "")
        name = f.get("user", "").strip().lower()
        users = users_load()
        back = "/users"

        if act == "create":
            role = f.get("role", "user")
            if not valid_name(name):
                return self.flash_go(s, "bad", "Invalid username (3-32 chars: a-z, 0-9, _ . -)", back)
            if name in users:
                return self.flash_go(s, "bad", "Username already exists", back)
            if role not in ("user", "admin"):
                role = "user"
            users[name] = new_record(role)
            key = issue_key(users[name])
            users_save(users)
            with LOCK:
                s["reveal"] = (name, key)
            return self.flash_go(s, "ok", "Account created - key shown below (once)", back)

        if name not in users:
            return self.flash_go(s, "bad", "User not found", back)
        if name == s["user"]:
            return self.flash_go(s, "bad", "Use the Account page for your own key", back)
        rec = users[name]
        admins_on = active_admins(users)
        is_last_admin = rec.get("role") == "admin" and name in admins_on and len(admins_on) == 1

        if act == "reset":
            key = issue_key(rec)
            users_save(users)
            kill_sessions(name)
            with LOCK:
                s["reveal"] = (name, key)
            return self.flash_go(s, "ok", "New key generated - give it to the user (shown once)", back)

        if act == "toggle":
            if not rec.get("disabled") and is_last_admin:
                return self.flash_go(s, "bad", "Cannot disable the last active admin", back)
            rec["disabled"] = not rec.get("disabled")
            users_save(users)
            if rec["disabled"]:
                kill_sessions(name)
            return self.flash_go(s, "ok", ("Disabled " if rec["disabled"] else "Enabled ") + name, back)

        if act == "role":
            new_role = "user" if rec.get("role") == "admin" else "admin"
            if new_role == "user" and is_last_admin:
                return self.flash_go(s, "bad", "Cannot demote the last active admin", back)
            rec["role"] = new_role
            users_save(users)
            return self.flash_go(s, "ok", name + " is now " + new_role, back)

        if act == "delete":
            if f.get("confirm") != "yes":
                return self.flash_go(s, "bad", "Tick 'confirm' to delete", back)
            if is_last_admin:
                return self.flash_go(s, "bad", "Cannot delete the last active admin", back)
            for m in list_bots(owner=name):
                stop_bot(m["id"])
                shutil.rmtree(bdir(m["id"]), ignore_errors=True)
            users.pop(name, None)
            users_save(users)
            kill_sessions(name)
            return self.flash_go(s, "ok", "Account and its bots deleted", back)

        return self.flash_go(s, "bad", "Unknown action", back)

    def do_own_key(self, s, f):
        if f.get("confirm") != "yes":
            return self.flash_go(s, "bad", "Tick the confirmation box first", "/account")
        users = users_load()
        rec = users.get(s["user"])
        if not rec or rec.get("disabled"):
            return self.flash_go(s, "bad", "Account unavailable", "/account")
        key = issue_key(rec)
        users_save(users)
        kill_sessions(s["user"], keep=s["tok"])
        with LOCK:
            s["reveal"] = (s["user"], key)
        self.go("/account")


def main():
    global BOT_RUN_AS
    if sys.version_info < (3, 10):
        sys.exit("TBP needs Python 3.10 or newer")
    a = sys.argv
    if len(a) == 3 and a[1] in ("--set-password", "--new-key"):
        os.makedirs(HOME, mode=0o700, exist_ok=True)
        return cli_new_key(a[2])
    os.makedirs(BOTS, mode=0o711, exist_ok=True)
    if os.geteuid() == 0:
        os.chmod(HOME, 0o711)          # bot user must traverse to its own folder
        os.chmod(BOTS, 0o711)
    BOT_RUN_AS = ensure_bot_user()
    admins = active_admins(users_load())
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
        if os.geteuid() == 0 and os.path.isdir(bdir(m["id"])):
            harden(m["id"])
    if os.geteuid() == 0 and not BOT_RUN_AS:
        print("WARNING: could not create sandbox user '%s'; bots will not start" % BOT_USER, flush=True)
    threading.Thread(target=watchdog, daemon=True).start()
    print("TBP panel v%s running on http://127.0.0.1:%d" % (VERSION, PORT), flush=True)
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
