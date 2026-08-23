#!/usr/bin/env python3
"""sentinel: remote hands for macOS security dialogs.

Watches for security prompt windows (1Password unlock, SecurityAgent,
keychain dialogs). When one appears: screenshots JUST that window and
pushes it to your phone via ntfy. Tapping opens a tailnet-only web panel:
  - live screenshot of the dialog; tap the image to click that spot
  - password field (iOS 1Password autofill + Face ID) typed into the dialog
  - Enter / Esc / Tab buttons
Nothing is stored on the Mac; input arrives over your tailnet per action.

Env:
  OPG_TOPIC      ntfy topic for pushes (required, share with op-guard)
  OPG_NTFY       ntfy server (default https://ntfy.sh)
  SENTINEL_URL   public-to-you panel URL, e.g. https://mini.tailXXXX.ts.net
  SENTINEL_PORT  local port (default 8377)

Expose with: tailscale serve --bg 8377   (HTTPS, tailnet-only)
Permissions (grant once, at the keyboard, to the terminal/launchd python):
  Screen Recording (screenshots) + Accessibility (clicks/keystrokes)

ponytail: polling + single-dialog state; event-driven AX observers if
polling ever misses a fast dialog.
"""
import html, json, os, subprocess, tempfile, threading, time, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import Quartz

NTFY = os.environ.get("OPG_NTFY", "https://ntfy.sh")
TOPIC = os.environ.get("OPG_TOPIC", "")
PANEL_URL = os.environ.get("SENTINEL_URL", "")
PORT = int(os.environ.get("SENTINEL_PORT", "8377"))
BIND = os.environ.get("SENTINEL_BIND", "127.0.0.1")  # 0.0.0.0 = LAN test only
POLL = 3
WATCH = {"1Password", "SecurityAgent", "CoreServicesUIAgent",
         "UserNotificationCenter", "LocalAuthenticationRemoteService"}
KEYCODES = {"return": 36, "esc": 53, "tab": 48}

state = {"dialog": None, "started": None, "pushes": 0}
alerted = set()                # window ids already pushed

# ---------- window watching ----------

def find_dialog():
    opts = (Quartz.kCGWindowListOptionOnScreenOnly
            | Quartz.kCGWindowListExcludeDesktopElements)
    for w in Quartz.CGWindowListCopyWindowInfo(opts, Quartz.kCGNullWindowID) or []:
        owner = w.get("kCGWindowOwnerName", "")
        if owner not in WATCH:
            continue
        b = w.get("kCGWindowBounds", {})
        if b.get("Width", 0) < 120 or b.get("Height", 0) < 60:
            continue  # menu bar item / status droppings
        return {"id": int(w["kCGWindowNumber"]), "owner": owner,
                "title": w.get("kCGWindowName", "") or "",
                "bounds": {k: float(b[k]) for k in ("X", "Y", "Width", "Height")}}
    return None

def capture(win_id):
    path = os.path.join(tempfile.gettempdir(), "sentinel-shot.png")
    r = subprocess.run(["screencapture", "-x", "-o", "-l", str(win_id), path],
                       capture_output=True)
    return path if r.returncode == 0 and os.path.getsize(path) > 0 else None

def notify(dialog, shot):
    if not TOPIC:
        return
    try:
        headers = {
            "Title": f"{dialog['owner']} prompt on {os.uname().nodename.split('.')[0]}",
            "Priority": "high", "Tags": "rotating_light",
            "X-Filename": "dialog.png",
        }
        if PANEL_URL:
            headers["Actions"] = f"view, Open panel, {PANEL_URL}, clear=true"
        with open(shot, "rb") as f:
            req = urllib.request.Request(f"{NTFY}/{TOPIC}", data=f.read(),
                                         headers=headers, method="PUT")
            urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        print(f"sentinel: ntfy push failed: {e}")

def watcher():
    while True:
        d = find_dialog()
        state["dialog"] = d
        if d and d["id"] not in alerted:
            shot = capture(d["id"])
            if shot:
                alerted.add(d["id"])
                state["pushes"] += 1
                print(f"sentinel: dialog {d['owner']} ({d['id']}) -> pushed")
                notify(d, shot)
        time.sleep(POLL)

# ---------- acting on the dialog ----------

def click_at(x, y):
    for t in (Quartz.kCGEventLeftMouseDown, Quartz.kCGEventLeftMouseUp):
        ev = Quartz.CGEventCreateMouseEvent(None, t, (x, y),
                                            Quartz.kCGMouseButtonLeft)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)
        time.sleep(0.05)

def type_text(s):
    # json.dumps gives AppleScript-compatible quoting for typical passwords
    subprocess.run(["osascript", "-e",
                    'tell application "System Events" to keystroke ' + json.dumps(s)])

