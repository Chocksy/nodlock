import XCTest
@testable import Nodlock

// The contract sample from the ops feed brief (plus a spike and a second app).
let OPS_SAMPLE = #"""
{
  "generated_at": "2026-11-12T12:30:00Z",
  "overall": "warning",
  "headline": "Look today: Hetzner memory went under 10%",
  "alerts": [
    {"id": "s1", "severity": "spike", "title": "EpicPxls: slow responses", "started_at": "2026-11-12T12:20:00Z"},
    {"id": "abc123", "severity": "warning", "title": "Hetzner: low free memory",
     "summary": "The Hetzner server has only 8% memory free.",
     "action": "Close old Coolify PR previews.",
     "app": "Infra", "service": "", "started_at": "2026-11-12T12:10:00.250Z",
     "links": {"grafana": "https://grafana.example/alerting/x/view", "claude": "https://claude.ai/new?q=x"}},
    {"id": "z", "severity": "ok", "title": "resolved"}
  ],
  "apps": [
    {"name": "Infra", "status": "warning", "services": []},
    {"name": "Tapselo", "status": "ok", "services": [
      {"name": "Admin", "up": true, "uptime_24h": 100.0, "tier": "911"},
      {"name": "POS", "up": false, "tier": "911"}]}
  ],
  "servers": [
    {"name": "Hetzner", "ram_free_pct": 8, "ram_free_min_24h": 4, "disk_pct": 45, "disk_days_left": null,
     "swap_pct": 48, "oom_kills_24h": 2},
    {"name": "Supabase POS", "ram_free_pct": 32, "conn_pct": 43, "disk_pct": 70}
  ],
  "kiosks": {"online": 4, "total": 6, "offline": ["pos-kiosk-610a", "pos-pi-e7ec"]},
  "future_field": {"ignored": true}
}
"""#

final class OpsTests: XCTestCase {
    private func feed() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(OPS_SAMPLE.utf8)) as! [String: Any]
    }

    func testMergeAndRank() throws {
        let macDown: [String: Any] = ["name": "caddy", "status": "down", "last_error": "not running",
                                      "since": "2026-11-12T12:00:00Z"]
        let s = buildSnapshot(feed: try feed(), feedError: nil, failures: 0, watches: [macDown])
        XCTAssertEqual(s.items.map(\.id), ["abc123", "mac:caddy", "s1"]) // ok alert dropped
        XCTAssertEqual(s.overall, "warning")
        XCTAssertEqual(s.items[0].grafana, "https://grafana.example/alerting/x/view")
        XCTAssertNotNil(parseISO(s.items[0].started_at))                  // fractional seconds parsed
        XCTAssertEqual(s.apps.map(\.name), ["Tapselo", "Infra"])         // preferred order
        XCTAssertEqual(s.apps[0].detail, "1 of 2 down: POS")
        XCTAssertEqual(s.servers[0], "Hetzner  RAM 8% free (min 4% 24h) · disk 45% · swap 48% · 2 OOM kills 24h")
        XCTAssertEqual(s.servers[1], "Supabase POS  RAM 32% free · disk 70% · conn 43%")
        XCTAssertEqual(s.servers[2], "Kiosks  4/6 online · off: pos-kiosk-610a, pos-pi-e7ec")
        XCTAssertNil(s.feed_error)
    }

    func test911Wins() throws {
        var f = try feed()
        f["alerts"] = [["id": "a", "severity": "911", "title": "Tapselo down"]]
        XCTAssertEqual(buildSnapshot(feed: f, feedError: nil, failures: 0, watches: []).overall, "911")
    }

    func testUnreachableAfterThreeFailuresIsGrey() throws {
        let two = buildSnapshot(feed: nil, feedError: "timeout", failures: 2, watches: [])
        XCTAssertTrue(two.items.isEmpty)
        let three = buildSnapshot(feed: try feed(), feedError: "timeout", failures: 3, watches: [])
        let u = three.items.first { $0.id == "feed" }
        XCTAssertEqual(u?.severity, "unreachable")
        XCTAssertEqual(three.feed_error, "timeout")
        XCTAssertEqual(three.items.first?.id, "abc123")                  // warning still outranks grey
        let alone = buildSnapshot(feed: nil, feedError: "dns", failures: 5, watches: [])
        XCTAssertEqual(alone.overall, "ok")                              // grey never tints the icon
    }

    func testNotifyKeysOnlyLoudAndEscalationIsNew() {
        let w = OpsItem(id: "a", severity: "warning", title: "t")
        let spike = OpsItem(id: "b", severity: "spike", title: "t")
        XCTAssertEqual(Set(notifyKeys([w, spike]).keys), ["a|warning"])
        var esc = w; esc.severity = "911"
        XCTAssertEqual(Set(notifyKeys([esc]).keys), ["a|911"])
    }

    func testUnknownSeveritySurfaces() {
        XCTAssertEqual(normSeverity("CRITICAL"), "warning")
        XCTAssertEqual(normSeverity("911"), "911")
        XCTAssertEqual(normSeverity(nil), "ok")
        XCTAssertEqual(normSeverity("unreachable"), "warning") // the feed cannot claim our grey state
    }

    func testJSONRoundTrip() throws {
        let s = buildSnapshot(feed: try feed(), feedError: nil, failures: 0, watches: [])
        let back = try JSONDecoder().decode(OpsSnapshot.self, from: try JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }
}
