#!/usr/bin/env python3
"""switchboard-serve: the Switchboard iPhone app's way in on this machine, for when the Mac
is closed or asleep.

Switchboard on the Mac installs this file and runs it here as a user service. It speaks the
same WebSocket protocol as Switchboard on a Mac (SBRemote.swift), so the phone lists this
machine with your Macs (it reports itself to Simplero) and shows the Claude sessions that run
here in tmux (switchboard-remote): their state, conversation and terminal. You can answer,
press keys, send files and start new sessions.

While the Mac's Switchboard is awake it shows these sessions itself, and this server lists
none of them (the Mac writes rows.json here every 30 s: when it is fresh, the Mac is up).

Who gets in: only devices of this machine's own Tailscale login (`tailscale whois`), and then
only the Simplero login that owns the Mac's Switchboard (serve.json, written by the Mac).
"""
import asyncio
import base64
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
import uuid

VERSION = 1
HOME = os.path.expanduser("~")
STATE = HOME + "/.cache/switchboard"
CONF_PATH = os.environ.get("SWITCHBOARD_SERVE_CONF") or (sys.argv[1] if len(sys.argv) > 1 else HOME + "/.config/switchboard/serve.json")


def log(*a):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), *a, flush=True)


# MARK: Settings (written by the Mac)

_conf = {"mtime": -1, "c": {}}


def conf():
    try:
        m = os.path.getmtime(CONF_PATH)
    except OSError:
        return _conf["c"]
    if m != _conf["mtime"]:
        try:
            with open(CONF_PATH) as f:
                _conf["c"] = json.load(f)
            _conf["mtime"] = m
        except (OSError, ValueError) as e:
            log("serve.json:", e)
    return _conf["c"]


def tmux_name():
    return conf().get("tmux") or "switchboard"


def state_dir():
    return conf().get("state") or STATE


def read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f)
    os.replace(tmp, path)


def tilde(p):
    if p == HOME:
        return "~"
    return "~" + p[len(HOME):] if p and p.startswith(HOME + "/") else p


def expand(p):
    return HOME + p[1:] if p and p.startswith("~") else p


def run(args, input=None, timeout=10):
    try:
        r = subprocess.run(args, input=input, capture_output=True, timeout=timeout)
        return r.returncode, r.stdout.decode("utf-8", "replace")
    except (OSError, subprocess.TimeoutExpired):
        return -1, ""


def tmux(*args, input=None):
    return run(["tmux", "-u", "-L", tmux_name()] + list(args), input=input)


def helper_env():
    env = dict(os.environ)
    c = conf()
    if c.get("claude"):
        env["SWITCHBOARD_CLAUDE_BIN"] = c["claude"]
    if c.get("tmux"):
        env["SWITCHBOARD_TMUX"] = c["tmux"]
    return env


def helper(*args, timeout=30):
    try:
        r = subprocess.run([HOME + "/.local/bin/switchboard-remote"] + list(args), capture_output=True, timeout=timeout, env=helper_env())
        return r.returncode, r.stdout.decode("utf-8", "replace")
    except (OSError, subprocess.TimeoutExpired) as e:
        return -1, str(e)


# MARK: Reading Claude's screen (SBScreen.swift)

SPINNER = re.compile(r"^\s*\S\s+[A-Z][\w'-]+…\s*\(", re.M)
CODEX_WORKING = re.compile(r"^\s*\S?\s*Working \(\d|Waiting for \d+ background agent", re.M | re.I)
PERMISSION = re.compile(r"Do you want to (proceed|make this edit|create|run)|❯ 1\. Yes|Allow command\?|approve this|Do you trust the contents of this project\?", re.M)


def screen_state(screen):
    last = [l for l in screen.splitlines() if l.strip()][-25:]
    if PERMISSION.search("\n".join(last)):
        return "permission"
    for l in last[-12:]:
        if SPINNER.search(l) or CODEX_WORKING.search(l):
            return "working"
    return "idle"


def working_line(screen):
    for l in reversed([l for l in screen.splitlines() if l.strip()]):
        if SPINNER.search(l) or CODEX_WORKING.search(l):
            return l.strip()
    return ""


# MARK: Conversations (SBConversation.swift)

def iso_time(s):
    try:
        from datetime import datetime
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except (ValueError, AttributeError):
        return 0


def between(s, a, b):
    i = s.find(a)
    if i < 0:
        return None
    j = s.find(b, i + len(a))
    return s[i + len(a):j].strip() if j >= 0 else None


