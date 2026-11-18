#!/usr/bin/env python3
# =====================================================
#  TURBO VPS PANEL - Telegram Bot (separate process) · V 2.7
#  Developer: TURBO   ·   Telegram: https://t.me/arsar2027
#
#  - Welcome screen with buttons
#  - Channel join required (fail-closed)
#  - Coins: 2 coin = 1 day · buy / extend days · reissue key (once / 24h)
#  - Invite & earn: referral coins when the invitee joins the channel
#  - Talks to the web panel ONLY through its local /internal API
#    (127.0.0.1 + shared secret). The panel owns all data.
#  - Config: /opt/tb-panel/config.json -> "bot": {...}
#  Run by systemd unit "tb-bot" (installed by vps-panel.sh)
# =====================================================
import html, json, os, re, sys, time, traceback
import urllib.error, urllib.request

VERSION = "2.7"
PANEL_NAME = "TURBO VPS PANEL"
TG_URL = "https://t.me/arsar2027"
TG_HANDLE = "@arsar2027"
CHANNEL_DEFAULT = "@arsar2027"
COIN_PER_DAY = 2          # keep in sync with app.py
DAY_OPTIONS = (1, 3, 7)   # keep in sync with app.py
STRIKE_LIMIT = 3          # keep in sync with app.py
CONF_PATH = os.environ.get("TBP_CONF", "/opt/tb-panel/config.json")
PANEL = "http://127.0.0.1:%s" % os.environ.get("TBP_PORT", "8787")

TOKEN = ""
SECRET = ""
CHANNEL = CHANNEL_DEFAULT
ADMINS = set()
PANEL_URL = ""
BOT_USERNAME = ""

# ---------- keyboards ----------
JOIN_KB = [
    [{"text": "📢 Join channel", "url": TG_URL}],
    [{"text": "✅ I joined, verify", "callback_data": "check"}],
]
MAIN_KB = [
    [{"text": "🛒 Buy time / Get key", "callback_data": "buy"}],
    [{"text": "🔑 Reissue key", "callback_data": "reissue"},
     {"text": "🪙 My coins", "callback_data": "coins"}],
    [{"text": "👥 Invite & earn", "callback_data": "invite"}],
    [{"text": "📢 Channel", "url": TG_URL}],
]
BUY_KB = [[{"text": "%d day%s · %d coin" % (d, "s" if d > 1 else "", d * COIN_PER_DAY),
            "callback_data": "buy:%d" % d}] for d in DAY_OPTIONS] + [
    [{"text": "⬅ Back to menu", "callback_data": "menu"}]]
BACK_KB = [[{"text": "⬅ Back to menu", "callback_data": "menu"}]]

PANEL_DOWN = "⚠️ Service is temporarily unavailable. Please try again later."
CHECK_FAILED = "⚠️ Channel check failed. Please try again later."


# =====================================================
#  Helpers
# =====================================================
def esc(s):
    return html.escape(str(s), quote=True)


def log(*a):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), *a, flush=True)


def load_cfg():
    try:
        with open(CONF_PATH, encoding="utf-8") as f:
            b = json.load(f).get("bot")
        return b if isinstance(b, dict) else {}
    except Exception:
        return {}


def reward_amount():
    try:
        return max(0, min(100, int(load_cfg().get("ref_reward", COIN_PER_DAY))))
    except (TypeError, ValueError):
        return COIN_PER_DAY


def banned_text():
    return ("⛔ <b>Account banned</b>\n\nContact the admin: <a href='%s'>%s</a>"
            % (TG_URL, esc(TG_HANDLE)))


def welcome_text(u):
    key = "✅ issued" if u.get("has_key") else "— none yet"
    return ("🚀 <b>%s မှ ကြိုဆိုပါတယ်!</b>\n"
            "<i>Welcome to TURBO VPS PANEL</i>\n\n"
            "🪙 Coins: <b>%d</b>\n"
            "⏳ Time: %s\n"
            "🔑 Key: %s\n\n"
            "💡 Rate: <b>%d coin = 1 day</b>\n"
            "👥 Invite friends and earn coins!\n\n"
            "Choose an option below 👇"
            % (esc(PANEL_NAME), int(u.get("coins", 0)), esc(u.get("time_left", "")), key, COIN_PER_DAY))


