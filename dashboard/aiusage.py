#!/usr/bin/env python3
"""ai-usage: a personal AI usage and quota dashboard that runs on the Mac Studio.

Standard library only, Python 3.9+ (the version macOS's Command Line Tools ship).

Sources, all local:
  Claude plan limits   ~/Library/Application Support/ClaudeUsage/{latest.json,history.jsonl}
                       written by the Claude Usage menu-bar app (v1.3+). This process never
                       reads or refreshes the Claude login: refresh tokens rotate, and two
                       refreshers would log each other out.
  Claude Code tokens   ~/.claude/projects/**/*.jsonl (Claude Code's own transcripts)
  Ollama               http://127.0.0.1:11434/api/{ps,tags,version} and ~/.ollama/logs/server*.log
  Plans and prices     config.json (things with no usage API: Gemini, Grok, Muse)

  python3 aiusage.py serve     run the dashboard (what the LaunchAgent does)
  python3 aiusage.py once      print the collected data as JSON and exit
  python3 aiusage.py url       print the links that open the dashboard
"""

import glob
import hmac
import json
import os
import re
import secrets
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

VERSION = "1.0.0"

HOME = Path(os.environ.get("AIU_HOME") or str(Path.home()))
ROOT = Path(__file__).resolve().parent
WEB = ROOT / "web"
APP_DIR = HOME / "Library" / "Application Support" / "ai-usage"
SNAP_DIR = HOME / "Library" / "Application Support" / "ClaudeUsage"
PROJECT_DIRS = [HOME / ".claude" / "projects", HOME / ".config" / "claude" / "projects"]
OLLAMA_LOG_DIR = HOME / ".ollama" / "logs"

WEEK = timedelta(days=7)
GEN_PATHS = ("/api/chat", "/api/generate", "/v1/chat/completions", "/v1/completions",
             "/v1/messages", "/v1/responses")


# ---------------------------------------------------------------- time helpers

_FRAC = re.compile(r"\.\d+")
_OFF_NOCOLON = re.compile(r"([+-]\d{2})(\d{2})$")


def parse_iso(s):
    """ISO 8601 with Z, +hh:mm, +hhmm, any fractional digits, or naive (= UTC)."""
    if not s or not isinstance(s, str):
        return None
    t = s.strip()
    t = _FRAC.sub("", t, count=1)
    if t.endswith("Z") or t.endswith("z"):
        t = t[:-1] + "+00:00"
    m = _OFF_NOCOLON.search(t)
    if m and t[-6] not in "+-":
        t = t[: m.start()] + m.group(1) + ":" + m.group(2)
    try:
        d = datetime.fromisoformat(t)
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=timezone.utc)
    return d


def iso(d):
    return d.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if d else None


def now_utc():
    override = os.environ.get("AIU_NOW")
    return parse_iso(override) if override else datetime.now(timezone.utc)


def local_day(d):
    return d.astimezone().strftime("%Y-%m-%d")


# ---------------------------------------------------------------- config

DEFAULT_CONFIG = {
    "port": 8787,
    "bind": "0.0.0.0",
    "plans": [
        {"id": "claude", "name": "Claude Pro", "monthly": 20, "meter": "live",
         "en": "Chat, Cowork, Claude Code, browser agents and scheduled tasks share one allowance",
         "zh": "聊天、Cowork、Claude Code、瀏覽器代理、排程任務共用一個額度"},
        {"id": "gemini", "name": "Google AI Pro", "monthly": 19.99, "meter": "none",
         "en": "Shared with I-Wen and Isaac. No usage API", "zh": "已分享給 I-Wen 和 Isaac，沒有用量 API"},
        {"id": "grok", "name": "X Premium (Grok)", "monthly": 8, "meter": "none",
         "en": "Rate-limited Grok. No usage API", "zh": "有額度限制的 Grok，沒有用量 API"},
        {"id": "muse", "name": "Meta Muse", "monthly": 0, "meter": "none",
         "en": "Free tier, 100M tokens a week. No usage API", "zh": "免費版，每週 1 億 token，沒有用量 API"},
        {"id": "ollama", "name": "Ollama (Mac Studio)", "monthly": 0, "meter": "live",
         "en": "Local, no quota", "zh": "本機，沒有額度"},
    ],
    "ollama": {"url": "http://127.0.0.1:11434", "primary": "qwen3.8:27b-mlx",
               "backup": "nemotron-3.5-lightning"},
}