def typed(raw):
    t = raw
    if "<command-name>" in t:
        name = between(t, "<command-name>", "</command-name>") or ""
        args = between(t, "<command-args>", "</command-args>") or ""
        line = (name if name.startswith("/") else "/" + name) + (" " + args if args else "")
        return None if line == "/" else (line, False)
    for skip in ["<local-command-stdout>", "<local-command-stderr>", "<task-notification>", "<bash-stdout>", "<bash-stderr>", "Caveat: "]:
        if t.startswith(skip):
            return None
    if t.startswith("<bash-input>"):
        cmd = between(t, "<bash-input>", "</bash-input>")
        if cmd is not None:
            return ("! " + cmd, False)
    t = re.sub(r"<system-reminder>.*?</system-reminder>", "", t, flags=re.S).strip()
    if not t:
        return None
    if t in ("[Request interrupted by user]", "[Request interrupted by user for tool use]"):
        return ("Stopped", True)
    return (t, False)


def result_text(c):
    s = ""
    if isinstance(c, str):
        s = c
    elif isinstance(c, list):
        s = "\n".join(p.get("text", "") if p.get("type") == "text" else "[Image]" for p in c if isinstance(p, dict) and p.get("type") in ("text", "image"))
    s = s.strip()
    return s[:1500] + "\n…" if len(s) > 1500 else s


def tool_name(name):
    if not name.startswith("mcp__"):
        return name
    parts = [p for p in name.split("_") if p]
    return parts[-1] if parts else name


def detail(name, inp):
    def s(k):
        v = inp.get(k)
        return v if isinstance(v, str) and v else None

    def short(x, n=240):
        if x is None:
            return None
        one = (x.splitlines() or [x])[0].strip()
        return one[:n] + "…" if len(one) > n else one

    if name == "Bash":
        return short(s("command"))
    if name in ("Read", "Write", "Edit", "MultiEdit"):
        return tilde(s("file_path")) if s("file_path") else None
    if name == "NotebookEdit":
        return tilde(s("notebook_path")) if s("notebook_path") else None
    if name == "Grep":
        return short("  in ".join(x for x in [s("pattern"), tilde(s("path")) if s("path") else None] if x))
    if name == "Glob":
        return short(s("pattern"))
    if name == "WebFetch":
        return short(s("url"))
    if name == "WebSearch":
        return short(s("query"))
    if name in ("Task", "Agent"):
        return short(s("description") or s("prompt"))
    if name == "Skill":
        return short(s("skill"))
    if name == "ToolSearch":
        return short(s("query"))
    if name == "TodoWrite":
        return f"{len(inp['todos'])} to-dos" if isinstance(inp.get("todos"), list) else None
    if name == "AskUserQuestion":
        qs = inp.get("questions")
        return short(qs[0].get("question")) if isinstance(qs, list) and qs and isinstance(qs[0], dict) else None
    for k in ["query", "title", "url", "path", "id", "name", "description"]:
        if s(k):
            return short(s(k))
    for v in inp.values():
        if isinstance(v, str):
            return short(v)
    return None


