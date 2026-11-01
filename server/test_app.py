"""Tests for the Nodlock status server. Run: python3 -m unittest -v"""
import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

import app

TOKEN = "t" * 32
HB = {"host": "mac-mini", "generated_at": "2026-11-01T10:05:00+02:00",
      "summary": {"ok": 1, "failing": 0, "down": 0, "error": 0},
      "watches": [{"name": "api <b>", "status": "ok", "last_error": None}],
      "outside_targets": [{"name": "trade site", "url": "https://trade.example/", "expect": [200]}]}


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        self.cfg = app.load_config({"NODLOCK_TOKEN": TOKEN, "NTFY_TOPIC": "x", "DATA_DIR": self.dir,
                                    "SECRETS_DIR": self.dir})
        self.t = 1_800_000_000.0
        self.sent = []
        self.ok = True
        self.app = self.make()

    def make(self):
        a = app.App(self.cfg)
        a.clock = lambda: self.t
        a.started = self.t
        a.deliver = self.sent.append
        a.fetch = lambda url, expect: (True, None) if self.ok else (False, "connection refused")
        a.bg = lambda f, *args: f(*args)
        return a


class TestConfig(unittest.TestCase):
    def test_short_token_refused(self):
        with self.assertRaises(SystemExit):
            app.load_config({"NODLOCK_TOKEN": "short", "NTFY_TOPIC": "x"})

    def test_needs_a_channel(self):
        with self.assertRaises(SystemExit):
            app.load_config({"NODLOCK_TOKEN": TOKEN})


class TestLogic(Base):
    def test_heartbeat_stores_targets_and_returns_pending(self):
        r = self.app.heartbeat(dict(HB))
        self.assertTrue(r["ok"])
        self.assertEqual(r["outside"], [{"name": "trade site", "url": "https://trade.example/",
                                         "status": "pending", "checked_at": None,
                                         "last_ok": None, "last_error": None}])
        self.assertTrue(self.app.wake.is_set())  # prompt check requested
        self.app.check_all()
        out = self.app.heartbeat(dict(HB))["outside"][0]
        self.assertEqual(out["status"], "ok")
        self.assertEqual(out["checked_at"], app.iso(self.t))
        self.assertEqual(out["last_ok"], app.iso(self.t))

    def test_bad_targets_skipped(self):
        hb = dict(HB, outside_targets=[{"name": "x", "url": "file:///etc/passwd"}, "junk",
                                       {"name": "", "url": "https://a/"}, {"name": "ok", "url": "http://b/"}])
        self.assertEqual([o["name"] for o in self.app.heartbeat(hb)["outside"]], ["ok"])

    def test_down_after_two_fails_one_alert_then_recovery(self):
        self.app.heartbeat(dict(HB))
        self.ok = False
        self.app.check_all()
        self.assertEqual(self.app.public()[0]["status"], "failing")
        self.assertEqual(self.sent, [])
        self.t += 300
        self.app.check_all()
        self.assertEqual(self.app.public()[0]["status"], "down")
        self.assertEqual(self.app.public()[0]["last_error"], "connection refused")
        self.t += 300
        self.app.check_all()  # still down: no second alert
        self.assertEqual(self.sent, [["trade site is down (outside check): connection refused"]])
        self.ok = True
        self.t += 300
        self.app.check_all()
        self.assertEqual(self.sent[1], ["trade site recovered (outside check) after 15 min"])
        self.app.check_all()
        self.assertEqual(len(self.sent), 2)

    def test_one_fail_then_ok_no_alert(self):
        self.app.heartbeat(dict(HB))
        self.ok = False
        self.app.check_all()
        self.ok = True
        self.app.check_all()
        self.assertEqual(self.sent, [])

    def test_silence_and_back(self):
        self.app.heartbeat(dict(HB))
        self.t += 9 * 60
        self.app.check_silence()
        self.assertEqual(self.sent, [])
        self.t += 2 * 60
        self.app.check_silence()
        self.app.check_silence()  # only once
        self.assertEqual(len(self.sent), 1)
        self.assertTrue(self.sent[0][0].startswith("mac-mini silent since "))
        self.app.heartbeat(dict(HB))
        self.assertEqual(self.sent[1], ["mac-mini is back"])

    def test_server_outage_is_not_mac_silence(self):
        self.app.heartbeat(dict(HB))
        self.t += 30 * 60  # server was down 30 min, then restarts
        again = self.make()
        again.check_silence()
        self.assertEqual(self.sent, [])
        self.t += 11 * 60  # still no heartbeat after the restart: now it is the Mac
        again.check_silence()
        self.assertEqual(len(self.sent), 1)

    def test_bad_target_fails_alone(self):
        hb = dict(HB, outside_targets=[{"name": "bad", "url": "http://["},
                                       {"name": "good", "url": "https://example.com/"}])
        self.app.heartbeat(hb)
        self.app.fetch = (
            lambda url, expect: app.check_url(url, expect) if url == "http://[" else (True, None))
        self.app.check_all()
        st = {r["name"]: r["status"] for r in self.app.public()}
        self.assertEqual(st, {"bad": "failing", "good": "ok"})

    def test_stuck_target_times_out(self):
        self.app.heartbeat(dict(HB))
        stuck = threading.Event()
        self.app.fetch = lambda url, expect: (stuck.wait(5), None)
        self.app.check_deadline = 0.2
        t0 = time.monotonic()
        self.app.check_all()
        stuck.set()
        self.assertLess(time.monotonic() - t0, 2)
        self.assertEqual(self.app.public()[0]["status"], "failing")

    def test_no_alert_before_first_heartbeat(self):
        self.t += 10 ** 6
        self.app.check_silence()
        self.app.check_all()
        self.assertEqual(self.sent, [])

    def test_targets_kept_when_silent(self):
        self.app.heartbeat(dict(HB))
        self.t += 3600
        self.app.check_silence()
        self.assertEqual(len(self.app.state["targets"]), 1)

    def test_state_survives_restart(self):
        self.app.heartbeat(dict(HB))
        self.ok = False
        self.app.check_all()
        self.app.check_all()
        again = self.make()
        self.assertEqual(again.public()[0]["status"], "down")
        self.assertEqual(again.state["heartbeat"]["body"]["host"], "mac-mini")
        self.ok = True
        again.check_all()
        self.assertTrue(self.sent[-1][0].startswith("trade site recovered"))

    def test_changed_url_resets_to_pending(self):
        self.app.heartbeat(dict(HB))
        self.app.check_all()
        hb = dict(HB, outside_targets=[{"name": "trade site", "url": "https://other.example/"}])
        self.assertEqual(self.app.heartbeat(hb)["outside"][0]["status"], "pending")

    def test_page_escapes(self):
        self.app.heartbeat(dict(HB, host="<script>x</script>"))
        p = self.app.page()
        self.assertNotIn("<script>", p)
        self.assertIn("&lt;script&gt;", p)
        self.assertIn("api &lt;b&gt;", p)