def load_config():
    cfg = json.loads(json.dumps(DEFAULT_CONFIG))
    p = APP_DIR / "config.json"
    user = {}
    try:
        user = json.loads(p.read_text(encoding="utf-8"))
        for k, v in user.items():
            if isinstance(v, dict) and isinstance(cfg.get(k), dict):
                cfg[k].update(v)
            else:
                cfg[k] = v
    except (OSError, ValueError, AttributeError):
        pass
    env = os.environ.get("OLLAMA_HOST")
    if env and "url" not in (user.get("ollama") or {}) and not env.startswith("0.0.0.0"):
        cfg["ollama"]["url"] = env if env.startswith("http") else "http://" + env
    return cfg


def access_key():
    """Random key that gates access from other devices. Created on first use."""
    p = APP_DIR / "key"
    try:
        k = p.read_text().strip()
        if len(k) >= 16:
            return k
    except OSError:
        pass
    APP_DIR.mkdir(parents=True, exist_ok=True)
    k = secrets.token_urlsafe(18)
    p.write_text(k + "\n")
    os.chmod(p, 0o600)
    return k


# ---------------------------------------------------------------- Claude plan limits

def _num(v):
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        try:
            return float(v)
        except ValueError:
            return None
    return None


def _pct(v):
    """The API reports 0-100; a fractional value at or below 1 is a 0-1 ratio."""
    n = _num(v)
    if n is None:
        return None
    return n * 100 if (n <= 1 and n != int(n)) else n


def _scope_name(l):
    sc = l.get("scope") if isinstance(l, dict) else None
    if not isinstance(sc, dict):
        return None
    m = sc.get("model")
    if isinstance(m, dict) and m.get("display_name"):
        return m["display_name"]
    s = sc.get("surface")
    if isinstance(s, str) and s:
        return s
    if isinstance(s, dict) and s.get("display_name"):
        return s["display_name"]
    return None


def _minor(v, exp):
    n = _num(v)
    if n is None:
        return None
    e = int(_num(exp) if _num(exp) is not None else 2)
    e = e if 0 <= e <= 6 else 2
    return n / (10 ** e)


def claude_rows(d):
    """Same rules as the menu-bar app's UsageParser: prefer `limits`, fall back to named fields."""
    rows = []
    if not isinstance(d, dict):
        return rows
    for l in d.get("limits") or []:
        if not isinstance(l, dict):
            continue
        pct = _num(l.get("percent"))
        if pct is None:
            continue
        kind = l.get("kind") or ""
        reset = l.get("resets_at")
        if kind == "weekly_scoped" and pct <= 0 and not reset:
            continue
        key = kind
        if kind == "weekly_scoped":
            n = _scope_name(l)
            if n:
                key = "weekly_scoped:" + n
        rows.append({"key": key, "percent": pct, "resets_at": iso(parse_iso(reset)),
                     "severity": l.get("severity") or ""})
    if not rows:
        for field, key in (("five_hour", "session"), ("seven_day", "weekly_all"),
                           ("seven_day_opus", "weekly_scoped:Opus"),
                           ("seven_day_sonnet", "weekly_scoped:Sonnet")):
            w = d.get(field)
            if not isinstance(w, dict):
                continue
            p = _pct(w.get("utilization"))
            if p is None:
                continue
            rows.append({"key": key, "percent": p, "resets_at": iso(parse_iso(w.get("resets_at"))),
                         "severity": ""})
    spend = _spend(d)
    if spend:
        rows.append(spend)
    return rows


def _spend(d):
    sp = d.get("spend")
    if isinstance(sp, dict) and sp.get("enabled"):
        used = limit = exp = cur = None
        u = sp.get("used")
        if isinstance(u, dict):
            exp, cur = u.get("exponent"), u.get("currency")
            used = _minor(u.get("amount_minor"), exp)
        lo = sp.get("limit")
        if isinstance(lo, dict):
            exp = exp if exp is not None else lo.get("exponent")
            cur = cur or lo.get("currency")
            limit = _minor(lo.get("amount_minor"), exp)
        pct = _num(sp.get("percent"))
        if pct is None and used is not None and limit:
            pct = used / limit * 100
        return {"key": "spend", "percent": pct or 0, "resets_at": None, "severity": sp.get("severity") or "",
                "used": used, "limit": limit, "currency": (cur or "USD").upper()}
    e = d.get("extra_usage")
    if isinstance(e, dict) and e.get("is_enabled"):
        dp = e.get("decimal_places")
        used, limit = _minor(e.get("used_credits"), dp), _minor(e.get("monthly_limit"), dp)
        pct = _pct(e.get("utilization"))
        if pct is None and used is not None and limit:
            pct = used / limit * 100
        return {"key": "spend", "percent": pct or 0, "resets_at": None, "severity": "",
                "used": used, "limit": limit, "currency": (e.get("currency") or "USD").upper()}
    return None