class Reader:
    FIRST = 6_000_000
    KEEP = 400

    def __init__(self, path):
        self.path = path
        self.offset = 0
        self.partial = b""
        self.items = []
        self.index = {}

    def start(self):
        size = self.size()
        self.offset = size - self.FIRST if size > self.FIRST else 0
        self.read_new(self.offset > 0)
        return self.items

    def poll(self):
        size = self.size()
        if size < self.offset:
            self.items, self.index, self.partial = [], {}, b""
            return self.start()
        if size == self.offset:
            return []
        return self.read_new(False)

    def size(self):
        try:
            return os.path.getsize(self.path)
        except OSError:
            return 0

    def put(self, item):
        if item["id"] in self.index:
            self.items[self.index[item["id"]]] = item
        else:
            self.index[item["id"]] = len(self.items)
            self.items.append(item)

    def read_new(self, skip_first):
        try:
            with open(self.path, "rb") as f:
                f.seek(self.offset)
                data = f.read()
        except OSError:
            return []
        self.offset += len(data)
        buf = self.partial + data
        lines = buf.split(b"\n")
        self.partial = lines.pop()
        if skip_first and lines:
            lines = lines[1:]
        changed = []
        for line in lines:
            changed.extend(self.parse(line))
        if len(self.items) > self.KEEP + 100:
            self.items = self.items[-self.KEEP:]
            self.index = {it["id"]: i for i, it in enumerate(self.items)}
        seen, out = set(), []
        for i in reversed(changed):
            if i not in seen:
                seen.add(i)
                out.append(i)
        return [self.items[self.index[i]] for i in reversed(out) if i in self.index]

    @staticmethod
    def item(id, role, text="", at=0):
        o = {"id": id, "r": role, "x": text, "at": int(at)}
        if role == "tool":
            o["te"] = False
            o["tok"] = False
        return o

    def parse(self, line):
        if not (line.startswith(b'{"parentUuid"') or line.startswith(b'{"type":"user"') or line.startswith(b'{"type":"assistant"')):
            return []
        try:
            j = json.loads(line)
        except ValueError:
            return []
        if j.get("isSidechain"):
            return []
        typ = j.get("type", "")
        uid = j.get("uuid") or str(uuid.uuid4())
        at = iso_time(j.get("timestamp", ""))
        content = (j.get("message") or {}).get("content")
        if typ == "user":
            return self.user(j, uid, at, content)
        if typ == "assistant":
            if not isinstance(content, list):
                return []
            out = []
            for n, b in enumerate(content):
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "text":
                    text = (b.get("text") or "").strip()
                    if not text or text == "(no content)":
                        continue
                    i = f"{uid}#{n}"
                    self.put(self.item(i, "ai", text, at))
                    out.append(i)
                elif b.get("type") == "tool_use" and b.get("id"):
                    i = b["id"]
                    name = b.get("name") or "Tool"
                    it = dict(self.items[self.index[i]]) if i in self.index else self.item(i, "tool", "", at)
                    it["tn"] = tool_name(name)
                    d = detail(name, b.get("input") or {})
                    if d:
                        it["td"] = d
                    self.put(it)
                    out.append(i)
            return out
        if typ == "system" and j.get("subtype") == "compact_boundary":
            self.put(self.item(uid, "note", "Conversation compacted", at))
            return [uid]
        return []

    def user(self, j, uid, at, content):
        if j.get("isCompactSummary") or j.get("isVisibleInTranscriptOnly"):
            return []
        if isinstance(content, str):
            if j.get("isMeta"):
                return []
            kind = (j.get("origin") or {}).get("kind")
            if kind and kind != "human":
                return []
            shown = typed(content)
            if not shown:
                return []
            self.put(self.item(uid, "note" if shown[1] else "you", shown[0], at))
            return [uid]
        if not isinstance(content, list):
            return []
        out, texts, images = [], [], 0
        for b in content:
            if not isinstance(b, dict):
                continue
            t = b.get("type")
            if t == "tool_result":
                i = b.get("tool_use_id")
                if i not in self.index:
                    continue
                it = dict(self.items[self.index[i]])
                it["tok"] = True
                it["te"] = bool(b.get("is_error"))
                it["to"] = result_text(b.get("content"))
                self.put(it)
                out.append(i)
            elif t == "text" and not j.get("isMeta"):
                shown = typed(b.get("text") or "")
                if shown and not shown[1]:
                    texts.append(shown[0])
            elif t == "image" and not j.get("isMeta"):
                images += 1
        if texts or images:
            text = "\n\n".join(texts)
            if images:
                mark = "[Image]" if images == 1 else f"[{images} images]"
                text = text + "\n" + mark if text else mark
            self.put(self.item(uid, "you", text, at))
            out.append(uid)
        return out


def project_dirs():
    dirs = conf().get("projects") or [".claude*/projects"]
    return [d if d.startswith("/") else HOME + "/" + d for d in dirs]


_paths = {}


def transcript_path(sid):
    hit = _paths.get(sid)
    if hit and hit[0] and os.path.exists(hit[0]):
        return hit[0]
    if hit and time.time() - hit[1] < 10:
        return None
    found = []
    for d in project_dirs():
        found.extend(glob.glob(d + "/*/" + sid + ".jsonl"))
    path = max(found, key=lambda p: os.path.getmtime(p)) if found else None
    _paths[sid] = (path, time.time()) if path else (None, time.time())
    return path


def tail_bytes(path, n=400_000):
    try:
        with open(path, "rb") as f:
            size = os.path.getsize(path)
            f.seek(max(0, size - n))
            return f.read().decode("utf-8", "replace")
    except OSError:
        return ""


def transcript_facts(path):
    """The folder Claude works in last, its /rename name and its last answer."""
    text = tail_bytes(path)
    cwd = None
    m = list(re.finditer(r'"cwd":"((?:[^"\\]|\\.)*)"', text))
    if m:
        cwd = json.loads('"' + m[-1].group(1) + '"')
    title = None
    m = list(re.finditer(r'"customTitle":"((?:[^"\\]|\\.)*)"', text))
    if m:
        title = json.loads('"' + m[-1].group(1) + '"')
    said = ""
    for line in reversed(text.splitlines()):
        if '"type":"assistant"' not in line[:200] and not line.startswith('{"parentUuid"'):
            continue
        try:
            j = json.loads(line)
        except ValueError:
            continue
        if j.get("type") != "assistant" or j.get("isSidechain"):
            continue
        blocks = (j.get("message") or {}).get("content")
        texts = [b.get("text", "") for b in blocks if isinstance(b, dict) and b.get("type") == "text"] if isinstance(blocks, list) else []
        t = " ".join(x.strip() for x in texts if x.strip())
        if t:
            said = re.sub(r"\s+", " ", t)[:240]
            break
    return cwd, title, said


