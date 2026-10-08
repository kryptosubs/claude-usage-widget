"""Run with:  python3 -m unittest discover -s tests   (from the repo root)

Builds a fake home directory with every source the dashboard reads, plus a stub
Ollama server, then checks what the collector makes of them.
"""

import importlib
import json
import os
import shutil
import sys
import tempfile
import threading
import unittest
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

NOW = datetime(2026, 10, 8, 21, 46, tzinfo=timezone.utc)          # Thu 2:46 PM PT
RESET = datetime(2026, 10, 12, 16, 0, tzinfo=timezone.utc)        # Mon 9:00 AM PT
SESSION_RESET = NOW + timedelta(hours=2, minutes=14)


def z(d):
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")


class StubOllama(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        body = {
            "/api/version": {"version": "0.12.9"},
            "/api/tags": {"models": [
                {"name": "qwen3.8:27b-mlx", "size": 18_000_000_000, "details": {"parameter_size": "27B", "quantization_level": "mixed"}},
                {"name": "nemotron-3.5-lightning:30b-mlx", "size": 23_000_000_000, "details": {"parameter_size": "30B"}},
            ]},
            "/api/ps": {"models": [{"name": "qwen3.8:27b-mlx", "size": 19_500_000_000, "size_vram": 19_500_000_000,
                                    "expires_at": "2026-10-08T15:00:00-07:00"}]},
        }.get(self.path)
        data = json.dumps(body or {}).encode()
        self.send_response(200 if body else 404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def build_home(home, ollama_url):
    snap = home / "Library" / "Application Support" / "ClaudeUsage"
    snap.mkdir(parents=True)
    payload = {
        "five_hour": {"utilization": 12.0},
        "tangelo": None,
        "limits": [
            {"kind": "session", "percent": 42, "resets_at": z(SESSION_RESET)},
            {"kind": "weekly_all", "percent": 71, "resets_at": z(RESET) + ".123456"},
            {"kind": "weekly_scoped", "percent": 0, "scope": {"model": {"display_name": "Sonnet"}}},
            {"kind": "weekly_scoped", "percent": 30, "resets_at": z(RESET), "scope": {"model": {"display_name": "Opus"}}},
        ],
        "spend": {"enabled": True, "used": {"amount_minor": 1250, "currency": "USD", "exponent": 2},
                  "limit": {"amount_minor": 5000, "currency": "USD", "exponent": 2}},
    }
    (snap / "latest.json").write_text(json.dumps({
        "schema": 1, "status": "live", "account": "kryptosubs@gmail.com",
        "fetched_at": z(NOW - timedelta(minutes=2)), "written_at": z(NOW), "payload": payload}))
    # history: steady climb that reaches 71% now (~21.9%/day)
    lines = []
    start = RESET - timedelta(days=7)
    t = start + timedelta(hours=6)
    while t < NOW - timedelta(minutes=5):
        hours = (t - start).total_seconds() / 3600
        p = hours * 71.0 / ((NOW - start).total_seconds() / 3600)
        lines.append(json.dumps({"t": z(t), "rows": [{"k": "weekly_all", "p": round(p, 1), "r": z(RESET)},
                                                     {"k": "session", "p": 10, "r": z(SESSION_RESET)}]}))
        t += timedelta(minutes=30)
    lines.append(json.dumps({"t": z(start - timedelta(days=3)), "rows": [{"k": "weekly_all", "p": 99}]}))  # previous window
    lines.append("not json")
    (snap / "history.jsonl").write_text("\n".join(lines) + "\n")

    proj = home / ".claude" / "projects" / "-Users-cp-code-smallbiz"
    proj.mkdir(parents=True)
    msgs = []
    for i in range(5):
        msgs.append({"type": "assistant", "timestamp": z(NOW - timedelta(hours=i * 20)), "cwd": "/Users/cp/code/smallbiz",
                     "sessionId": "s1", "requestId": "req%d" % i,
                     "message": {"id": "msg%d" % i, "model": "claude-sonnet-4-5",
                                 "usage": {"input_tokens": 100, "output_tokens": 50, "cache_creation_input_tokens": 1000,
                                           "cache_read_input_tokens": 9000}}})
    msgs.append(dict(msgs[0]))                                           # streamed duplicate
    msgs.append({"type": "assistant", "timestamp": z(NOW - timedelta(days=9)), "cwd": "/Users/cp/code/smallbiz",
                 "message": {"id": "old", "usage": {"input_tokens": 999999}}})   # before the window
    msgs.append({"type": "user", "timestamp": z(NOW), "message": {"content": "hi"}})
    (proj / "s1.jsonl").write_text("\n".join(json.dumps(m) for m in msgs) + "\n")
    proj2 = home / ".claude" / "projects" / "-Users-cp-code-kryptohead-home"
    proj2.mkdir(parents=True)
    (proj2 / "s2.jsonl").write_text(json.dumps(
        {"timestamp": z(NOW - timedelta(hours=1)), "cwd": "/Users/cp/code/kryptohead-home", "sessionId": "s2",
         "requestId": "x", "message": {"id": "m", "model": "claude-opus-4-1",
                                       "usage": {"input_tokens": 10, "output_tokens": 20}}}) + "\n")

    logs = home / ".ollama" / "logs"
    logs.mkdir(parents=True)
    local_today = NOW.astimezone().strftime("%Y/%m/%d")
    local_yday = (NOW.astimezone() - timedelta(days=1)).strftime("%Y/%m/%d")
    gin = [
        '[GIN] %s - 14:02:11 | 200 |  1.234s |       127.0.0.1 | POST     "/api/chat"' % local_today,
        '[GIN] %s - 14:03:11 | 200 |  2m3.5s |       127.0.0.1 | POST     "/v1/chat/completions"' % local_today,
        '[GIN] %s - 14:04:11 | 200 |    501µs |       127.0.0.1 | GET      "/api/tags"' % local_today,
        '[GIN] %s - 14:05:11 | 500 |  1.0s |       127.0.0.1 | POST     "/api/generate"' % local_today,
        '[GIN] %s - 09:00:00 | 200 |  800ms |       127.0.0.1 | POST     "/api/generate"' % local_yday,
        'time=2026-10-08T14:00:00 level=INFO msg="loaded"',
    ]
    (logs / "server.log").write_text("\n".join(gin) + "\n")

    app = home / "Library" / "Application Support" / "ai-usage"
    app.mkdir(parents=True)
    (app / "config.json").write_text(json.dumps({"ollama": {"url": ollama_url}, "port": 0}))


class AiUsageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="aiu-"))
        cls.ollama = ThreadingHTTPServer(("127.0.0.1", 0), StubOllama)
        threading.Thread(target=cls.ollama.serve_forever, daemon=True).start()
        build_home(cls.tmp, "http://127.0.0.1:%d" % cls.ollama.server_address[1])
        os.environ["AIU_HOME"] = str(cls.tmp)
        os.environ["AIU_NOW"] = z(NOW)
        import aiusage
        cls.m = importlib.reload(aiusage)
        cls.data = cls.m.collect()

    @classmethod
    def tearDownClass(cls):
        cls.ollama.shutdown()
        cls.ollama.server_close()
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_parse_iso(self):
        p = self.m.parse_iso
        base = datetime(2026, 9, 22, 18, 0, tzinfo=timezone.utc)
        self.assertEqual(p("2026-09-22T18:00:00Z"), base)
        self.assertEqual(p("2026-09-22T18:00:00.123456789+00:00"), base)
        self.assertEqual(p("2026-09-22T18:00:00"), base)
        self.assertEqual(p("2026-09-22T11:00:00-0700"), base)
        self.assertEqual(p("2026-09-22T11:00:00-07:00"), base)
        self.assertIsNone(p("garbage"))
        self.assertIsNone(p(None))

    def test_rows_match_the_menu_bar_parser(self):
        rows = self.data["claude"]["rows"]
        self.assertEqual([r["key"] for r in rows], ["session", "weekly_all", "weekly_scoped:Opus", "spend"])
        self.assertEqual(rows[0]["percent"], 42)
        spend = rows[-1]
        self.assertEqual((spend["used"], spend["limit"], round(spend["percent"])), (12.5, 50.0, 25))
        legacy = self.m.claude_rows({"five_hour": {"utilization": 0.35}, "seven_day": {"utilization": 60},
                                     "seven_day_opus": None,
                                     "extra_usage": {"is_enabled": True, "used_credits": 250000,
                                                     "monthly_limit": 1000000, "decimal_places": 4}})
        self.assertEqual([r["key"] for r in legacy], ["session", "weekly_all", "spend"])
        self.assertAlmostEqual(legacy[0]["percent"], 35)
        self.assertAlmostEqual(legacy[2]["used"], 25.0)

    def test_weekly_projection(self):
        w = self.data["claude"]["weekly"]
        self.assertEqual(w["verdict"], "over")
        self.assertEqual(w["window_start"], z(RESET - timedelta(days=7)))
        # ~0.91 %/h -> the 29 % left lasts ~32 h -> late Friday, well before Monday's reset
        hit = self.m.parse_iso(w["projected_hit"])
        self.assertTrue(NOW + timedelta(hours=30) < hit < NOW + timedelta(hours=48), w["projected_hit"])
        self.assertAlmostEqual(w["rate_per_day"], 21.9, delta=0.6)
        self.assertAlmostEqual(w["sustainable_per_day"], 14.29, delta=0.01)
        self.assertAlmostEqual(w["pace_percent"], 46.3, delta=0.5)
        self.assertEqual(w["projected_at_reset"], 100.0)
        # the reading from the previous window is not part of this one
        self.assertTrue(all(p["p"] <= 71 for p in w["series"]))

    def test_on_pace_when_slow(self):
        start = RESET - timedelta(days=7)
        hist = [(start + timedelta(hours=h), {"weekly_all": {"p": h * 0.3, "r": RESET}}) for h in range(0, 80, 2)]
        b = self.m.burn(hist, "weekly_all", 24.0, RESET, NOW, self.m.WEEK)
        self.assertEqual(b["verdict"], "ok")
        self.assertIsNone(b["projected_hit"])
        self.assertLess(b["projected_at_reset"], 100)

    def test_claude_code_by_project(self):
        cc = self.data["claude_code"]
        names = [p["name"] for p in cc["projects"]]
        self.assertEqual(names, ["smallbiz", "kryptohead-home"])
        sb = cc["projects"][0]
        # 4 unique messages since the weekly reset: the duplicate is dropped, and the
        # 80-hour-old and 9-day-old ones fall before the window (it opened 78 h ago)
        self.assertEqual(sb["messages"], 4)
        self.assertEqual(sb["tokens"], 4 * (100 + 50 + 1000))
        self.assertEqual(sb["cache_read"], 4 * 9000)
        self.assertEqual(sb["sessions"], 1)
        self.assertEqual(sum(d["messages"] for d in cc["days"]), 5)
        self.assertEqual(cc["models"][0]["model"], "claude-sonnet-4-5")

    def test_ollama(self):
        o = self.data["ollama"]
        self.assertTrue(o["reachable"], o.get("error"))
        self.assertEqual(o["version"], "0.12.9")
        self.assertEqual([m["name"] for m in o["installed"]], ["nemotron-3.5-lightning:30b-mlx", "qwen3.8:27b-mlx"])
        self.assertEqual(o["loaded"][0]["name"], "qwen3.8:27b-mlx")
        self.assertEqual(o["disk_bytes"], 41_000_000_000)
        req = {r["date"]: r["requests"] for r in o["requests"]}
        today = NOW.astimezone().strftime("%Y-%m-%d")
        yday = (NOW.astimezone() - timedelta(days=1)).strftime("%Y-%m-%d")
        self.assertEqual(req[today], 2)        # GET /api/tags and the 500 are not counted
        self.assertEqual(req[yday], 1)
        self.assertEqual(len(o["requests"]), 7)

    def test_durations(self):
        f = self.m._dur_seconds
        self.assertAlmostEqual(f("1.234s"), 1.234)
        self.assertAlmostEqual(f("800ms"), 0.8)
        self.assertAlmostEqual(f("2m3.5s"), 123.5)
        self.assertAlmostEqual(f("501µs"), 0.000501)

    def test_stale_snapshot(self):
        os.environ["AIU_NOW"] = z(NOW + timedelta(hours=1))
        try:
            c = self.m.collect_claude(self.m.now_utc())
            self.assertEqual(c["status"], "stale")
        finally:
            os.environ["AIU_NOW"] = z(NOW)

    def test_missing_snapshot(self):
        saved = self.m.SNAP_DIR
        self.m.SNAP_DIR = self.tmp / "nowhere"
        try:
            c = self.m.collect_claude(NOW)
            self.assertFalse(c["available"])
            self.assertEqual(c["hint"], "no_snapshot")
        finally:
            self.m.SNAP_DIR = saved

    def test_access_key_gate(self):
        key = self.m.access_key()
        self.assertGreaterEqual(len(key), 16)
        self.assertEqual(oct(os.stat(self.m.APP_DIR / "key").st_mode & 0o777), "0o600")
        H = self.m.make_handler(self.m.Cache(), key)

        class Fake:
            pass

        def authed(ip, query=None, cookie=None):
            f = Fake()
            f.client_address = (ip, 5555)
            f.headers = {"Cookie": cookie} if cookie else {}
            f._local = lambda: H._local(f)
            return H._authed(f, query or {})

        self.assertTrue(authed("127.0.0.1"))
        self.assertFalse(authed("192.168.86.40"))
        self.assertFalse(authed("192.168.86.40", {"k": ["wrong"]}))
        self.assertTrue(authed("192.168.86.40", {"k": [key]}))
        self.assertTrue(authed("192.168.86.40", cookie="x=1; aiu_k=" + key))
        self.assertFalse(authed("192.168.86.40", cookie="aiu_k=" + key[:-1]))

    def test_server_end_to_end(self):
        import urllib.request
        key = self.m.access_key()
        srv = ThreadingHTTPServer(("127.0.0.1", 0), self.m.make_handler(self.m.Cache(), key))
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        base = "http://127.0.0.1:%d" % srv.server_address[1]
        try:
            with urllib.request.urlopen(base + "/api/data") as r:
                j = json.loads(r.read())
                self.assertIn("default-src 'self'", r.headers["Content-Security-Policy"])
            self.assertEqual(j["claude"]["status"], "live")
            with urllib.request.urlopen(base + "/") as r:
                self.assertIn(b"/app.js", r.read())
            with urllib.request.urlopen(base + "/healthz") as r:
                self.assertEqual(r.read(), b"ok\n")
        finally:
            srv.shutdown()
            srv.server_close()


if __name__ == "__main__":
    unittest.main()
