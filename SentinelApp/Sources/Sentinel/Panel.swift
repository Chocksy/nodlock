import Foundation

// PANEL_HTML: copied VERBATIM from the Python `PAGE` constant in sentinel.py.
// Do not redesign.
let PAGE = #"""
<!doctype html><html lang=en><head>
<meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name=theme-color content="#0b0d12"><title>Nodlock</title>
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
<div class=top><div class=logo>N</div><h1>Nodlock</h1>
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
</script></body></html>
"""#