def press(name):
    subprocess.run(["osascript", "-e",
                    f'tell application "System Events" to key code {KEYCODES[name]}'])

# ---------- web panel ----------

PAGE = r"""<!doctype html><html lang=en><head>
<meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name=theme-color content="#0b0d12"><title>Sentinel</title>
<style>
:root{--bg:#0b0d12;--card:rgba(255,255,255,.06);--line:rgba(255,255,255,.12);
--txt:#eef1f6;--dim:#9aa4b2;--accent:#4c8dff;--ok:#2fd27a;--warn:#ffb020;--danger:#ff5c6c}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
body{margin:0;font:16px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;
color:var(--txt);background:
radial-gradient(1200px 600px at 20% -10%,rgba(76,141,255,.18),transparent 60%),
radial-gradient(900px 500px at 100% 0%,rgba(47,210,122,.10),transparent 55%),var(--bg);
min-height:100dvh;padding:max(16px,env(safe-area-inset-top)) 16px calc(16px + env(safe-area-inset-bottom))}
.wrap{max-width:520px;margin:0 auto}
.top{display:flex;align-items:center;gap:10px;margin-bottom:14px}
.logo{width:30px;height:30px;border-radius:8px;background:linear-gradient(135deg,var(--accent),#7b5cff);
display:grid;place-items:center;font-weight:700;box-shadow:0 6px 18px rgba(76,141,255,.4)}
h1{font-size:19px;margin:0;font-weight:650;letter-spacing:.2px}
.chip{margin-left:auto;font-size:12px;color:var(--dim);display:flex;align-items:center;gap:6px}
.dot{width:8px;height:8px;border-radius:50%;background:var(--ok);box-shadow:0 0 10px var(--ok)}
.dot.off{background:var(--danger);box-shadow:0 0 10px var(--danger)}
.card{background:var(--card);border:1px solid var(--line);border-radius:18px;padding:14px;
backdrop-filter:blur(20px);-webkit-backdrop-filter:blur(20px);box-shadow:0 10px 40px rgba(0,0,0,.45)}
.owner{font-size:13px;color:var(--dim);margin:2px 2px 12px}
.shotwrap{position:relative;border-radius:14px;overflow:hidden;border:1px solid var(--line);
background:#05070c;min-height:120px;display:grid;place-items:center}
.shotwrap img{width:100%;display:block}
.empty{color:var(--dim);font-size:14px;padding:40px 12px;text-align:center}
.ping{position:absolute;width:44px;height:44px;margin:-22px 0 0 -22px;border-radius:50%;
border:2px solid var(--accent);animation:ping .6s ease-out forwards;pointer-events:none}
@keyframes ping{from{transform:scale(.3);opacity:.9}to{transform:scale(1.2);opacity:0}}
.field{margin-top:14px;display:flex;gap:8px}
input[type=password]{flex:1;font-size:17px;padding:14px 16px;border-radius:14px;
border:1px solid var(--line);background:rgba(0,0,0,.35);color:var(--txt);outline:none}
input[type=password]:focus{border-color:var(--accent);box-shadow:0 0 0 3px rgba(76,141,255,.25)}
.btn{border:none;border-radius:14px;padding:14px 18px;font-size:16px;font-weight:600;color:#fff;
background:linear-gradient(135deg,var(--accent),#3b7bff);cursor:pointer;transition:transform .08s,filter .15s}
.btn:active{transform:scale(.96)}.btn.ghost{background:rgba(255,255,255,.08);color:var(--txt);border:1px solid var(--line)}
.row{display:flex;gap:8px;margin-top:10px}.row .btn{flex:1;padding:12px}
.opt{display:flex;align-items:center;gap:8px;margin-top:10px;color:var(--dim);font-size:14px}
.toggle{position:relative;width:44px;height:26px;border-radius:20px;background:rgba(255,255,255,.15);
transition:background .2s;cursor:pointer;flex:none}.toggle.on{background:var(--accent)}
.toggle::after{content:"";position:absolute;top:3px;left:3px;width:20px;height:20px;border-radius:50%;
background:#fff;transition:transform .2s}.toggle.on::after{transform:translateX(18px)}
.foot{margin-top:16px;text-align:center;color:var(--dim);font-size:12px}
.toast{position:fixed;left:50%;bottom:24px;transform:translateX(-50%) translateY(20px);opacity:0;
background:rgba(20,24,32,.95);border:1px solid var(--line);padding:10px 16px;border-radius:12px;
transition:.25s;pointer-events:none}.toast.show{opacity:1;transform:translateX(-50%) translateY(0)}
</style></head><body><div class=wrap>
<div class=top><div class=logo>S</div><h1>Sentinel</h1>
<div class=chip><span class=dot id=dot></span><span id=stat>connecting</span></div></div>
<div class=card>
<div class=owner id=owner>Looking for a security prompt...</div>
<div class=shotwrap id=sw><div class=empty id=empty>No dialog on screen</div>
<img id=shot alt="" style="display:none" onclick="clickAt(event)"></div>
<div class=field>
<input id=pw type=password autocomplete=current-password placeholder="Password (Face ID / 1Password)">
<button class=btn onclick=doType()>Unlock</button></div>
<div class=opt><span>Press Return after typing</span>
<div class="toggle on" id=tg onclick="this.classList.toggle('on')"></div></div>
<div class=row><button class="btn ghost" onclick=key('return')>Return</button>
<button class="btn ghost" onclick=key('esc')>Esc</button>
<button class="btn ghost" onclick=key('tab')>Tab</button></div>
</div>
<div class=foot id=foot>tailnet-only - nothing is stored</div></div>
<div class=toast id=toast></div>
<script>
const $=s=>document.querySelector(s);
function toast(m){const t=$('#toast');t.textContent=m;t.classList.add('show');
setTimeout(()=>t.classList.remove('show'),1600)}
async function post(u,b){const r=await fetch(u,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:b});return r}
function doType(){const pw=$('#pw').value;if(!pw)return toast('Enter a password');
const en=$('#tg').classList.contains('on')?'&enter=on':'';
post('/type','text='+encodeURIComponent(pw)+en);$('#pw').value='';toast('Sent to Mac')}
function key(k){post('/key','k='+k);toast(k)}
function clickAt(e){const i=$('#shot');const r=i.getBoundingClientRect();
const fx=(e.clientX-r.left)/r.width,fy=(e.clientY-r.top)/r.height;
post('/click','fx='+fx+'&fy='+fy);
const p=document.createElement('div');p.className='ping';p.style.left=(e.clientX-r.left)+'px';
p.style.top=(e.clientY-r.top)+'px';$('#sw').appendChild(p);setTimeout(()=>p.remove(),600);toast('Clicked')}
async function tick(){try{const s=await(await fetch('/status')).json();
$('#dot').classList.toggle('off',!s.ok);
$('#stat').textContent=s.dialog?'prompt active':'idle - '+Math.floor(s.uptime_s/60)+'m up';
if(s.dialog){$('#owner').textContent=s.dialog+' is asking';$('#shot').style.display='';
$('#empty').style.display='none';$('#shot').src='/shot.png?t='+Date.now();}
else{$('#owner').textContent='No security prompt right now';
$('#shot').style.display='none';$('#empty').style.display='';}
}catch(e){$('#dot').classList.add('off');$('#stat').textContent='offline'}}
tick();setInterval(tick,2000);
</script></body></html>"""