class TestApnsFallback(Base):
    def test_apple_failure_falls_back_to_ntfy(self):
        self.app.cfg.apns = True
        calls = []
        self.app.push_apple = lambda lines: calls.append("apple") or False
        self.app.push_ntfy = lambda lines: calls.append("ntfy") or True
        self.app.send_alert(["x"])
        self.assertEqual(calls, ["apple", "ntfy"])

    def test_apple_success_skips_ntfy(self):
        self.app.cfg.apns = True
        calls = []
        self.app.push_apple = lambda lines: calls.append("apple") or True
        self.app.push_ntfy = lambda lines: calls.append("ntfy") or True
        self.app.send_alert(["x"])
        self.assertEqual(calls, ["apple"])


class TestHTTP(Base):
    def setUp(self):
        super().setUp()
        self.srv = app.serve(self.app, 0)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.addCleanup(self.srv.server_close)
        self.addCleanup(self.srv.shutdown)
        self.base = f"http://127.0.0.1:{self.srv.server_address[1]}"

    def req(self, path, data=None, headers=None):
        class Keep(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *a):
                return None
        r = urllib.request.Request(self.base + path, data=data, headers=headers or {})
        try:
            with urllib.request.build_opener(Keep).open(r, timeout=5) as resp:
                return resp.status, resp.read().decode(), resp.headers
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode(), e.headers

    def test_healthz(self):
        self.assertEqual(self.req("/healthz")[:2], (200, "ok\n"))

    def test_bearer(self):
        body = json.dumps(HB).encode()
        self.assertEqual(self.req("/api/heartbeat", body)[0], 401)
        self.assertEqual(self.req("/api/heartbeat", body, {"Authorization": "Bearer nope"})[0], 401)
        code, text, _ = self.req("/api/heartbeat", body, {"Authorization": "Bearer " + TOKEN})
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(text)["outside"][0]["status"], "pending")
        self.assertEqual(self.req("/api/state")[0], 401)
        code, text, _ = self.req("/api/state", headers={"Authorization": "Bearer " + TOKEN})
        self.assertEqual(json.loads(text)["heartbeat"]["body"]["host"], "mac-mini")

    def test_bad_body(self):
        auth = {"Authorization": "Bearer " + TOKEN}
        self.assertEqual(self.req("/api/heartbeat", b"[1]", auth)[0], 400)
        self.assertEqual(self.req("/api/heartbeat", b"{", auth)[0], 400)

    def test_body_limit(self):
        auth = {"Authorization": "Bearer " + TOKEN}
        big = json.dumps({"pad": "x" * (app.MAX_BODY + 1)}).encode()
        try:
            code = self.req("/api/heartbeat", big, auth)[0]
        except (ConnectionError, urllib.error.URLError):
            code = 413  # server closed early while we were still sending
        self.assertEqual(code, 413)

    def test_cookie_flow(self):
        self.assertEqual(self.req("/")[0], 401)
        self.assertEqual(self.req("/?k=wrong")[0], 401)
        code, _, h = self.req("/?k=" + TOKEN)
        self.assertEqual(code, 303)
        self.assertEqual(h["Location"], "/")
        cookie = h["Set-Cookie"]
        self.assertIn("HttpOnly", cookie)
        self.assertIn("SameSite=Strict", cookie)
        code, page, _ = self.req("/", headers={"Cookie": cookie.split(";")[0]})
        self.assertEqual(code, 200)
        self.assertIn("No heartbeat from the Mac yet", page)
        self.assertEqual(self.req("/", headers={"Cookie": "nk=wrong"})[0], 401)


