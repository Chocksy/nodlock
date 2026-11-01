import Foundation

// Run an absolute-path tool, return (exitCode, trimmedStdout). GUI apps get a
// minimal PATH, so we resolve tools by probing common install locations.
struct Shell {
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 6) -> (Int32, String) {
        guard FileManager.default.isExecutableFile(atPath: path) else { return (127, "") }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        // launchd hands us PATH=/usr/bin:/bin:/usr/sbin:/sbin, so scripts like
        // ~/.local/bin/vpn could not find tailscale / warp-cli (exit 127).
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            + (env["PATH"].map { ":" + $0 } ?? "")
        proc.environment = env
        // Output goes to a temp file, not a pipe: a grandchild that outlives a
        // timed-out child would hold a pipe open and block the read forever.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodlock-\(UUID().uuidString).out")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: tmp) else { return (-1, "") }
        defer { try? fh.close(); try? FileManager.default.removeItem(at: tmp) }
        proc.standardOutput = fh
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return (-1, "") }

        func waitExit(_ secs: TimeInterval) {
            let end = Date().addingTimeInterval(secs)
            while proc.isRunning && Date() < end { usleep(20_000) }
        }
        waitExit(timeout)
        let timedOut = proc.isRunning
        // ponytail: signals go to the child only; grandchildren of `sh -c` may linger.
        if timedOut {
            proc.terminate()
            waitExit(2)
            if proc.isRunning {
                let pid = proc.processIdentifier
                kill(-pid, SIGKILL)  // its process group, like terminate(); no-op if it has none
                kill(pid, SIGKILL)
                waitExit(1)
            }
        }

        let data = (try? Data(contentsOf: tmp)) ?? Data()
        let str = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // 124 = timeout (as in coreutils `timeout`); never read terminationStatus of a live process.
        if timedOut || proc.isRunning { return (124, str) }
        return (proc.terminationStatus, str)
    }

    // `/bin/sh -c cmd` with stderr merged into the returned output. Used by
    // `command` watches and health fixes (local watches.json only).
    static func sh(_ cmd: String, timeout: TimeInterval) -> (Int32, String) {
        run("/bin/sh", ["-c", "exec 2>&1\n" + cmd], timeout: timeout)
    }

    // First existing candidate path, else nil.
    static func resolve(_ candidates: [String]) -> String? {
        for c in candidates {
            let p = (c as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static var tailscale: String? {
        resolve([
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        ])
    }

    static var warpCli: String? {
        resolve([
            "/usr/local/bin/warp-cli",
            "/opt/homebrew/bin/warp-cli",
            "/Applications/Cloudflare WARP.app/Contents/Resources/warp-cli",
        ])
    }

    static var vpn: String? {
        resolve(["~/.local/bin/vpn"])
    }
}