class H(BaseHTTPRequestHandler):
    def _ok(self, body, ctype="text/html"):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.end_headers()
        self.wfile.write(body if isinstance(body, bytes) else body.encode())

    def _back(self):
        self.send_response(303); self.send_header("Location", "/"); self.end_headers()

    def do_GET(self):
        d = state["dialog"]
        if self.path.startswith("/status"):
            up = int(time.time()) - (state["started"] or int(time.time()))
            self._ok(json.dumps({"ok": True, "uptime_s": up,
                     "pushes": state["pushes"], "topic_set": bool(TOPIC),
                     "panel_url": PANEL_URL or None,
                     "dialog": (d["owner"] if d else None)}), "application/json")
            return
        if self.path.startswith("/shot.png"):
            shot = capture(d["id"]) if d else None
            if shot:
                with open(shot, "rb") as f: self._ok(f.read(), "image/png")
            else:
                self.send_response(404); self.end_headers()
            return
        self._ok(PAGE)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        form = urllib.parse.parse_qs(self.rfile.read(n).decode())
        get = lambda k: form.get(k, [""])[0]
        d = state["dialog"]
        if self.path == "/click" and d:
            b = d["bounds"]
            click_at(b["X"] + float(get("fx")) * b["Width"],
                     b["Y"] + float(get("fy")) * b["Height"])
        elif self.path == "/type" and get("text"):
            # No click, no activation: security modals already own key focus,
            # and synthetic focus changes steal it. Just type.
            type_text(get("text"))
            if get("enter"): time.sleep(0.1); press("return")
        elif self.path == "/key" and get("k") in KEYCODES:
            press(get("k"))
        time.sleep(0.4)  # let the UI settle before the redirect re-screenshots
        self._back()

    def log_message(self, *a): pass

if __name__ == "__main__":
    state["started"] = int(time.time())
    threading.Thread(target=watcher, daemon=True).start()
    print(f"sentinel: panel on http://127.0.0.1:{PORT} (expose: tailscale serve --bg {PORT})")
    ThreadingHTTPServer((BIND, PORT), H).serve_forever()
