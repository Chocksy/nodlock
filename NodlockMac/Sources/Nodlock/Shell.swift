import Foundation

// Run an absolute-path tool, return (exitCode, trimmedStdout). GUI apps get a
// minimal PATH, so we resolve tools by probing common install locations.
struct Shell {
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 6) -> (Int32, String) {
        guard FileManager.default.isExecutableFile(atPath: path) else { return (127, "") }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return (-1, "") }

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline { usleep(20_000) }
        if proc.isRunning { proc.terminate() }
        proc.waitUntilExit()

        let data = out.fileHandleForReading.readDataToEndOfFile()
        let str = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (proc.terminationStatus, str)
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
