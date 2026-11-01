#!/usr/bin/env python3
"""Nodlock status server: checks your URLs from inside the tailnet, takes
heartbeats from the Nodlock Mac app, and alerts (ntfy or Apple push) when a URL
goes down or the Mac goes silent. Python stdlib only. Config: env vars, see
.env.example and README.md."""
import base64
import hmac
import html
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import types
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, wait
from datetime import datetime
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

MAX_BODY = 256 * 1024
PUBLIC = ("name", "url", "status", "checked_at", "last_ok", "last_error")
HEX = re.compile(r"[0-9a-fA-F]{16,200}")
BUNDLE = re.compile(r"[A-Za-z0-9.\-]{1,200}")
COOKIE = "nk"


def log(msg):
    print("nodlock-server: " + msg, file=sys.stderr, flush=True)


def iso(ts):
    return datetime.fromtimestamp(ts).astimezone().isoformat(timespec="seconds")


def epoch(s):
    return datetime.fromisoformat(s).timestamp()


def ago(seconds):
    m = int(seconds // 60)
    if m < 1:
        return "less than a minute"
    return f"{m} min" if m < 60 else f"{m // 60} h {m % 60} min"


def load_config(env):
    key_id, team_id = env.get("OPG_APNS_KEY_ID", ""), env.get("OPG_APNS_TEAM_ID", "")
    secrets = env.get("SECRETS_DIR") or "/secrets"
    c = types.SimpleNamespace(
        token=env.get("NODLOCK_TOKEN", ""),
        interval=max(30, int(env.get("CHECK_INTERVAL") or 300)),
        silence=max(2, int(env.get("SILENCE_MINUTES") or 10)) * 60,
        ntfy_url=(env.get("NTFY_URL") or "https://ntfy.sh").rstrip("/"),
        ntfy_topic=env.get("NTFY_TOPIC", ""),
        ntfy_token=env.get("NTFY_TOKEN", ""),
        key_id=key_id,
        team_id=team_id,
        key_path=os.path.join(secrets, f"AuthKey_{key_id}.p8"),
        data_dir=env.get("DATA_DIR") or "/data",
        port=int(env.get("PORT") or 8080),
    )
    c.apns = bool(key_id and team_id and os.access(c.key_path, os.R_OK))
    if len(c.token) < 24:
        raise SystemExit("nodlock-server: NODLOCK_TOKEN must be at least 24 characters. "
                         "Make one with: openssl rand -hex 16")
    if not c.ntfy_topic and not c.apns:
        raise SystemExit("nodlock-server: set NTFY_TOPIC (or configure Apple push: "
                         f"OPG_APNS_KEY_ID, OPG_APNS_TEAM_ID and {c.key_path}).")
    return c


# ---------- URL check ----------

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None  # a 3xx then surfaces as HTTPError with its own code


OPENER = urllib.request.build_opener(NoRedirect)


def check_url(url, expect, timeout=10):
    """GET once, no redirects. Returns (ok, error_text)."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "nodlock-server/1"})
        with OPENER.open(req, timeout=timeout) as r:
            code = r.status
    except urllib.error.HTTPError as e:
        code = e.code
    except urllib.error.URLError as e:
        return False, str(e.reason)[:200]  # TLS, DNS, refused
    except Exception as e:  # timeouts, resets
        return False, (str(e) or type(e).__name__)[:200]
    ok = code in expect if expect else 200 <= code <= 399
    return ok, None if ok else f"HTTP {code}"


# ---------- Apple push (ES256 JWT via openssl, HTTP/2 via curl) ----------

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der, n=32):
    """ECDSA DER SEQUENCE{INTEGER r, INTEGER s} -> raw r||s (JWT ES256 form)."""
    if der[0] != 0x30:
        raise ValueError("not a DER sequence")
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    out = b""
    for _ in range(2):
        if der[i] != 0x02:
            raise ValueError("expected DER integer")
        ln = der[i + 1]
        v = der[i + 2:i + 2 + ln].lstrip(b"\0")
        if len(v) > n:
            raise ValueError("integer too long")
        out += v.rjust(n, b"\0")
        i += 2 + ln
    return out


def make_jwt(key_path, key_id, team_id, now):
    head = b64url(json.dumps({"alg": "ES256", "kid": key_id}, separators=(",", ":")).encode())
    claims = b64url(json.dumps({"iss": team_id, "iat": int(now)}, separators=(",", ":")).encode())
    signing_input = f"{head}.{claims}"
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                         input=signing_input.encode(), capture_output=True,
                         check=True, timeout=10).stdout
    return f"{signing_input}.{b64url(der_to_raw(der))}"


def apns_post(jwt, host, device, bundle, payload):
    """Returns (http_status, reason_body). Same headers as the Mac's APNs.swift."""
    # ponytail: the JWT rides curl's argv; only this container can see it.
    r = subprocess.run(
        ["curl", "-sS", "--http2", "--max-time", "10", "-o", "-", "-w", "\n%{http_code}",
         "-H", f"authorization: bearer {jwt}", "-H", f"apns-topic: {bundle}",
         "-H", "apns-push-type: alert", "-H", "apns-priority: 10",
         "-H", "apns-expiration: 0", "--data-binary", "@-",
         f"https://{host}/3/device/{device}"],
        input=json.dumps(payload).encode(), capture_output=True, timeout=20)
    body, _, code = r.stdout.decode(errors="replace").rpartition("\n")
    return code.strip(), (body or r.stderr.decode(errors="replace")).strip()[:300]


# ---------- state + logic ----------

class App:
    def __init__(self, cfg):
        self.cfg = cfg
        self.path = os.path.join(cfg.data_dir, "state.json")
        self.lock = threading.RLock()
        self.wake = threading.Event()
        self.clock = time.time
        self.fetch = check_url        # tests swap these three
        self.deliver = self.send_alert
        self.bg = lambda f, *a: threading.Thread(target=f, args=a, daemon=True).start()
        self.jwt = (None, 0.0)
        self.check_deadline = 30  # seconds for one whole check round
        self.state = self.load()
        self.started = self.clock()  # a server outage must not read as Mac silence

    def load(self):
        try:
            with open(self.path) as f:
                return json.load(f)
        except FileNotFoundError:
            pass
        except ValueError as e:
            log(f"state.json unreadable ({e}); starting empty")
        return {"heartbeat": None, "targets": [], "results": {}, "silent": False}

    def save(self):
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.state, f, indent=1)
        os.replace(tmp, self.path)

    def token_ok(self, s):
        return bool(s) and hmac.compare_digest(s.encode(), self.cfg.token.encode())

    def host(self):
        hb = self.state["heartbeat"]
        return str((hb or {}).get("body", {}).get("host") or "Mac")[:100]

    def public(self):
        res = self.state["results"]
        return [{k: res[t["name"]].get(k) for k in PUBLIC}
                for t in self.state["targets"] if t["name"] in res]

    def heartbeat(self, body):
        now, targets = self.clock(), []
        for t in body.get("outside_targets") or []:
            if not isinstance(t, dict):
                continue
            name, url = t.get("name"), t.get("url")
            if isinstance(name, str) and name and isinstance(url, str) and re.match(r"https?://", url):
                expect = t.get("expect") if isinstance(t.get("expect"), list) else []
                expect = [c for c in expect if type(c) is int]
                targets.append({"name": name[:200], "url": url, "expect": expect})
        lines, fresh = [], False
        with self.lock:
            st = self.state
            st["heartbeat"] = {"at": iso(now), "body": body}
            if st["silent"]:
                st["silent"] = False
                lines.append(f"{self.host()} is back")
            old, new = st["results"], {}
            for t in targets:
                r = old.get(t["name"])
                if not r or r["url"] != t["url"] or r.get("expect") != t["expect"]:
                    r = {"name": t["name"], "url": t["url"], "expect": t["expect"],
                         "status": "pending", "checked_at": None, "last_ok": None,
                         "last_error": None, "fails": 0, "failing_since": None}
                    fresh = True
                new[t["name"]] = r
            st["targets"], st["results"] = targets, new
            self.save()
            out = self.public()
        if fresh:
            self.wake.set()  # check new targets now, not in CHECK_INTERVAL
        if lines:
            self.bg(self.alert, lines)
        return {"ok": True, "outside": out}

    def check_all(self):
        with self.lock:
            targets = list(self.state["targets"])
        if not targets:
            return
        def one(t):  # a bad target fails alone, never the whole batch
            try:
                return self.fetch(t["url"], t["expect"])
            except Exception as e:
                return False, (str(e) or type(e).__name__)[:200]
        # Wall-clock cap: a target that trickles bytes defeats urllib's idle timeout.
        # ponytail: a stuck worker thread lingers until its socket dies; fine at 5-min cadence.
        ex = ThreadPoolExecutor(8)
        futs = [ex.submit(one, t) for t in targets]
        wait(futs, timeout=self.check_deadline)
        ex.shutdown(wait=False)
        outcomes = [f.result() if f.done() else (False, f"timeout (no full reply in {self.check_deadline}s)") for f in futs]
        now, lines = self.clock(), []
        with self.lock:
            for t, (ok, err) in zip(targets, outcomes):
                r = self.state["results"].get(t["name"])
                if not r or r["url"] != t["url"] or r.get("expect") != t["expect"]:
                    continue  # targets changed while we were checking
                r["checked_at"] = iso(now)
                if ok:
                    if r["status"] == "down":
                        took = ago(now - epoch(r["failing_since"]))
                        lines.append(f"{t['name']} recovered (outside check) after {took}")
                    r.update(status="ok", last_ok=iso(now), last_error=None,
                             fails=0, failing_since=None)
                else:
                    r["fails"] += 1
                    r["last_error"] = err
                    if r["fails"] == 1:
                        r["failing_since"] = iso(now)
                    r["status"] = "down" if r["fails"] >= 2 else "failing"
                    if r["fails"] == 2:
                        lines.append(f"{t['name']} is down (outside check): {err}")
            self.save()
        if lines:
            self.alert(lines)

    def check_silence(self):
        now = self.clock()
        with self.lock:
            hb = self.state["heartbeat"]
            last = max(epoch(hb["at"]), self.started) if hb else 0
            if not hb or self.state["silent"] or now - last <= self.cfg.silence:
                return
            self.state["silent"] = True
            self.save()
            since = datetime.fromisoformat(hb["at"]).astimezone().strftime("%Y-%m-%d %H:%M %Z")
            line = f"{self.host()} silent since {since}"
        self.alert([line])

    def loop(self):
        last = 0.0
        self.wake.set()  # first check right away
        while True:
            woke = self.wake.wait(30)
            self.wake.clear()
            try:
                if woke or time.monotonic() - last >= self.cfg.interval:
                    last = time.monotonic()
                    self.check_all()
                self.check_silence()
            except Exception as e:  # keep the loop alive; the next tick retries
                log(f"loop error: {e!r}")

    # ---------- alerts ----------

    def alert(self, lines):
        log("alert: " + " | ".join(lines))
        try:
            self.deliver(lines)
        except Exception as e:
            log(f"alert send failed: {e!r}")

    def send_alert(self, lines):
        if self.cfg.apns and self.push_apple(lines):
            return
        if self.cfg.ntfy_topic:
            self.push_ntfy(lines)

    def push_ntfy(self, lines):
        bad = any(" is down" in s or " silent since " in s for s in lines)
        # ponytail: ntfy JSON publish instead of Ntfy.swift's PUT + headers, so
        # non-ASCII watch names survive (HTTP headers are latin-1 only).
        msg = {"topic": self.cfg.ntfy_topic, "title": "Nodlock", "message": "\n".join(lines),
               "priority": 4 if bad else 3, "tags": ["rotating_light" if bad else "white_check_mark"]}
        req = urllib.request.Request(self.cfg.ntfy_url, data=json.dumps(msg).encode(), method="POST",
                                     headers={"Content-Type": "application/json"})
        if self.cfg.ntfy_token:
            req.add_header("Authorization", f"Bearer {self.cfg.ntfy_token}")
        try:
            urllib.request.urlopen(req, timeout=10).close()
            return True
        except Exception as e:
            log(f"ntfy push failed: {e}")
            return False

    def provider_jwt(self):
        jwt, made = self.jwt
        if not jwt or time.time() - made > 50 * 60:  # Apple allows 60 min
            jwt = make_jwt(self.cfg.key_path, self.cfg.key_id, self.cfg.team_id, time.time())
            self.jwt = (jwt, time.time())
        return jwt

    def push_apple(self, lines):
        with self.lock:
            a = ((self.state["heartbeat"] or {}).get("body") or {}).get("apns") or {}
        devices = [d for d in a.get("devices") or [] if isinstance(d, str) and HEX.fullmatch(d)]
        bundle = a.get("bundle_id") if isinstance(a.get("bundle_id"), str) else ""
        if not devices or not BUNDLE.fullmatch(bundle):
            return False
        try:
            jwt = self.provider_jwt()
        except Exception as e:
            log(f"apns jwt failed: {e}")
            return False
        alert = {"title": lines[0]} if len(lines) == 1 else \
            {"title": f"{len(lines)} status changes",  # max 10 lines: Apple's 4 KB limit
             "body": "\n".join(lines[:10] + ([f"and {len(lines) - 10} more"] if len(lines) > 10 else []))}
        # Same shape as APNs.swift send(title:owner:).
        payload = {"aps": {"alert": alert, "sound": "default",
                           "interruption-level": "time-sensitive"}, "type": "health", "owner": "status server"}
        host = "api.push.apple.com" if str(a.get("env", "")).lower() == "production" else "api.sandbox.push.apple.com"
        sent = False
        for d in devices:
            try:
                code, reason = apns_post(jwt, host, d, bundle, payload)
                if code == "400" and "BadEnvironment" in reason:  # TestFlight vs Xcode token
                    other = "api.push.apple.com" if "sandbox" in host else "api.sandbox.push.apple.com"
                    code, reason = apns_post(jwt, other, d, bundle, payload)
            except Exception as e:
                code, reason = "error", str(e)
            if code == "200":
                sent = True
            else:
                log(f"apns {code} for {d[:8]}...: {reason}")
        return sent

    # ---------- status page ----------

    def page(self):
        e, now = html.escape, self.clock()
        with self.lock:
            st = json.loads(json.dumps(self.state))
        color = {"ok": "#2a2", "failing": "#d90", "down": "#d22"}
        dot = lambda s: f'<b style="color:{color.get(str(s), "#999")}">&#9679;</b>'
        hb = st["heartbeat"]
        if hb:
            body = hb["body"]
            head = (f"<p>{dot('down' if st['silent'] else 'ok')} <b>{e(str(body.get('host') or 'Mac'))}</b>: "
                    f"last heartbeat {e(ago(now - epoch(hb['at'])))} ago ({e(hb['at'])})</p>")
            watches = "".join(
                f"<tr><td>{dot(w.get('status'))} {e(str(w.get('name', '')))}</td>"
                f"<td>{e(str(w.get('status', '')))}</td><td>{e(str(w.get('last_error') or ''))}</td></tr>"
                for w in body.get("watches") or [] if isinstance(w, dict))
        else:
            head, watches = "<p>No heartbeat from the Mac yet.</p>", ""
        outside = "".join(
            f"<tr><td>{dot(r['status'])} {e(r['name'])}<br><small>{e(r['url'])}</small></td>"
            f"<td>{e(r['status'])}</td><td>{e(r['last_error'] or '')}"
            f"<br><small>checked {e(r['checked_at'] or 'never')}</small></td></tr>"
            for r in (st["results"][t["name"]] for t in st["targets"] if t["name"] in st["results"]))
        table = lambda rows: f"<table>{rows}</table>" if rows else "<p>None.</p>"
        return f"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="refresh" content="60">
