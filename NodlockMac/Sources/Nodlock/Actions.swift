import Foundation

// Named actions this Mac publishes to the phone. `vpnArg` is what we hand to
// ~/.local/bin/vpn; the phone only ever sees `id` and `label`.
struct MacAction {
    let id: String
    let label: String
    let vpnArg: String
}

// ponytail: hardcoded pair; the vpn script only knows these two.
let ACTIONS: [MacAction] = [
    MacAction(id: "tailscale",  label: "Tailscale",       vpnArg: "ts"),
    MacAction(id: "cloudflare", label: "Cloudflare WARP", vpnArg: "cf"),
]

// `tailscale status` exits non-zero when the client is stopped or logged out.
func tailscaleUp() -> Bool {
    guard let ts = Shell.tailscale else { return false }
    let (code, _) = Shell.run(ts, ["status"])
    return code == 0
}

// `warp-cli status` prints "Status update: Connected" / "Status update: Disconnected".
// Check "Disconnected" first: "Connected" is a substring of it, so a loose match
// would report the opposite. Case-sensitive on purpose.
func warpConnected() -> Bool {
    guard let warp = Shell.warpCli else { return false }
    let (_, out) = Shell.run(warp, ["status"])
    if out.contains("Disconnected") { return false }
    return out.contains("Connected")
}

// Probes both tools. Empty when the switch script is missing, so Macs without it
// publish no actions and the phone shows no card.
func probeActions() -> [[String: Any]] {
    guard Shell.vpn != nil else { return [] }
    let tsUp = tailscaleUp()
    let warpUp = warpConnected()
    return ACTIONS.map { a in
        ["id": a.id, "label": a.label, "active": a.id == "tailscale" ? tsUp : warpUp]
    }
}
