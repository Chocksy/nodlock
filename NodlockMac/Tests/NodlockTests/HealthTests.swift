import XCTest
@testable import Nodlock

// The exact example from SPEC-health.md A2.
let SPEC_EXAMPLE = #"""
{
  "interval": 60,
  "watches": [
    {"name": "trade site", "type": "url", "target": "https://trade.chocksy.com/",
     "expect": [200], "outside": true,
     "hint": "Caddy -> FastAPI :8000. If only the phone fails, check the 443 share."},
    {"name": "api", "type": "url", "target": "http://127.0.0.1:8000/health",
     "fix": "tmux kill-window -t trade-analyzer-web:api; launchctl kickstart gui/$(id -u)/com.razvan.trade-analyzer",
     "hint": "API loop in tmux. trade-analyzer-up recreates it every 5 min."},
    {"name": "vite", "type": "port", "target": "7820"},
    {"name": "caddy", "type": "process", "target": "caddy"},
    {"name": "trade-analyzer-up", "type": "launchd", "target": "com.razvan.trade-analyzer"},
    {"name": "tmux api window", "type": "tmux", "target": "trade-analyzer-web:api"},
    {"name": "no 443 share", "type": "tailscale_serve", "target": "443",
     "fix": "tailscale serve --https=443 off"},
    {"name": "external disk", "type": "command", "target": "test -d /Volumes/External/Development"}
  ]
}
"""#

final class ParseTests: XCTestCase {
    func testSpecExample() throws {
        let c = try parseWatches(Data(SPEC_EXAMPLE.utf8))
        XCTAssertEqual(c.interval, 60)
        XCTAssertEqual(c.watches.count, 8)
        let site = c.watches[0]
        XCTAssertEqual(site.expect, [200])
        XCTAssertTrue(site.outside)
        XCTAssertEqual(site.timeout, 5)
        XCTAssertNil(site.fix)
        XCTAssertEqual(c.watches[1].fix?.hasPrefix("tmux kill-window"), true)
        XCTAssertNil(c.watches[1].expect)          // default: any 200-399
        XCTAssertFalse(c.watches[1].outside)
        XCTAssertEqual(c.watches[2].target, "7820")
        XCTAssertEqual(c.watches[7].timeout, 10)   // command default
    }

    func testDefaultsAndMinInterval() throws {
        let c = try parseWatches(Data(#"{"interval": 5, "watches": [{"name":"p","type":"port","target":7820,"timeout":2}]}"#.utf8))
        XCTAssertEqual(c.interval, 15)
        XCTAssertEqual(c.watches[0].target, "7820")
        XCTAssertEqual(c.watches[0].timeout, 2)
        XCTAssertEqual(try parseWatches(Data(#"{"watches": []}"#.utf8)).interval, 60)
        let e = try parseWatches(Data(#"{"watches": [{"name":"u","type":"url","target":"http://x/","expect":[]}]}"#.utf8))
        XCTAssertNil(e.watches[0].expect) // [] = default 200-399, same as the server
    }

    func testUnknownTypeIsWatchError() throws {
        let c = try parseWatches(Data(#"{"watches": [{"name":"x","type":"ftp","target":"a"},{"name":"y","type":"command","target":"true"}]}"#.utf8))
        XCTAssertEqual(c.watches.count, 2)
        XCTAssertEqual(check(c.watches[0]), .error("unknown type"))
    }

    func testBadConfigs() {
        XCTAssertThrowsError(try parseWatches(Data("{nope".utf8)))
        XCTAssertThrowsError(try parseWatches(Data(#"{"watches": [{"name":"x","type":"url"}]}"#.utf8)))
        XCTAssertThrowsError(try parseWatches(Data(#"{"watches": [{"name":"x","type":"port","target":"1"},{"name":"x","type":"port","target":"2"}]}"#.utf8)))
    }

    func testBadJSONKeepsLastGood() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nodlock-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cfg = dir.appendingPathComponent("watches.json")
        let h = Health(configPath: cfg.path, statePath: dir.appendingPathComponent("health.json").path)

        h.reloadConfig()
        XCTAssertTrue(h.isOff)
        XCTAssertEqual(h.lastError, "no watches.json")

        try Data(SPEC_EXAMPLE.utf8).write(to: cfg)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -100)], ofItemAtPath: cfg.path)
        h.reloadConfig()
        XCTAssertFalse(h.isOff)
        XCTAssertNil(h.lastError)
        XCTAssertEqual(h.watches.count, 8)

        try Data("{ broken".utf8).write(to: cfg)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cfg.path)
        h.reloadConfig()
        XCTAssertEqual(h.watches.count, 8)
        XCTAssertTrue(h.lastError?.hasPrefix("invalid JSON") == true)

        // health.json is written atomically and carries the error.
        h.writeState()
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("health.json"))) as? [String: Any]
        XCTAssertTrue((obj?["config_error"] as? String)?.hasPrefix("invalid JSON") == true)
    }
}

final class ConfigChangeTests: XCTestCase {
    // A result for a watch whose target changed since the check began (e.g. edited during a Fix) is dropped.
    func testResultForChangedWatchDropped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nodlock-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cfg = dir.appendingPathComponent("watches.json")
        let h = Health(configPath: cfg.path, statePath: dir.appendingPathComponent("health.json").path)
        func write(_ target: String, _ age: TimeInterval) throws {
            try Data(#"{"watches":[{"name":"api","type":"url","target":"\#(target)"}]}"#.utf8).write(to: cfg)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: age)], ofItemAtPath: cfg.path)
            h.reloadConfig()
        }
        try write("http://old/", -100)
        let old = h.watches[0]
        _ = h.apply([(old, .fail("x"))]); _ = h.apply([(old, .fail("x"))])
        try write("http://new/", 0)
        let new = h.watches[0]
        XCTAssertNil(h.snapshot()["watches"].flatMap { ($0 as? [Any])?.first }, "changed check starts fresh")
        XCTAssertEqual(h.apply([(new, .fail("y"))]), [])
        XCTAssertEqual(h.apply([(old, .ok)]), [], "stale re-check of the old target is ignored")
        XCTAssertEqual(h.apply([(new, .fail("y"))]), ["api is down: y"])
    }
}

final class TransitionTests: XCTestCase {
    func testOkFailingDownOk() {
        let t0 = Date()
        var st = WatchState(since: t0)
        var pushes: [String] = []
        func step(_ r: CheckResult, _ dt: TimeInterval) -> String {
            if let m = advance(&st, name: "api", result: r, now: t0.addingTimeInterval(dt)) { pushes.append(m) }
            return st.status
        }
        XCTAssertEqual(step(.ok, 0), "ok")
        XCTAssertEqual(step(.fail("connection refused"), 60), "failing")
        XCTAssertEqual(st.failures, 1)
        XCTAssertEqual(step(.fail("connection refused"), 120), "down")
        XCTAssertEqual(step(.fail("connection refused"), 180), "down")
        XCTAssertEqual(st.failures, 3)
        XCTAssertEqual(st.since, t0.addingTimeInterval(120))
        XCTAssertEqual(pushes, ["api is down: connection refused"])
        XCTAssertEqual(step(.ok, 420), "ok")
        XCTAssertEqual(pushes.count, 2)
        XCTAssertEqual(pushes[1], "api recovered after 6m") // from the first failure
        XCTAssertEqual(st.recoveriesToday, 1)
        XCTAssertEqual(st.failures, 0)
        XCTAssertEqual(st.lastOK, t0.addingTimeInterval(420))
        XCTAssertEqual(step(.ok, 480), "ok")
        XCTAssertEqual(pushes.count, 2)
    }

    func testFailingToOkDoesNotPush() {
        var st = WatchState(since: Date())
        XCTAssertNil(advance(&st, name: "a", result: .fail("x"), now: Date()))
        XCTAssertNil(advance(&st, name: "a", result: .ok, now: Date()))
        XCTAssertEqual(st.recoveriesToday, 0)
    }

    func testRecoveriesResetAtMidnight() {
        let cal = Calendar.current
        let day1 = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 23, minute: 50))!
        var st = WatchState(since: day1)
        _ = advance(&st, name: "a", result: .fail("x"), now: day1)
        _ = advance(&st, name: "a", result: .fail("x"), now: day1.addingTimeInterval(60))
        _ = advance(&st, name: "a", result: .ok, now: day1.addingTimeInterval(120))
        XCTAssertEqual(st.recoveriesToday, 1)
        _ = advance(&st, name: "a", result: .ok, now: day1.addingTimeInterval(3600))
        XCTAssertEqual(st.recoveriesToday, 0)
    }

    func testEngineBatchesOnePushPerCycle() {
        let h = Health(configPath: "/nonexistent", statePath: "/nonexistent")
        let a = Watch(name: "a", type: "port", target: "1", expect: nil, timeout: 1, outside: false, fix: nil, hint: nil)
        let b = Watch(name: "b", type: "port", target: "2", expect: nil, timeout: 1, outside: false, fix: nil, hint: nil)
        XCTAssertEqual(h.apply([(a, .fail("x")), (b, .fail("y"))]), [])
        XCTAssertEqual(h.apply([(a, .fail("x")), (b, .fail("y"))]), ["a is down: x", "b is down: y"])
        XCTAssertEqual(h.apply([(a, .fail("x")), (b, .fail("y"))]), [])
    }

    func testDurations() {
        XCTAssertEqual(fmtDuration(45), "45s")
        XCTAssertEqual(fmtDuration(300), "5m")
        XCTAssertEqual(fmtDuration(3900), "1h 5m")
        XCTAssertEqual(fmtDuration(90000), "1d 1h")
    }
}

final class ParserTests: XCTestCase {
    func testTailscaleServe() {
        let json = #"{"TCP": {"443": {"HTTPS": true}, "8080": {"HTTP": true}}, "Web": {}}"#
        XCTAssertEqual(serveResult(code: 0, output: json, port: "443"), .fail("tailscale serve is active on port 443"))
        XCTAssertEqual(serveResult(code: 0, output: json, port: "8443"), .ok)
        XCTAssertEqual(serveResult(code: 0, output: "{}", port: "443"), .ok)
        let fg = #"{"Foreground": {"sess1": {"TCP": {"443": {"HTTPS": true}}}}}"#
        XCTAssertEqual(serveResult(code: 0, output: fg, port: "443"), .fail("tailscale serve is active on port 443"))
        XCTAssertEqual(serveResult(code: 0, output: "", port: "443"), .ok)
        XCTAssertEqual(serveResult(code: 1, output: "failed to connect to local tailscaled", port: "443"),
                       .fail("failed to connect to local tailscaled"))
    }

    func testLaunchd() {
        let ok = "gui/501/com.x = {\n\tstate = not running\n\tlast exit code = 0\n}"
        XCTAssertEqual(launchdResult(code: 0, output: ok), .ok)
        XCTAssertEqual(launchdResult(code: 0, output: "\tlast exit code = (never exited)\n"), .ok)
        XCTAssertEqual(launchdResult(code: 0, output: "\tlast exit code = 78: EX_CONFIG\n"), .fail("last exit code 78: EX_CONFIG"))
        XCTAssertEqual(launchdResult(code: 113, output: "Could not find service"), .fail("not loaded"))
    }

    func testHealthTextOff() {
        XCTAssertEqual(healthText(["config_error": "no watches.json", "config_path": "~/w.json"], now: Date()),
                       "Health: no watches.json (~/w.json)")
    }
}

final class EnvTests: XCTestCase {
    func testRewriteReplacesAppendsKeeps() {
        let old = "# comment\nexport OPG_TOPIC=abc\nOPG_SERVER_URL=http://old:8080\n\nexport OPG_APNS_ENV=sandbox\n"
        let new = Config.rewriteEnv(old, set: [("OPG_SERVER_URL", "http://nodlock-server:8080"),
                                               ("OPG_SERVER_TOKEN", "deadbeef")])
        XCTAssertEqual(new, "# comment\nexport OPG_TOPIC=abc\nexport OPG_SERVER_URL=http://nodlock-server:8080\n\n"
                            + "export OPG_APNS_ENV=sandbox\nexport OPG_SERVER_TOKEN=deadbeef\n")
        XCTAssertEqual(Config.rewriteEnv("", set: [("A", "1")]), "export A=1\n")
        // Later duplicates go, so the reader (last value wins) sees the new one.
        XCTAssertEqual(Config.rewriteEnv("A=1\nB=2\nexport A=3\n", set: [("A", "9")]), "export A=9\nB=2\n")
        // A key that is a prefix of another must not match it.
        XCTAssertEqual(Config.rewriteEnv("OPG_SERVER_URL_X=1\n", set: [("OPG_SERVER_URL", "2")]),
                       "OPG_SERVER_URL_X=1\nexport OPG_SERVER_URL=2\n")
    }

    func testShellPathAndSh() {
        let (code, out) = Shell.sh("echo $PATH; echo err >&2; exit 3", timeout: 5)
        XCTAssertEqual(code, 3)
        XCTAssertTrue(out.hasPrefix("/usr/local/bin:/opt/homebrew/bin:"))
        XCTAssertTrue(out.hasSuffix("err"))
        let (tcode, _) = Shell.sh("sleep 5", timeout: 0.3)
        XCTAssertNotEqual(tcode, 0)
    }
}

// Live checks against this Mac (skipped unless NODLOCK_LIVE_DIR is set):
//   NODLOCK_LIVE_DIR=/path/with/watches.json swift test --filter LiveTests
final class LiveTests: XCTestCase {
    func testLiveCycle() throws {
        guard let dir = ProcessInfo.processInfo.environment["NODLOCK_LIVE_DIR"] else { throw XCTSkip("set NODLOCK_LIVE_DIR") }
        let h = Health(configPath: dir + "/watches.json", statePath: dir + "/health.json")
        let t = Date()
        h.cycle()
        print("cycle took \(Date().timeIntervalSince(t))s\n" + h.summaryText())
    }
}

final class ShellTests: XCTestCase {
    // A child that ignores SIGTERM must still end at the timeout and never count as exit 0.
    func testTimeoutKillsChildThatIgnoresTerm() {
        let t0 = Date()
        let (code, _) = Shell.sh("trap '' TERM; sleep 8; echo late", timeout: 1)
        XCTAssertEqual(code, 124)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)
    }
}

final class CheckTests: XCTestCase {
    private func w(_ type: String, _ target: String) -> Watch {
        Watch(name: "w", type: type, target: target, expect: nil, timeout: 1, outside: false, fix: nil, hint: nil)
    }

    func testBadTmuxTargetsAreConfigErrors() {
        for t in [":", ":win", "sess:"] { XCTAssertEqual(check(w("tmux", t)), .error("bad tmux target"), t) }
    }

    func testClosedPortFails() {
        guard case .fail = check(w("port", "1")) else { return XCTFail("port 1 should not be open") }
    }

    // A failure from a cycle that started before a newer pass (fix re-check) is dropped.
    func testStaleFailureDropped() {
        let h = Health(configPath: "/nonexistent", statePath: "/nonexistent")
        let a = w("port", "1")
        let t0 = Date()
        _ = h.apply([(a, .ok)], now: t0.addingTimeInterval(2))
        _ = h.apply([(a, .fail("old"))], now: t0.addingTimeInterval(3), startedAt: t0) // stale: dropped
        // Had the stale failure counted, this second failure would push "down".
        XCTAssertEqual(h.apply([(a, .fail("new"))], now: t0.addingTimeInterval(5), startedAt: t0.addingTimeInterval(4)), [])
        XCTAssertEqual(h.apply([(a, .fail("new"))], now: t0.addingTimeInterval(7), startedAt: t0.addingTimeInterval(6)), ["w is down: new"])
    }
}