def read_history(now, days=8):
    out = []
    cutoff = now - timedelta(days=days)
    p = SNAP_DIR / "history.jsonl"
    try:
        with open(p, encoding="utf-8") as f:
            for line in f:
                try:
                    j = json.loads(line)
                except ValueError:
                    continue
                t = parse_iso(j.get("t"))
                if not t or t < cutoff:
                    continue
                pts = {}
                for r in j.get("rows") or []:
                    if isinstance(r, dict) and r.get("k") is not None and _num(r.get("p")) is not None:
                        pts[r["k"]] = {"p": _num(r["p"]), "r": parse_iso(r.get("r"))}
                out.append((t, pts))
    except OSError:
        pass
    out.sort(key=lambda x: x[0])
    return out


def burn(history, key, pct, reset, now, window):
    """Pace and projection for one limit inside its current window."""
    if pct is None or reset is None:
        return None
    start = reset - window
    elapsed = (now - start).total_seconds() / 3600
    total = window.total_seconds() / 3600
    pts = [(t, v["p"]) for t, rows in history for k, v in rows.items()
           if k == key and t >= start and t <= now
           and (v["r"] is None or abs((v["r"] - reset).total_seconds()) < 3600)]
    pts.append((now, pct))
    rate = None
    recent = [x for x in pts if x[0] >= now - timedelta(hours=24)]
    if len(recent) >= 2 and (recent[-1][0] - recent[0][0]) >= timedelta(hours=3):
        dt = (recent[-1][0] - recent[0][0]).total_seconds() / 3600
        rate = max(0.0, (recent[-1][1] - recent[0][1]) / dt)
    elif elapsed > 0.5:
        rate = pct / elapsed
    hit = None
    if rate and rate > 0 and pct < 100:
        hit = now + timedelta(hours=(100 - pct) / rate)
    elif pct >= 100:
        hit = now
    pace = max(0.0, min(100.0, elapsed / total * 100)) if total else None
    projected_at_reset = None
    if rate is not None:
        hours_left = max(0.0, (reset - now).total_seconds() / 3600)
        projected_at_reset = min(100.0, pct + rate * hours_left)
    return {
        "key": key, "percent": pct, "reset": iso(reset), "window_start": iso(start),
        "rate_per_hour": round(rate, 3) if rate is not None else None,
        "rate_per_day": round(rate * 24, 2) if rate is not None else None,
        "sustainable_per_day": round(100 / (total / 24), 2) if total else None,
        "pace_percent": round(pace, 1) if pace is not None else None,
        "projected_hit": iso(hit) if hit and hit < reset else None,
        "projected_at_reset": round(projected_at_reset, 1) if projected_at_reset is not None else None,
        "verdict": ("capped" if pct >= 100 else "over" if (hit and hit < reset) else "ok"),
        "series": [{"t": iso(t), "p": round(p, 1)} for t, p in pts],
    }