class TestSignature(unittest.TestCase):
    def test_der_to_raw(self):
        r, s = b"\x80" + b"\x11" * 31, b"\x05" * 30  # r needs a 0x00 pad, s is short
        der = bytes([0x30, 2 + 33 + 2 + 30, 0x02, 33]) + b"\0" + r + bytes([0x02, 30]) + s
        self.assertEqual(app.der_to_raw(der), r + b"\0\0" + s)

    def test_der_rejects_junk(self):
        with self.assertRaises(ValueError):
            app.der_to_raw(b"\x31\x00")

    @unittest.skipUnless(shutil.which("openssl"), "openssl not installed")
    def test_jwt_verifies_with_openssl(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        run = lambda *a: subprocess.run(a, check=True, capture_output=True, cwd=d)
        run("openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "ec.pem")
        run("openssl", "pkcs8", "-topk8", "-nocrypt", "-in", "ec.pem", "-out", "AuthKey_ABC.p8")
        run("openssl", "ec", "-in", "ec.pem", "-pubout", "-out", "pub.pem")
        jwt = app.make_jwt(os.path.join(d, "AuthKey_ABC.p8"), "ABC", "TEAM", 1_800_000_000)
        head, claims, sig = jwt.split(".")
        pad = lambda x: x + "=" * (-len(x) % 4)
        self.assertEqual(json.loads(app.base64.urlsafe_b64decode(pad(head))), {"alg": "ES256", "kid": "ABC"})
        raw = app.base64.urlsafe_b64decode(pad(sig))
        self.assertEqual(len(raw), 64)

        def der_int(b):
            b = b.lstrip(b"\0") or b"\0"
            b = b"\0" + b if b[0] & 0x80 else b
            return bytes([0x02, len(b)]) + b
        body = der_int(raw[:32]) + der_int(raw[32:])
        with open(os.path.join(d, "sig.der"), "wb") as f:
            f.write(bytes([0x30, len(body)]) + body)
        with open(os.path.join(d, "input"), "w") as f:
            f.write(f"{head}.{claims}")
        out = run("openssl", "dgst", "-sha256", "-verify", "pub.pem", "-signature", "sig.der", "input")
        self.assertIn(b"Verified OK", out.stdout)


class TestCheckUrl(unittest.TestCase):
    def test_redirect_not_followed_and_expect(self):
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                self.send_response(302 if self.path == "/r" else 200)
                self.send_header("Location", "/")
                self.send_header("Content-Length", "0")
                self.end_headers()
        srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        base = f"http://127.0.0.1:{srv.server_address[1]}"
        self.assertEqual(app.check_url(base + "/r", []), (True, None))  # 302 within 200-399
        self.assertEqual(app.check_url(base + "/r", [200]), (False, "HTTP 302"))
        self.assertEqual(app.check_url(base + "/", [200]), (True, None))
        ok, err = app.check_url("http://127.0.0.1:9/", [], timeout=2)
        self.assertFalse(ok)
        self.assertTrue(err)


if __name__ == "__main__":
    unittest.main()
