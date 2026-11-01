# Nodlock status server (optional)

A small server you run yourself. It joins your tailnet, checks your URLs the
way your phone sees them, and takes a heartbeat from Nodlock on your Mac every
minute. It tells you when:

- a URL marked `"outside": true` fails twice in a row, and when it comes back;
- your Mac stops sending heartbeats for 10 minutes, and when it is back.

Alerts go to [ntfy](https://ntfy.sh) by default, or to the Nodlock iOS app
through Apple push if you have an APNs key. A 5-minute check cycle is the
default, so alerts are not instant.

It is one Python file (stdlib only) plus a Tailscale sidecar container. No
ports are published. The server is reachable only over your tailnet, at
`http://nodlock-server:8080` (its MagicDNS name).

## Setup

You need a Docker host (any Linux box, a NAS, or Coolify), a Tailscale
account, and Nodlock running on your Mac.

### 1. Create a Tailscale auth key

Open [Settings > Keys](https://login.tailscale.com/admin/settings/keys) and
generate an auth key. Make it **reusable** and add the tag **`tag:nodlock`**.
(Add the tag to your policy first, step 2, or the tag will not be offered.)
Tagged devices do not expire, so the server stays logged in.

### 2. Allow the traffic in your tailnet policy

Open [Access controls](https://login.tailscale.com/admin/acls). Add who may
use the tag, then allow the server to reach your Mac, and your devices to reach
the server. Replace `100.101.102.103` with your Mac's Tailscale IP and
`you@example.com` with your login.

```json
{
  "tagOwners": {
    "tag:nodlock": ["autogroup:admin"]
  },
  "hosts": {
    "my-mac": "100.101.102.103"
  },
  "grants": [
    {"src": ["tag:nodlock"], "dst": ["my-mac"], "ip": ["tcp:443"]},
    {"src": ["you@example.com"], "dst": ["tag:nodlock"], "ip": ["tcp:8080"]}
  ]
}
```

Merge these keys into your existing policy, do not replace it. Add any other
port your outside URLs use to the first rule (for example `"tcp:443", "tcp:8443"`).
The second rule covers your Mac (heartbeats) and your phone (the status page).

Using the older `acls` format? The same two rules:

```json
"acls": [
  {"action": "accept", "src": ["tag:nodlock"], "dst": ["my-mac:443"]},
  {"action": "accept", "src": ["you@example.com"], "dst": ["tag:nodlock:8080"]}
]
```

Still on the default allow-all policy? Then you only need the `tagOwners` block.

### 3. Pick an ntfy topic

Make up a long random topic name, for example the output of
`openssl rand -hex 12`. Anyone who knows the name can read your alerts, so do
not use a word. Install the ntfy app on your phone and subscribe to it.

Self-hosting ntfy? Set `NTFY_URL` to your server, and `NTFY_TOKEN` if it
needs one.

### 4. Deploy

Make the token Nodlock and the server share:

```bash
openssl rand -hex 16
```

You need three values: `NODLOCK_TOKEN` (that token), `TS_AUTHKEY` (step 1)
and `NTFY_TOPIC` (step 3). All settings are listed in `.env.example`.

**Plain Docker.** On the host:

```bash
git clone https://github.com/<you>/nodlock && cd nodlock/server
cp .env.example .env    # fill in the three values
docker compose up -d
docker compose logs -f checker
```

**Coolify.**

1. New Resource > Git repository (your copy of this repo).
2. Build Pack: **Docker Compose**. Base Directory: **`/server`**. Docker
   Compose Location: **`/compose.yaml`**.
3. Environment Variables: set `NODLOCK_TOKEN`, `TS_AUTHKEY`, `NTFY_TOPIC`
   (and any optional ones). Coolify reads the names from `compose.yaml`.
4. Leave Domains empty for both services. The server must not go through
   the Coolify proxy; it lives on your tailnet only.
5. Deploy.

Then check the [Machines](https://login.tailscale.com/admin/machines) page:
a machine named `nodlock-server` with the `tag:nodlock` tag should be online.
If the name is taken, Tailscale adds a suffix (`nodlock-server-1`). Use that
name in step 5.

### 5. Connect Nodlock

On the Mac: menu bar > Setup > Status server. Paste the address
(`http://nodlock-server:8080`) and the token, press **Test**, then **Save**.

Or edit `~/.config/op-guard/env` and restart Nodlock:

```
OPG_SERVER_URL=http://nodlock-server:8080
OPG_SERVER_TOKEN=<the same token>
```

### 6. Mark the URLs to check from outside

In `~/.config/op-guard/watches.json`, add `"outside": true` to each `url`
watch the server should check:

```json
{"name": "trade site", "type": "url", "target": "https://trade.example.com/", "outside": true}
```

The next heartbeat sends the list. The server checks new URLs right away, so
the first result shows in Nodlock within a minute or two.

## Status page

Open `http://nodlock-server:8080/?k=<your token>` once on your phone. The
server stores the token in a cookie and drops it from the address, so you can
bookmark plain `http://nodlock-server:8080/` after that. The page shows the
last heartbeat, what your Mac reports, and the outside checks.

## Apple push (optional)

If you already push to the Nodlock iOS app from your Mac, the server can do
the same. It uses the device tokens, bundle id and environment your Mac sends
in each heartbeat. If Apple push fails, it falls back to ntfy when a topic is set.

1. Set `OPG_APNS_KEY_ID` and `OPG_APNS_TEAM_ID` (same values as on your Mac).
2. Give the server your key file as `/secrets/AuthKey_<KEY_ID>.p8`. The
   server runs as uid 10001, so the file must be readable by it
   (`chmod 644` is fine on a host only you use).
   - **Plain Docker:** copy it into `server/secrets/`. Git ignores that folder.
   - **Coolify:** the `./secrets` folder is not in git, so the host has no
     key. Either open the checker's Persistent Storage tab and add a File
     Mount at `/secrets/AuthKey_<KEY_ID>.p8` with the key pasted in, or
     copy the file over SSH into the host folder that tab shows for
     `./secrets`. Redeploy.

The startup log line says `alerts via Apple push + ntfy` when the key is found.

## Settings

| Variable | Default | What |
| --- | --- | --- |
| `NODLOCK_TOKEN` | (required) | Shared with the Mac. At least 24 characters; use hex. |
| `TS_AUTHKEY` | (required once) | Tailscale auth key. Only used on the first start. |
| `NTFY_TOPIC` | | Required unless Apple push is set up. |
| `NTFY_URL` | `https://ntfy.sh` | Your own ntfy server, if any. |
| `NTFY_TOKEN` | | Bearer token for a private ntfy server. |
| `CHECK_INTERVAL` | `300` | Seconds between URL checks (min 30). |
| `SILENCE_MINUTES` | `10` | Minutes without a heartbeat before a "silent" alert. |
| `TZ` | `UTC` | Time zone for alert text, e.g. `Europe/Bucharest`. |
| `OPG_APNS_KEY_ID`, `OPG_APNS_TEAM_ID` | | Apple push, see above. |

State lives in `/data/state.json` (the `data` volume). Tailscale's login
lives in the `ts-state` volume.

## Routes

| Route | Auth | What |
| --- | --- | --- |
| `POST /api/heartbeat` | `Authorization: Bearer <token>` | Nodlock sends this. Returns `{"ok":true,"outside":[...]}`. |
| `GET /api/state` | Bearer | Full state as JSON. |
| `GET /` | `?k=<token>` once, then a cookie | Status page. |
| `GET /healthz` | none | `ok`, for the container health check. |

## How a check works

One `GET` per URL, 10 second timeout, redirects not followed. It passes when
the status code is in the watch's `expect` list, or 200-399 when there is no
list. A TLS error fails with the error text. Two failures in a row mean
**down** and one alert. The first pass after that is one **recovered** alert.

The URLs come only from the last heartbeat. If your Mac goes silent, the
server keeps checking the last list it got.

## Troubleshooting

- **No `nodlock-server` machine in Tailscale.** Check
  `docker compose logs tailscale`. The auth key is probably expired, used up
  (not reusable), or missing `tag:nodlock`.
- **Test in Nodlock says it cannot connect.** MagicDNS must be on for the
  Mac, and your policy must allow the Mac to reach `tag:nodlock:8080`.
- **Every outside check times out.** The policy does not let `tag:nodlock`
  reach the Mac's port.
- **The checker exits at start.** Read its log. It says which setting is
  missing: a short `NODLOCK_TOKEN`, or no `NTFY_TOPIC` and no Apple key.
- **Outside checks fail after the tailscale container restarted.** The checker
  shares its network and keeps the old, dead one. Restart the checker too.
- **Run the tests:** `cd server && python3 -m unittest -v`.