<title>Nodlock status</title><style>body{{font:15px -apple-system,system-ui,sans-serif;margin:1em;max-width:40em}}
table{{border-collapse:collapse;width:100%}}td{{border-top:1px solid #ddd;padding:.4em .3em;vertical-align:top;
word-break:break-word}}small{{color:#777}}</style></head><body><h2>Nodlock status</h2>{head}
<h3>Outside checks (from the tailnet)</h3>{table(outside)}<h3>Mac watches</h3>{table(watches)}</body></html>"""


# ---------- HTTP ----------

class Handler(BaseHTTPRequestHandler):
    server_version = "nodlock-server"

    def log_message(self, *args):
        pass  # ponytail: no access log; it would also print ?k=<token>

    def send(self, code, body, ctype="application/json", extra=()):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def json(self, code, obj):
        self.send(code, json.dumps(obj))

    def bearer(self):
        a = self.headers.get("Authorization", "")
        return a[:7].lower() == "bearer " and self.server.app.token_ok(a[7:].strip())

    def cookie(self):
        c = SimpleCookie()
        try:
            c.load(self.headers.get("Cookie", ""))
        except Exception:
            return False
        return COOKIE in c and self.server.app.token_ok(c[COOKIE].value)

    def do_GET(self):
        app, u = self.server.app, urlparse(self.path)
        if u.path == "/healthz":
            return self.send(200, "ok\n", "text/plain")
        if u.path == "/api/state":
            if not self.bearer():
                return self.json(401, {"ok": False, "error": "unauthorized"})
            with app.lock:
                data = json.dumps(app.state)
            return self.send(200, data)
        if u.path == "/":
            k = parse_qs(u.query).get("k", [""])[0]
            if k and app.token_ok(k):  # move the token from the URL into a cookie
                return self.send(303, "", "text/plain", [
                    ("Location", "/"),
                    ("Set-Cookie", f"{COOKIE}={k}; HttpOnly; SameSite=Strict; Path=/; Max-Age=31536000")])
            if not (self.cookie() or self.bearer()):
                return self.send(401, "<p>Open this page once as /?k=&lt;your NODLOCK_TOKEN&gt;</p>",
                                 "text/html; charset=utf-8")
            return self.send(200, app.page(), "text/html; charset=utf-8")
        self.json(404, {"ok": False, "error": "not found"})

    def do_POST(self):
        if urlparse(self.path).path != "/api/heartbeat":
            return self.json(404, {"ok": False, "error": "not found"})
        if not self.bearer():
            return self.json(401, {"ok": False, "error": "unauthorized"})
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = -1
        if n > MAX_BODY or n < 0:
            self.close_connection = True
            return self.json(413, {"ok": False, "error": "body over 256 KB"})
        try:
            body = json.loads(self.rfile.read(n))
            if not isinstance(body, dict):
                raise ValueError
        except ValueError:
            return self.json(400, {"ok": False, "error": "body must be a JSON object"})
        self.json(200, self.server.app.heartbeat(body))


def iface_up(name="tailscale0"):
    return any(n == name for _, n in socket.if_nameindex())


def net_guard(up=iface_up, sleep=time.sleep, exit=os._exit, every=10):
    """Exit once the tailnet interface vanishes after it was seen. The checker shares the
    tailscale container's network namespace; when that container restarts, the checker is
    left in a dead namespace and must restart to join the new one (restart policy does it)."""
    seen = False
    while True:
        if up():
            seen = True
        elif seen:
            log("tailnet interface gone (tailscale container restarted?); exiting to rejoin")
            return exit(1)
        sleep(every)


def serve(app, port):
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    srv.app = app
    return srv


def main():
    cfg = load_config(os.environ)
    os.makedirs(cfg.data_dir, exist_ok=True)
    app = App(cfg)
    app.save()  # fail at start, not on the first heartbeat, if /data is not writable
    threading.Thread(target=app.loop, daemon=True).start()
    threading.Thread(target=net_guard, daemon=True).start()
    log(f"listening on :{cfg.port}, checks every {cfg.interval}s, silence after "
        f"{cfg.silence // 60} min, alerts via {'Apple push + ' if cfg.apns else ''}"
        f"{'ntfy' if cfg.ntfy_topic else 'no ntfy'}")
    serve(app, cfg.port).serve_forever()


if __name__ == "__main__":
    main()
