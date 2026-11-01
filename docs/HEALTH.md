# Health watches (for agents)

Nodlock checks the watches in `~/.config/op-guard/watches.json` every `interval`
seconds (default 60, min 15) and writes the result to
`~/.local/state/nodlock/health.json` after every cycle.

## Read it

```bash
nodlockctl health          # one summary line, then one line per watch
nodlockctl health --json   # the raw health.json
```

Each watch line reads `status  name  last_error  age  fix: <cmd>`. The age is how
long the watch has had its current status. Lines are sorted down, failing, error, ok.
The panel (`GET /health`) and the menu bar's Health submenu show the same data.

## Fields (health.json)

- `generated_at`: end of the last cycle. Older than 2 x `interval_s` + 30 s means Nodlock is stuck or not running (unless a check's timeout is longer than that; a cycle waits for every check). `nodlockctl health` prints `STALE:` in that case.
- `config_error`: `"no watches.json"` (feature off), or the parse error. On a parse error the last good config stays live.
- `summary`: counts per status.
- `watches[]`: `name`, `type`, `target`, `status`, `since` (when this status started), `last_ok`, `last_error`, `consecutive_failures`, `recoveries_today` (down to ok, resets at local midnight), `fix`, `hint`, `outside`.
- `server`: the optional status server (`url`, `last_heartbeat_ok`, `error`), or null.
- `outside_checks[]`: what the status server sees from the tailnet, for URL watches with `"outside": true`.
- `last_fix`: `name`, `at`, `exit`, `output_tail` of the last Fix run.

## Statuses and what to do

- `ok`: the last check passed. Nothing to do.
- `failing`: one failed check. Wait a cycle; it is often a blip.
- `down`: two or more failures in a row (a push went out). Read `hint`, then `last_error`. If `fix` is set, the user can press Fix in the panel or menu; you can run the same command yourself. After any fix, wait one cycle and re-read.
- `error`: the watch itself is wrong (`unknown type`, `bad url`, `bad port`, `bad tmux target`). Fix watches.json.
- An outside check is down but the local watch is ok: the service works on the Mac, the path from the phone does not (DNS, a stray `tailscale serve` on 443, the proxy).

## Add a watch

Edit `~/.config/op-guard/watches.json`. Nodlock reloads it when the file changes.
The file is one object with an optional `interval` (seconds, default 60) and a `watches` array:

```json
{"interval": 60, "watches": [
  {"name": "api", "type": "url", "target": "http://127.0.0.1:8000/health",
   "expect": [200], "timeout": 5, "fix": "launchctl kickstart -k gui/$(id -u)/com.me.api",
   "hint": "FastAPI under launchd. Logs in /tmp/api.log."}
]}
```

| type | OK when |
|---|---|
| `url` | GET returns a status in `expect` (default 200-399). Redirects are not followed. |
| `port` | TCP connect to `127.0.0.1:<target>` works. |
| `process` | `pgrep -x <target>` finds it. |
| `launchd` | `launchctl print gui/<uid>/<target>` works and the last exit code is 0. |
| `tmux` | `session:window` exists (bare `session` = the session exists). |
| `tailscale_serve` | Nothing is served on port `<target>`. |
| `command` | `/bin/sh -c <target>` exits 0 (default timeout 10 s). |

`name` must be unique. Always write a `hint`: it is the first thing the next agent reads.
A `fix` that starts a background process must redirect its output (`>/dev/null 2>&1 &`); prefer `launchctl kickstart` or `tmux`.