def collect_claude(now):
    out = {"available": False, "status": "missing", "rows": [], "weekly": None, "session": None}
    try:
        j = json.loads((SNAP_DIR / "latest.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        out["hint"] = "no_snapshot"
        return out
    fetched = parse_iso(j.get("fetched_at"))
    out.update({
        "available": True,
        "status": j.get("status") or "unknown",
        "account": j.get("account"),
        "fetched_at": iso(fetched),
        "age_seconds": int((now - fetched).total_seconds()) if fetched else None,
        "rows": claude_rows(j.get("payload") or {}),
    })
    if fetched and (now - fetched) > timedelta(minutes=15) and out["status"] == "live":
        out["status"] = "stale"
    hist = read_history(now)
    rows = {r["key"]: r for r in out["rows"]}
    w = rows.get("weekly_all")
    if w:
        out["weekly"] = burn(hist, "weekly_all", w["percent"], parse_iso(w["resets_at"]), now, WEEK)
    s = rows.get("session")
    if s:
        out["session"] = burn(hist, "session", s["percent"], parse_iso(s["resets_at"]), now, timedelta(hours=5))
        out["session_series"] = [{"t": iso(t), "p": rows_["session"]["p"]}
                                 for t, rows_ in hist if "session" in rows_ and t >= now - timedelta(hours=24)]
    out["history_points"] = len(hist)
    return out


# ---------------------------------------------------------------- Claude Code transcripts

def _project_name(cwd, folder):
    if cwd:
        name = os.path.basename(cwd.rstrip("/")) or cwd
        if cwd.rstrip("/") == str(HOME):
            return "~"
        return name
    # folder names are the cwd with / replaced by -
    return folder.rsplit("-", 1)[-1] or folder


def collect_claude_code(now, since):
    out = {"available": False, "files": 0, "since": iso(since), "projects": [], "days": [], "models": []}
    files = []
    for base in PROJECT_DIRS:
        files.extend(glob.glob(str(base / "*" / "*.jsonl")))
        files.extend(glob.glob(str(base / "*" / "*" / "*.jsonl")))
    cutoff_ts = since.timestamp() - 3600
    seen = set()
    projects, days, models = {}, {}, {}
    for f in files:
        try:
            if os.path.getmtime(f) < cutoff_ts:
                continue
        except OSError:
            continue
        out["files"] += 1
        folder = os.path.basename(os.path.dirname(f))
        try:
            fh = open(f, encoding="utf-8", errors="replace")
        except OSError:
            continue
        with fh:
            for line in fh:
                if '"usage"' not in line:
                    continue
                try:
                    j = json.loads(line)
                except ValueError:
                    continue
                msg = j.get("message")
                if not isinstance(msg, dict) or not isinstance(msg.get("usage"), dict):
                    continue
                t = parse_iso(j.get("timestamp"))
                if not t or t < since or t > now + timedelta(minutes=5):
                    continue
                uid = (msg.get("id") or "") + "|" + (j.get("requestId") or "")
                if uid != "|":
                    if uid in seen:
                        continue
                    seen.add(uid)
                u = msg["usage"]
                inp = int(_num(u.get("input_tokens")) or 0)
                outp = int(_num(u.get("output_tokens")) or 0)
                cw = int(_num(u.get("cache_creation_input_tokens")) or 0)
                cr = int(_num(u.get("cache_read_input_tokens")) or 0)
                name = _project_name(j.get("cwd"), folder)
                p = projects.setdefault(name, {"name": name, "input": 0, "output": 0, "cache_write": 0,
                                               "cache_read": 0, "messages": 0, "sessions": set()})
                p["input"] += inp
                p["output"] += outp
                p["cache_write"] += cw
                p["cache_read"] += cr
                p["messages"] += 1
                if j.get("sessionId"):
                    p["sessions"].add(j["sessionId"])
                day = local_day(t)
                dd = days.setdefault(day, {"date": day, "tokens": 0, "messages": 0})
                dd["tokens"] += inp + outp + cw
                dd["messages"] += 1
                model = msg.get("model") or "unknown"
                if model != "<synthetic>":
                    mm = models.setdefault(model, {"model": model, "tokens": 0, "messages": 0})
                    mm["tokens"] += inp + outp + cw
                    mm["messages"] += 1
    for p in projects.values():
        p["sessions"] = len(p["sessions"])
        p["tokens"] = p["input"] + p["output"] + p["cache_write"]
    out["projects"] = sorted(projects.values(), key=lambda p: -p["tokens"])
    out["days"] = sorted(days.values(), key=lambda d: d["date"])
    out["models"] = sorted(models.values(), key=lambda m: -m["tokens"])
    out["available"] = bool(files)
    out["dirs_found"] = [str(b) for b in PROJECT_DIRS if b.is_dir()]
    return out


# ---------------------------------------------------------------- Ollama

_GIN = re.compile(r"\[GIN\]\s+(\d{4}/\d{2}/\d{2})\s+-\s+(\d{2}:\d{2}:\d{2})\s+\|\s+(\d{3})\s+\|\s+([^|]+?)\s+\|"
                  r"\s+([^|]+?)\s+\|\s+(\w+)\s+\"([^\"]+)\"")


def _dur_seconds(s):
    s = s.strip()
    m = re.match(r"^([\d.]+)(ns|µs|us|ms|s|m|h)?$", s)
    if m:
        v = float(m.group(1))
        return v * {"ns": 1e-9, "µs": 1e-6, "us": 1e-6, "ms": 1e-3, "s": 1, "m": 60, "h": 3600}.get(m.group(2) or "s", 1)
    m = re.match(r"^(\d+)m([\d.]+)s$", s)
    if m:
        return int(m.group(1)) * 60 + float(m.group(2))
    m = re.match(r"^(\d+)h(\d+)m([\d.]+)s$", s)
    if m:
        return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))
    return None