def join_text():
    return ("📢 <b>Join our channel first</b>\n\n"
            "You must be a member of <b>%s</b> to use <b>%s</b>.\n\n"
            "1️⃣ Tap <b>Join channel</b>\n"
            "2️⃣ Come back and tap <b>✅ I joined, verify</b>"
            % (esc(CHANNEL), esc(PANEL_NAME)))


def coins_text(u):
    return ("🪙 <b>My coins</b>\n\n"
            "Coins: <b>%d</b>\n"
            "⏳ Time: %s\n\n"
            "Rate: <b>%d coin = 1 day</b>\n"
            "Need more coins? Contact the admin: <a href='%s'>%s</a>"
            % (int(u.get("coins", 0)), esc(u.get("time_left", "")), COIN_PER_DAY, TG_URL, esc(TG_HANDLE)))


# =====================================================
#  Telegram API
# =====================================================
def tg(method, params=None, timeout=20):
    if not TOKEN:
        return {"ok": False, "description": "no token"}
    req = urllib.request.Request("https://api.telegram.org/bot%s/%s" % (TOKEN, method),
                                 data=json.dumps(params or {}).encode("utf-8"),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode("utf-8", "replace"))
        except Exception:
            return {"ok": False, "description": "HTTP %s" % e.code, "error_code": e.code}
    except Exception as e:
        return {"ok": False, "description": e.__class__.__name__}


def send(chat_id, text, kb=None):
    p = {"chat_id": chat_id, "text": text[:3900], "parse_mode": "HTML", "disable_web_page_preview": True}
    if kb:
        p["reply_markup"] = {"inline_keyboard": kb}
    r = tg("sendMessage", p)
    if not r.get("ok"):
        log("send failed:", str(r.get("description"))[:120])
    return r


def send_key(cid, msg, key):
    t = ("✅ %s\n\n🔑 <b>Your access key</b>\n<code>%s</code>\n\n"
         "⚠️ Shown <b>once</b>. Save it now and never share it." % (esc(msg), esc(key)))
    if PANEL_URL:
        t += "\n🌐 Panel: %s" % esc(PANEL_URL)
    send(cid, t, MAIN_KB)


def is_member(uid):
    """True / False / None (None = could not verify, fail closed)."""
    r = tg("getChatMember", {"chat_id": CHANNEL, "user_id": int(uid)})
    if not r.get("ok"):
        log("channel check failed:", str(r.get("description"))[:120])
        return None
    res = r.get("result") or {}
    st = res.get("status")
    if st in ("creator", "administrator", "member"):
        return True
    if st == "restricted" and res.get("is_member"):
        return True
    return False


# =====================================================
#  Panel API (local only, shared secret)
# =====================================================
def panel(path, body):
    if not SECRET:
        return {"ok": False, "error": "no internal secret"}
    req = urllib.request.Request(PANEL + path, data=json.dumps(body).encode("utf-8"), method="POST",
                                 headers={"Content-Type": "application/json", "X-Bot-Secret": SECRET})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode("utf-8", "replace"))
        except Exception:
            return {"ok": False, "error": "HTTP %s" % e.code}
    except Exception:
        return {"ok": False, "error": "panel unreachable"}


def ensure(uid, ref=None):
    return panel("/internal/user", {"tg_id": int(uid), "ref": ref})


def info(uid):
    r = panel("/internal/info", {"tg_id": int(uid)})
    return r.get("user") if r.get("ok") else None


def reward(uid):
    """Pays the inviter once, after the invitee passed the channel check."""
    r = panel("/internal/reward", {"tg_id": int(uid)})
    inv = r.get("inviter_tg")
    if inv:
        send(inv, "🎉 <b>Referral reward!</b>\nA new user joined through your link.\n"
                  "🪙 <b>+%d coin</b> added to your balance." % int(r.get("amount", COIN_PER_DAY)),
             BACK_KB)


# =====================================================
#  Screens
# =====================================================
def gate(cid, uid):
    ok = is_member(uid)
    if ok is None:
        send(cid, CHECK_FAILED, BACK_KB)
        return False
    if not ok:
        send(cid, join_text(), JOIN_KB)
        return False
    reward(uid)
    return True