# MARK: The sessions here

def live_sessions():
    code, out = tmux("list-sessions", "-F", "#{session_name} #{session_activity}")
    if code != 0:
        return {}
    got = {}
    for l in out.splitlines():
        parts = l.split()
        if parts and parts[0].startswith("sb-"):
            got[parts[0][3:]] = float(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
    return got


def pane(sid):
    """The pane of a session ("=name" alone is a session, not a pane, for tmux)."""
    return "=sb-" + sid + ":"


def screen_of(sid):
    code, out = tmux("capture-pane", "-p", "-t", pane(sid))
    return out.rstrip("\n") if code == 0 else None


def login_of(sid):
    code, out = tmux("show-environment", "-t", "=sb-" + sid, "SB_LOGIN")
    return out.strip().split("=", 1)[1] if code == 0 and "=" in out else "~/.claude"


def mac_rows():
    """The Mac's rows for this machine's sessions, and whether the Mac is up (wrote them lately)."""
    r = read_json(state_dir() + "/rows.json", {})
    fresh = time.time() - float(r.get("at") or 0) < float(conf().get("mac_fresh") or 150)
    return {x.get("k"): x for x in r.get("rows") or [] if isinstance(x, dict)}, fresh, r


NEEDS = {"permission", "question", "review", "heads_up"}
_facts = {}


def rows():
    macrows, fresh, raw = mac_rows()
    if fresh:
        return [], raw
    started = read_json(state_dir() + "/started.json", {})
    names = read_json(state_dir() + "/names.json", {})
    logins = {l.get("d"): l.get("lg") for l in conf().get("logins") or raw.get("logins") or []}
    out = []
    for sid, activity in live_sessions().items():
        try:
            out.append(row_of(sid, activity, macrows, raw, started, names, logins))
        except Exception as e:
            log("row", sid, e)
    return out, raw


def row_of(sid, activity, macrows, raw, started, names, logins):
    if True:
        k = "claude:" + sid
        mac = macrows.get(k) or {}
        screen = screen_of(sid) or ""
        st = screen_state(screen)
        path = transcript_path(sid)
        mtime = os.path.getmtime(path) if path and os.path.exists(path) else 0
        cached = _facts.get(sid)
        if path and (not cached or cached[0] != mtime):
            _facts[sid] = (mtime,) + transcript_facts(path)
        _, cwd, title, said = _facts.get(sid, (0, None, None, ""))
        folder = mac.get("cwd") or tilde(cwd) or (started.get(sid) or {}).get("cwd") or "~"
        name = names.get(sid) or mac.get("n") or (started.get(sid) or {}).get("name") or title or os.path.basename(expand(folder).rstrip("/")) or "Session"
        ld = login_of(sid)
        row = {"k": k, "n": name, "a": "claude", "o": True, "pk": False, "ar": False, "u": False,
               "la": max(mtime, activity), "ca": 0, "cwd": folder, "ld": ld, "lg": logins.get(ld) or mac.get("lg") or ld,
               "sf": "here:" + sid, "t": mac.get("t") or "", "sd": said, "ns": "", "wl": "", "rp": [], "m": None}
        if mac.get("br"):
            row["br"] = mac["br"]
        if st == "working":
            row["st"] = "working"
            row["wl"] = working_line(screen)
        elif st == "permission":
            row["st"] = "permission"
            row["ns"] = "Claude asks for your permission."
        elif mac.get("st") and mtime and mtime <= float(raw.get("at") or 0) + 5:
            # Nothing happened since the Mac last read it: what the Mac knew still holds.
            row["st"] = mac["st"]
            for f in ("ns", "sd", "rp", "u"):
                if mac.get(f):
                    row[f] = mac[f]
        else:
            row["st"] = "info"
        return row


# MARK: WebSocket (RFC 6455), just what the phone needs

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class Closed(Exception):
    pass


async def handshake(reader, writer):
    head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 15)
    lines = head.decode("latin-1").split("\r\n")
    headers = {}
    for l in lines[1:]:
        if ":" in l:
            a, b = l.split(":", 1)
            headers[a.strip().lower()] = b.strip()
    key = headers.get("sec-websocket-key")
    if not key or "websocket" not in headers.get("upgrade", "").lower():
        writer.write(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
        await writer.drain()
        raise Closed()
    accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    writer.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                  f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
    await writer.drain()


async def recv(reader, writer, lock):
    """One whole message (text), answering pings on the way."""
    parts = []
    while True:
        h = await reader.readexactly(2)
        fin, op = h[0] & 0x80, h[0] & 0x0F
        masked, n = h[1] & 0x80, h[1] & 0x7F
        if n == 126:
            n = int.from_bytes(await reader.readexactly(2), "big")
        elif n == 127:
            n = int.from_bytes(await reader.readexactly(8), "big")
        if n > (2 << 20):
            raise Closed()
        mask = await reader.readexactly(4) if masked else b""
        data = await reader.readexactly(n)
        if masked:
            data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        if op == 8:
            raise Closed()
        if op == 9:
            await send_frame(writer, lock, 10, data)
            continue
        if op == 10:
            continue
        parts.append(data)
        if fin:
            return b"".join(parts).decode("utf-8", "replace")


async def send_frame(writer, lock, op, data):
    n = len(data)
    head = bytes([0x80 | op])
    if n < 126:
        head += bytes([n])
    elif n < 65536:
        head += bytes([126]) + n.to_bytes(2, "big")
    else:
        head += bytes([127]) + n.to_bytes(8, "big")
    async with lock:
        writer.write(head + data)
        await writer.drain()


# MARK: Who may come in

_ts = {}


def ts_login(ip=None):
    key = ip or "self"
    hit = _ts.get(key)
    if hit and time.time() - hit[1] < 600:
        return hit[0]
    login = None
    if ip:
        code, out = run(["tailscale", "whois", "--json", ip], timeout=8)
        if code == 0:
            try:
                login = (json.loads(out).get("UserProfile") or {}).get("LoginName")
            except ValueError:
                pass
    else:
        code, out = run(["tailscale", "status", "--json", "--peers=false"], timeout=8)
        if code == 0:
            try:
                j = json.loads(out)
                uid = str((j.get("Self") or {}).get("UserID"))
                login = ((j.get("User") or {}).get(uid) or {}).get("LoginName")
            except ValueError:
                pass
    if login:
        _ts[key] = (login, time.time())
    return login


def ts_self():
    code, out = run(["tailscale", "status", "--json", "--peers=false"], timeout=8)
    if code != 0:
        return None, None
    try:
        s = json.loads(out).get("Self") or {}
        ips = [x for x in s.get("TailscaleIPs") or [] if ":" not in x]
        return (ips[0] if ips else None), (s.get("DNSName") or "").rstrip(".") or None
    except ValueError:
        return None, None


_verified = {}


def who_is(key, server):
    """The Simplero person of a mobile API key: (id, name), "rejected" or None (no answer)."""
    c = conf()
    h = hashlib.sha256((server + " " + key).encode()).hexdigest()
    if c.get("test_key_sha256") and hashlib.sha256(key.encode()).hexdigest() == c["test_key_sha256"]:
        o = c.get("owner") or {}
        return (o.get("id"), o.get("name") or "you")
    hit = _verified.get(h)
    if hit and time.time() - hit[1] < 6 * 3600:
        return hit[0]
    req = urllib.request.Request(server + "/api/mobile/v1/users/me", headers={"X-API-Key": key, "Accept": "application/json", "User-Agent": "Switchboard/1"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            j = json.load(r)
        p = (j.get("id"), j.get("name") or "you")
        _verified[h] = (p, time.time())
        return p
    except urllib.error.HTTPError as e:
        return "rejected" if e.code in (401, 403) else None
    except (OSError, ValueError):
        return None


# MARK: One phone

KEYS = {"esc": "Escape", "enter": "Enter", "tab": "Tab", "shift-tab": "BTab", "backspace": "BSpace", "space": "Space",
        "up": "Up", "down": "Down", "right": "Right", "left": "Left", "ctrl-c": "C-c"}


class Phone:
    def __init__(self, reader, writer):
        self.reader, self.writer = reader, writer
        self.lock = asyncio.Lock()
        self.person = None
        self.sent_rows = {}
        self.watch = None          # {"k", "sid", "screen": bool, "reader", "last_screen", "looked"}
        self.uploads = {}
        self.peer = (writer.get_extra_info("peername") or ("", 0))[0]

    async def send(self, obj):
        await send_frame(self.writer, self.lock, 1, json.dumps(obj).encode())

    async def reply(self, msg, ok, message, **extra):
        if msg.get("id") is None:
            return
        r = dict(extra)
        r.update({"t": "r", "id": msg.get("id"), "ok": ok, "msg": message})
        await self.send(r)

    async def serve(self):
        try:
            await handshake(self.reader, self.writer)
            while True:
                raw = await recv(self.reader, self.writer, self.lock)
                try:
                    msg = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(msg, dict):
                    try:
                        await self.handle(msg)
                    except Closed:
                        raise
                    except Exception as e:
                        log("request", msg.get("t"), repr(e))
                        await self.reply(msg, False, "Something went wrong on this machine.")
        except (Closed, asyncio.IncompleteReadError, ConnectionError, asyncio.TimeoutError, asyncio.LimitOverrunError):
            pass
        finally:
            PHONES.discard(self)
            try:
                self.writer.close()
            except Exception:
                pass

    async def deny(self, why):
        await self.send({"t": "denied", "why": why})
        raise Closed()

    async def handle(self, msg):
        t = msg.get("t")
        if t == "hello":
            if self.person is None:
                await self.sign_in(msg)
            return
        if self.person is None:
            return
        loop = asyncio.get_running_loop()
        if t == "ping":
            await self.send({"t": "pong"})
        elif t == "watch":
            k = msg.get("k")
            if not k:
                self.watch = None
            elif self.watch and self.watch["k"] == k:
                self.watch["screen"] = msg.get("screen", True)
            else:
                self.watch = {"k": k, "sid": k.split(":", 1)[-1], "screen": msg.get("screen", True), "reader": None, "last_screen": "", "looked": 0}
                await self.poll_watch()
        elif t == "screen":
            if self.watch:
                self.watch["screen"] = msg.get("on", True)
                self.watch["last_screen"] = ""
                await self.poll_watch()
        elif t == "send":
            await self.send_text(msg)
        elif t == "keys":
            await self.keys(msg)
        elif t == "put":
            await self.put(msg)
        elif t == "new":
            await self.new(msg)
        elif t == "op":
            await self.op(msg)
        else:
            await self.reply(msg, False, f"Unknown request “{t}”.")

    async def sign_in(self, msg):
        key = msg.get("key") or ""
        if not key:
            await self.deny("Sign in with Simplero first.")
        server = (msg.get("server") or "https://simplero.com").rstrip("/")
        c = conf()
        servers = ["https://simplero.com"] + ([c["server"]] if c.get("server") else [])
        if server not in servers:
            await self.deny(f"This machine does not take sign-ins from {server}.")
        loop = asyncio.get_running_loop()
        if self.peer not in ("127.0.0.1", "::1"):
            mine, theirs = await loop.run_in_executor(None, ts_login), await loop.run_in_executor(None, ts_login, self.peer)
            if not mine or mine != theirs:
                await self.deny("This device does not belong to this machine's Tailscale login.")
        p = await loop.run_in_executor(None, who_is, key, server)
        if p == "rejected":
            await self.deny("Simplero did not accept the sign-in. Sign out and sign in again.")
        if p is None:
            await self.deny("This machine could not reach Simplero to check your sign-in. Try again in a moment.")
        owner = c.get("owner") or {}
        if not owner.get("id") or owner.get("id") != p[0]:
            await self.deny(f"This machine's Switchboard belongs to {owner.get('name') or 'someone else'}'s Simplero login.")
        self.person = p
        _, _, raw = mac_rows()
        await self.send({"t": "welcome", "v": 1, "mac": c.get("name") or os.uname().nodename, "user": p[1],
                         "logins": c.get("logins") or raw.get("logins") or [{"d": "~/.claude", "lg": "~/.claude", "email": ""}],
                         "folders": raw.get("folders") or c.get("folders") or ["~"], "machines": []})
        await self.push_sessions(force=True)

    async def push_sessions(self, force=False, current=None):
        if current is None:
            current = (await asyncio.get_running_loop().run_in_executor(None, rows))[0]
        full = force or not self.sent_rows
        now, changed = {}, []
        for r in current:
            d = json.dumps(r, sort_keys=True)
            now[r["k"]] = d
            if full or self.sent_rows.get(r["k"]) != d:
                changed.append(r)
        gone = [k for k in self.sent_rows if k not in now]
        if not full and not changed and not gone:
            return
        self.sent_rows = now
        await self.send({"t": "sessions", "full": full, "s": changed, "gone": gone, "at": int(time.time()), "use": {}, "machines": []})

    async def poll_watch(self):
        w = self.watch
        if not w:
            return
        loop = asyncio.get_running_loop()
        sid, k = w["sid"], w["k"]
        if w["screen"]:
            screen = await loop.run_in_executor(None, screen_of, sid)
            if screen is not None and screen != w["last_screen"]:
                w["last_screen"] = screen
                await self.send({"t": "screen", "k": k, "text": screen})
        if w["reader"] is None:
            if time.time() - w["looked"] < 3:
                return
            w["looked"] = time.time()
            path = await loop.run_in_executor(None, transcript_path, sid)
            if not path:
                return
            reader = Reader(path)
            items = await loop.run_in_executor(None, reader.start)
            if self.watch is not w:
                return
            w["reader"] = reader
            await self.send({"t": "conv", "k": k, "reset": True, "items": items[-160:]})
        else:
            changed = await loop.run_in_executor(None, w["reader"].poll)
            if changed and self.watch is w:
                await self.send({"t": "conv", "k": k, "items": changed})

    def live_sid(self, msg):
        k = msg.get("k") or ""
        sid = k.split(":", 1)[-1]
        return sid if re.fullmatch(r"[0-9a-f-]{36}", sid) and sid in live_sessions() else None

    def phone_files(self, msg):
        root = state_dir() + "/phone/"
        return [p for p in msg.get("files") or [] if isinstance(p, str) and p.startswith(root) and "/../" not in p and os.path.exists(p)]

    async def send_text(self, msg):
        sid = await asyncio.get_running_loop().run_in_executor(None, self.live_sid, msg)
        if not sid:
            return await self.reply(msg, False, "That session is not running. Reopen it first.")
        text = (msg.get("text") or "").strip()
        files = self.phone_files(msg)
        if not text and not files:
            return await self.reply(msg, False, "Nothing to send.")
        body = "\n\n".join(x for x in [text, "\n".join(files)] if x)
        ok = await asyncio.get_running_loop().run_in_executor(None, paste, sid, body)
        await self.reply(msg, ok, "Sent." if ok else "That terminal is gone.", text=body)

    async def keys(self, msg):
        sid = await asyncio.get_running_loop().run_in_executor(None, self.live_sid, msg)
        if not sid:
            return await self.reply(msg, False, "That session is not running. Reopen it first.")
        for n in msg.get("keys") or []:
            if n in KEYS:
                tmux("send-keys", "-t", pane(sid), KEYS[n])
            elif isinstance(n, str) and len(n) == 1 and n.isascii() and n.isalnum():
                tmux("send-keys", "-t", pane(sid), "-l", n)
            else:
                return await self.reply(msg, False, f"Unknown key “{n}”.")
        await self.reply(msg, True, "Sent.")

    async def put(self, msg):
        up = (msg.get("up") or "").lower()
        if len(up) != 36 or not re.fullmatch(r"[0-9a-f-]{36}", up):
            return await self.reply(msg, False, "Which file?")
        seq = msg.get("seq", -1)
        try:
            data = base64.b64decode(msg.get("data") or "", validate=True)
        except ValueError:
            return await self.reply(msg, False, "That part of the file did not arrive whole.")
        if seq == 0:
            d = state_dir() + "/phone/" + up
            os.makedirs(d, exist_ok=True)
            name = os.path.basename((msg.get("name") or "").replace(":", "-")).strip().lstrip(".")[:120] or "file"
            path = d + "/" + name
            open(path, "wb").close()
            self.uploads[up] = [path, 0, 0]
        u = self.uploads.get(up)
        if not u or u[1] != seq:
            self.uploads.pop(up, None)
            return await self.reply(msg, False, "A part of the file went missing. Send it again.")
        u[2] += len(data)
        if u[2] > 500 << 20:
            self.uploads.pop(up, None)
            return await self.reply(msg, False, "That file is too big (more than 500 MB).")
        with open(u[0], "ab") as f:
            f.write(data)
        u[1] += 1
        if msg.get("last"):
            self.uploads.pop(up, None)
            await self.reply(msg, True, "Saved.", path=u[0])
        else:
            await self.reply(msg, True, "")

    async def new(self, msg):
        c = conf()
        login = msg.get("login") or "~/.claude"
        known = [l.get("d") for l in c.get("logins") or mac_rows()[2].get("logins") or []] or ["~/.claude"]
        if login not in known:
            return await self.reply(msg, False, f"Unknown login {login}.")
        folder = (msg.get("cwd") or "~").strip() or "~"
        if not os.path.isdir(expand(folder)):
            return await self.reply(msg, False, f"There is no folder {folder} on {c.get('name') or 'this machine'}.")
        sid = str(uuid.uuid4())
        text = "\n\n".join(x for x in [(msg.get("prompt") or "").strip(), "\n".join(self.phone_files(msg))] if x)
        args = ["start", sid, login, folder, "new"]
        if text:
            first = state_dir() + f"/first-{sid}.txt"
            with open(first, "w") as f:
                f.write(" " + text if text.startswith("-") else text)
            args.append(first)
        code, out = await asyncio.get_running_loop().run_in_executor(None, lambda: helper(*args))
        if code != 0:
            return await self.reply(msg, False, (out.strip().splitlines() or ["Claude did not start."])[-1])
        started = read_json(state_dir() + "/started.json", {})
        started[sid] = {"cwd": folder, "login": login, "at": time.time()}
        write_json(state_dir() + "/started.json", started)
        await self.reply(msg, True, f"Started on {c.get('name') or 'this machine'}.", sf="here:" + sid, k="claude:" + sid)
        await broadcast_sessions()

    async def op(self, msg):
        name = msg.get("op") or ""
        k = msg.get("k") or ""
        sid = k.split(":", 1)[-1]
        if not re.fullmatch(r"[0-9a-f-]{36}", sid):
            return await self.reply(msg, False, "Which session?")
        if name in ("close", "done", "park"):
            await asyncio.get_running_loop().run_in_executor(None, lambda: helper("stop", sid))
            await self.reply(msg, True, "Closed. Its conversation stays; the Mac can resume it.")
            return await broadcast_sessions()
        if name == "ack":
            return await self.reply(msg, True, "")
        if name == "rename":
            n = (msg.get("name") or "").strip()[:80]
            if not n:
                return await self.reply(msg, False, "Which name?")
            names = read_json(state_dir() + "/names.json", {})
            names[sid] = n
            write_json(state_dir() + "/names.json", names)
            await self.reply(msg, True, "Renamed.")
            return await broadcast_sessions()
        if name == "open":
            return await self.reply(msg, sid in live_sessions(), "It runs." if sid in live_sessions() else "Resume it on the Mac.")
        await self.reply(msg, False, f"Only the Mac can do “{name}”.")


def paste(sid, text):
    buf = "sbphone-" + uuid.uuid4().hex[:8]
    if tmux("load-buffer", "-b", buf, "-", input=text.encode())[0] != 0:
        return False
    if tmux("paste-buffer", "-p", "-d", "-b", buf, "-t", pane(sid))[0] != 0:
        return False
    time.sleep(0.2)
    return tmux("send-keys", "-t", pane(sid), "Enter")[0] == 0


PHONES = set()


async def broadcast_sessions():
    signed = [p for p in PHONES if p.person]
    if not signed:
        return
    current = (await asyncio.get_running_loop().run_in_executor(None, rows))[0]
    for p in signed:
        try:
            await p.push_sessions(current=current)
        except Exception:
            pass


async def ticker():
    while True:
        await asyncio.sleep(1)
        try:
            await broadcast_sessions()
        except Exception as e:
            log("sessions:", e)
        for p in list(PHONES):
            if p.person and p.watch:
                try:
                    await p.poll_watch()
                except Exception:
                    pass


# MARK: Telling Simplero where this machine is

def machine_id():
    path = state_dir() + "/serve-machine-id"
    try:
        with open(path) as f:
            s = f.read().strip()
            if s:
                return s
    except OSError:
        pass
    s = str(uuid.uuid4())
    os.makedirs(state_dir(), exist_ok=True)
    with open(path, "w") as f:
        f.write(s)
    return s


def report():
    c = conf()
    if not c.get("key") or c.get("report") is False:
        return
    ip, dns = ts_self()
    body = {"name": c.get("name") or os.uname().nodename, "port": int(c.get("port") or 4480), "app_build": int(c.get("build") or 0)}
    if ip:
        body["tailscale_ip"] = ip
    if dns:
        body["tailscale_name"] = dns
    server = (c.get("server") or "https://simplero.com").rstrip("/")
    req = urllib.request.Request(server + "/api/mobile/v1/switchboard/machines/" + machine_id(), data=json.dumps(body).encode(), method="PUT",
                                 headers={"X-API-Key": c["key"], "Content-Type": "application/json", "Accept": "application/json", "User-Agent": "Switchboard/1"})
    try:
        urllib.request.urlopen(req, timeout=20).read()
    except Exception as e:
        log("report:", e)


async def reporter():
    while True:
        await asyncio.get_running_loop().run_in_executor(None, report)
        await asyncio.sleep(120)


async def main():
    c = conf()
    port = int(c.get("port") or 4480)
    hosts = ["127.0.0.1"]
    if not c.get("loopback_only"):
        ip, _ = ts_self()
        if not ip:
            # Tailscale is not up yet: systemd starts this again in a moment.
            log("no Tailscale address yet")
            sys.exit(1)
        hosts.append(ip)
    async def accept(reader, writer):
        p = Phone(reader, writer)
        PHONES.add(p)
        await p.serve()
    servers = []
    for h in hosts:
        try:
            servers.append(await asyncio.start_server(accept, h, port, limit=4 << 20))
        except OSError as e:
            log(f"listen {h}:{port}:", e)
    if not servers:
        log("nothing to listen on")
        sys.exit(1)
    log(f"switchboard-serve {VERSION} on {', '.join(hosts)} port {port}")
    asyncio.create_task(ticker())
    asyncio.create_task(reporter())
    await asyncio.Event().wait()


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "version":
        print(VERSION)
        sys.exit(0)
    asyncio.run(main())