def ollama_log_counts(now, days=7):
    """Requests per local day from Ollama's server log ([GIN] lines use local time)."""
    first = (now.astimezone() - timedelta(days=days - 1)).strftime("%Y-%m-%d")
    counts = {}
    durations = []
    files = sorted(glob.glob(str(OLLAMA_LOG_DIR / "server*.log")))
    for f in files:
        try:
            with open(f, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if "[GIN]" not in line:
                        continue
                    m = _GIN.search(line)
                    if not m:
                        continue
                    day = m.group(1).replace("/", "-")
                    if day < first:
                        continue
                    method, path = m.group(6), m.group(7).split("?")[0]
                    if method != "POST" or not path.startswith(GEN_PATHS):
                        continue
                    if not m.group(3).startswith("2"):
                        continue
                    counts[day] = counts.get(day, 0) + 1
                    d = _dur_seconds(m.group(4))
                    if d is not None:
                        durations.append(d)
        except OSError:
            continue
    series = []
    for i in range(days - 1, -1, -1):
        day = (now.astimezone() - timedelta(days=i)).strftime("%Y-%m-%d")
        series.append({"date": day, "requests": counts.get(day, 0)})
    durations.sort()
    median = durations[len(durations) // 2] if durations else None
    return {"log_found": bool(files), "requests": series, "median_seconds": round(median, 2) if median else None}


def _get_json(url, timeout=2.0):
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def mac_memory_bytes():
    try:
        out = subprocess.run(["/usr/sbin/sysctl", "-n", "hw.memsize"], capture_output=True, text=True, timeout=2)
        return int(out.stdout.strip())
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def collect_ollama(now, cfg):
    base = (cfg.get("ollama") or {}).get("url", "http://127.0.0.1:11434").rstrip("/")
    out = {"reachable": False, "url": base, "installed": [], "loaded": [],
           "primary": cfg["ollama"].get("primary"), "backup": cfg["ollama"].get("backup")}
    try:
        out["version"] = _get_json(base + "/api/version").get("version")
        tags = _get_json(base + "/api/tags").get("models") or []
        ps = _get_json(base + "/api/ps").get("models") or []
        out["reachable"] = True
        out["installed"] = sorted(({"name": m.get("name"), "size": m.get("size"),
                                    "modified_at": m.get("modified_at"),
                                    "family": (m.get("details") or {}).get("family"),
                                    "params": (m.get("details") or {}).get("parameter_size"),
                                    "quant": (m.get("details") or {}).get("quantization_level")}
                                   for m in tags), key=lambda m: -(m["size"] or 0))
        out["loaded"] = [{"name": m.get("name"), "size": m.get("size"), "size_vram": m.get("size_vram"),
                          "expires_at": m.get("expires_at"), "context": m.get("context_length")}
                         for m in ps]
    except (urllib.error.URLError, OSError, ValueError, socket.timeout) as e:
        out["error"] = str(e)[:200]
    out["disk_bytes"] = sum(m["size"] or 0 for m in out["installed"])
    out["memory_bytes"] = mac_memory_bytes()
    out.update(ollama_log_counts(now))
    return out


# ---------------------------------------------------------------- snapshot of everything

def collect():
    now = now_utc()
    cfg = load_config()
    claude = collect_claude(now)
    since = now - WEEK
    if claude.get("weekly") and claude["weekly"].get("window_start"):
        since = parse_iso(claude["weekly"]["window_start"]) or since
    return {
        "version": VERSION,
        "generated_at": iso(now),
        "timezone": time.strftime("%Z"),
        "claude": claude,
        "claude_code": collect_claude_code(now, since),
        "ollama": collect_ollama(now, cfg),
        "plans": cfg.get("plans") or [],
    }


class Cache:
    def __init__(self, ttl=60):
        self.ttl, self.data, self.at, self.lock = ttl, None, 0.0, threading.Lock()

    def get(self):
        with self.lock:
            if self.data is None or time.time() - self.at > self.ttl:
                try:
                    self.data = json.dumps(collect(), ensure_ascii=False).encode("utf-8")
                except Exception as e:  # keep serving the last good snapshot
                    sys.stderr.write("collect failed: %r\n" % (e,))
                    if self.data is None:
                        self.data = json.dumps({"version": VERSION, "error": str(e)}).encode("utf-8")
                self.at = time.time()
            return self.data


# ---------------------------------------------------------------- web server

STATIC = {"/": ("index.html", "text/html; charset=utf-8"),
          "/app.js": ("app.js", "text/javascript; charset=utf-8"),
          "/style.css": ("style.css", "text/css; charset=utf-8")}

CSP = ("default-src 'self'; script-src 'self'; style-src 'self' https://fonts.googleapis.com; "
       "font-src https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self'; "
       "frame-ancestors 'none'; base-uri 'none'; form-action 'none'")


def make_handler(cache, key):
    class Handler(BaseHTTPRequestHandler):
        server_version = "ai-usage/" + VERSION
        sys_version = ""

        def log_message(self, fmt, *args):
            pass

        def _local(self):
            return self.client_address[0] in ("127.0.0.1", "::1")

        def _authed(self, query):
            if self._local():
                return True
            supplied = (query.get("k") or [""])[0]
            if supplied and hmac.compare_digest(supplied, key):
                return True
            for part in (self.headers.get("Cookie") or "").split(";"):
                name, _, val = part.strip().partition("=")
                if name == "aiu_k" and hmac.compare_digest(val, key):
                    return True
            return False

        def _send(self, code, body, ctype, extra=None):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Content-Security-Policy", CSP)
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def do_HEAD(self):
            self.do_GET()

        def do_GET(self):
            u = urllib.parse.urlsplit(self.path)
            q = urllib.parse.parse_qs(u.query)
            if u.path == "/healthz":
                return self._send(200, b"ok\n", "text/plain")
            if not self._authed(q):
                body = ("<!doctype html><meta charset=utf-8><title>ai-usage</title>"
                        "<p style='font:16px system-ui;margin:3em'>Open the link printed by "
                        "<code>install.sh</code> (or run <code>python3 aiusage.py url</code> on the Mac).</p>")
                return self._send(401, body.encode(), "text/html; charset=utf-8")
            if "k" in q:  # remember the key in a cookie and drop it from the address bar
                cookie = "aiu_k=%s; Max-Age=31536000; Path=/; HttpOnly; SameSite=Strict" % key
                return self._send(303, b"", "text/plain", {"Location": u.path or "/", "Set-Cookie": cookie})
            if u.path == "/api/data":
                return self._send(200, cache.get(), "application/json; charset=utf-8")
            if u.path in STATIC:
                name, ctype = STATIC[u.path]
                try:
                    return self._send(200, (WEB / name).read_bytes(), ctype)
                except OSError:
                    return self._send(500, b"missing web file", "text/plain")
            return self._send(404, b"not found", "text/plain")

    return Handler


def lan_ip():
    for iface in ("en0", "en1"):
        try:
            out = subprocess.run(["/usr/sbin/ipconfig", "getifaddr", iface], capture_output=True, text=True, timeout=2)
            ip = out.stdout.strip()
            if ip:
                return ip
        except (OSError, subprocess.SubprocessError):
            pass
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("192.0.2.1", 9))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return None


def links(cfg):
    key = access_key()
    port = cfg.get("port", 8787)
    out = ["On this Mac:    http://127.0.0.1:%d/" % port]
    ip = lan_ip()
    if ip:
        out.append("iPad / LAN:     http://%s:%d/?k=%s" % (ip, port, key))
    host = socket.gethostname().split(".")[0]
    out.append("By name:        http://%s.local:%d/?k=%s" % (host, port, key))
    return out


def serve():
    cfg = load_config()
    key = access_key()
    cache = Cache(ttl=int(cfg.get("refresh_seconds", 60)))
    srv = ThreadingHTTPServer((cfg.get("bind", "0.0.0.0"), int(cfg.get("port", 8787))), make_handler(cache, key))
    sys.stderr.write("ai-usage %s listening on %s:%s\n" % (VERSION, cfg.get("bind"), cfg.get("port")))
    srv.serve_forever()


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "serve"
    if cmd == "serve":
        serve()
    elif cmd == "once":
        print(json.dumps(collect(), ensure_ascii=False, indent=2))
    elif cmd == "url":
        print("\n".join(links(load_config())))
    elif cmd in ("-v", "--version", "version"):
        print(VERSION)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