def show_welcome(cid, uid):
    u = info(uid)
    if u is None:
        return send(cid, PANEL_DOWN)
    if u.get("disabled"):
        return send(cid, banned_text())
    if not gate(cid, uid):
        return
    send(cid, welcome_text(u), MAIN_KB)


def show_coins(cid, uid):
    if not gate(cid, uid):
        return
    u = info(uid)
    if u is None:
        return send(cid, PANEL_DOWN)
    send(cid, coins_text(u), BACK_KB)


def show_buy(cid, uid):
    if not gate(cid, uid):
        return
    send(cid, "🛒 <b>Choose how many days</b>\n\nRate: <b>%d coin = 1 day</b>\n"
              "Buying again <b>adds</b> time to your current expiry." % COIN_PER_DAY, BUY_KB)


def do_buy(cid, uid, raw_days):
    if not gate(cid, uid):
        return
    try:
        days = int(raw_days)
    except ValueError:
        days = 0
    if days not in DAY_OPTIONS:
        return send(cid, "Invalid option", BUY_KB)
    r = panel("/internal/buy", {"tg_id": int(uid), "days": days})
    if not r.get("ok"):
        return send(cid, "❌ " + esc(r.get("msg") or r.get("error") or "Failed"), BUY_KB)
    if r.get("key"):
        return send_key(cid, r.get("msg", ""), r["key"])
    send(cid, "✅ " + esc(r.get("msg", "")), MAIN_KB)


def do_reissue(cid, uid):
    if not gate(cid, uid):
        return
    r = panel("/internal/reissue", {"tg_id": int(uid)})
    if not r.get("ok"):
        return send(cid, "❌ " + esc(r.get("msg") or r.get("error") or "Failed"), MAIN_KB)
    send_key(cid, r.get("msg", ""), r.get("key", ""))


def show_invite(cid, uid):
    if not gate(cid, uid):
        return
    if not BOT_USERNAME:
        return send(cid, "⚠️ Bot is starting, try again in a moment.", BACK_KB)
    link = "https://t.me/%s?start=ref%d" % (BOT_USERNAME, int(uid))
    u = info(uid) or {}
    send(cid, ("👥 <b>Invite &amp; earn</b>\n\n"
               "Share your link. Each new user who joins the channel and opens the bot "
               "gives you <b>%d coin</b>.\n\n"
               "🔗 <code>%s</code>\n\n"
               "Referrals: <b>%d</b>")
         % (reward_amount(), esc(link), int(u.get("refs", 0))), BACK_KB)


def admin_cmd(cid, cmd, parts):
    if cmd == "/addcoin":
        if len(parts) != 3 or not parts[1].isdigit() or not re.fullmatch(r"-?\d{1,6}", parts[2]):
            return send(cid, "Usage: <code>/addcoin &lt;tg_id&gt; &lt;amount&gt;</code>")
        r = panel("/internal/addcoin", {"tg_id": int(parts[1]), "amount": int(parts[2])})
        if not r.get("ok"):
            return send(cid, "❌ " + esc(r.get("error") or "failed"))
        return send(cid, "✅ tg%s now has %d coins" % (parts[1], int(r.get("coins", 0))))
    if len(parts) != 2 or not parts[1].isdigit():
        return send(cid, "Usage: <code>/userinfo &lt;tg_id&gt;</code>")
    u = info(int(parts[1]))
    if not u:
        return send(cid, "Not found")
    send(cid, ("<b>tg%s</b>\nCoins: %d\nTime: %s\nBanned: %s\nStrikes: %d/%d\nReferrals: %d\nKey: %s")
         % (parts[1], int(u.get("coins", 0)), esc(u.get("time_left", "")), "yes" if u.get("disabled") else "no",
            int(u.get("strikes", 0)), STRIKE_LIMIT, int(u.get("refs", 0)),
            "issued" if u.get("has_key") else "none"))


# =====================================================
#  Update handlers
# =====================================================
def handle_message(m):
    chat = m.get("chat") or {}
    if chat.get("type") != "private":
        return
    uid = (m.get("from") or {}).get("id")
    cid = chat.get("id")
    if not uid or not cid:
        return
    parts = (m.get("text") or "").strip().split()
    cmd = parts[0].lower().split("@")[0] if parts else ""
    if cmd in ("/addcoin", "/userinfo"):
        if uid not in ADMINS:
            return send(cid, "⛔ Not authorized")
        return admin_cmd(cid, cmd, parts)
    ref = None
    if cmd == "/start" and len(parts) > 1:
        mm = re.fullmatch(r"ref(\d{4,15})", parts[1])
        if mm:
            ref = mm.group(1)
    ensure(uid, ref)
    show_welcome(cid, uid)


def handle_callback(cq):
    tg("answerCallbackQuery", {"callback_query_id": cq.get("id")})
    chat = (cq.get("message") or {}).get("chat") or {}
    if chat.get("type") != "private":
        return
    uid = (cq.get("from") or {}).get("id")
    cid = chat.get("id")
    if not uid or not cid:
        return
    data = str(cq.get("data") or "")
    ensure(uid)
    u = info(uid)
    if u is None:
        return send(cid, PANEL_DOWN)
    if u.get("disabled"):
        return send(cid, banned_text())

    if data == "menu":
        return show_welcome(cid, uid)
    if data == "check":
        ok = is_member(uid)
        if ok is None:
            return send(cid, CHECK_FAILED, BACK_KB)
        if ok:
            send(cid, "✅ <b>Verified!</b> Welcome to <b>%s</b>." % esc(PANEL_NAME))
            return show_welcome(cid, uid)
        return send(cid, join_text(), JOIN_KB)
    if data == "coins":
        return show_coins(cid, uid)
    if data == "buy":
        return show_buy(cid, uid)
    if data.startswith("buy:"):
        return do_buy(cid, uid, data.split(":", 1)[1])
    if data == "reissue":
        return do_reissue(cid, uid)
    if data == "invite":
        return show_invite(cid, uid)
    send(cid, "Unknown option", MAIN_KB)


def dispatch(u):
    if "message" in u:
        handle_message(u["message"])
    elif "callback_query" in u:
        handle_callback(u["callback_query"])


# =====================================================
#  Boot + polling loop
# =====================================================
def boot():
    global TOKEN, SECRET, CHANNEL, ADMINS, PANEL_URL, BOT_USERNAME
    cfg = load_cfg()
    TOKEN = cfg.get("token") or ""
    SECRET = cfg.get("internal_secret") or ""
    CHANNEL = cfg.get("channel") or CHANNEL_DEFAULT
    ADMINS = {int(x) for x in cfg.get("admins", []) if str(x).isdigit()}
    PANEL_URL = cfg.get("panel_url") or ""
    if not TOKEN:
        log("No bot token. Set it in: sudo bash vps-panel.sh → 14 → 9 → 1")
        sys.exit(3)
    if not SECRET:
        log("Panel has no internal secret yet. Start the web panel once (menu 14 → 1).")
        sys.exit(3)
    if not ADMINS:
        log("WARNING: no admin Telegram ID set (menu 14 → 9 → 2). /addcoin will not work.")
    while True:
        me = tg("getMe")
        if me.get("ok"):
            BOT_USERNAME = (me.get("result") or {}).get("username", "")
            break
        if me.get("error_code") in (401, 404):
            log("Telegram rejected the token. Fix it in menu 14 → 9 → 1")
            sys.exit(3)
        log("getMe failed, retrying:", str(me.get("description"))[:120])
        time.sleep(15)
    panel("/internal/meta", {"username": BOT_USERNAME})
    log("%s bot V%s started as @%s · channel %s · admins %d"
        % (PANEL_NAME, VERSION, BOT_USERNAME, CHANNEL, len(ADMINS)))


def run():
    tg("deleteWebhook", {"drop_pending_updates": False})
    offset, backoff = None, 2
    while True:
        p = {"timeout": 25, "allowed_updates": ["message", "callback_query"]}
        if offset:
            p["offset"] = offset
        r = tg("getUpdates", p, timeout=35)
        if not r.get("ok"):
            log("poll error:", str(r.get("description"))[:120])
            if r.get("error_code") in (401, 404):
                sys.exit(3)
            time.sleep(min(60, backoff))
            backoff = min(60, backoff * 2)
            continue
        backoff = 2
        for u in r.get("result", []):
            offset = u["update_id"] + 1
            try:
                dispatch(u)
            except Exception:
                traceback.print_exc()


if __name__ == "__main__":
    boot()
    run()
