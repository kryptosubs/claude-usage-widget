// Snapshot.swift - hands the latest usage to other local tools (the ai-usage
// dashboard) so they never touch the login. Foundation only; no token is ever
// written here.
//
//   ~/Library/Application Support/ClaudeUsage/latest.json    newest state, rewritten after every fetch
//   ~/Library/Application Support/ClaudeUsage/history.jsonl  one line per successful fetch, 35 days kept
//
// The widget stays the only process that reads or refreshes the login. A second
// reader refreshing on its own would spend the same rotating refresh token.

import Foundation

enum Snapshot {
    static var dir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClaudeUsage", isDirectory: true)
    static var keepDays: Double = 35
    static let schema = 1

    static var latestURL: URL { dir.appendingPathComponent("latest.json") }
    static var historyURL: URL { dir.appendingPathComponent("history.jsonl") }

    private static var lastPrune: Date?

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    /// After every fetch, good or bad. `payload` is the last GOOD response, kept on
    /// failures so readers still have numbers; `status` says how fresh they are.
    @discardableResult
    static func writeLatest(payload: JSON?, account: String?, status: String,
                            lastOk: Date?, now: Date = Date()) -> Bool {
        var o: JSON = ["schema": schema, "written_at": iso(now), "status": status]
        if let a = account { o["account"] = a }
        if let t = lastOk { o["fetched_at"] = iso(t) }
        if let p = payload, JSONSerialization.isValidJSONObject(p) { o["payload"] = p }
        guard JSONSerialization.isValidJSONObject(o),
              let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return false }
        return write(data, to: latestURL)
    }

    /// One compact line per successful fetch: {"t":"…","rows":[{"k":"weekly_all","p":71,"r":"…"}]}.
    /// Keys only, never labels, so the history does not depend on the UI language.
    @discardableResult
    static func appendHistory(rows: [UsageRow], now: Date = Date()) -> Bool {
        let items: [JSON] = rows.filter { $0.key != "spend" }.map { r in
            var j: JSON = ["k": r.key, "p": (r.percent * 10).rounded() / 10]
            if let d = r.resetsAt { j["r"] = iso(d) }
            return j
        }
        let line: JSON = ["t": iso(now), "rows": items]
        guard var bytes = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return false }
        bytes.append(0x0A)
        guard ensureDir() else { return false }
        if FileManager.default.fileExists(atPath: historyURL.path),
           let h = try? FileHandle(forWritingTo: historyURL) {
            h.seekToEndOfFile()
            h.write(bytes)
            try? h.close()
        } else if !write(bytes, to: historyURL) {
            return false
        }
        if lastPrune == nil || now.timeIntervalSince(lastPrune!) > 86_400 {
            prune(now: now)
        }
        return true
    }

    /// Drops history lines older than `keepDays` (and any line that does not parse).
    static func prune(now: Date = Date()) {
        lastPrune = now
        guard let text = try? String(contentsOf: historyURL, encoding: .utf8) else { return }
        let cutoff = now.addingTimeInterval(-keepDays * 86_400)
        var kept: [Substring] = []
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: d) as? JSON,
                  let t = ISODate.parse(j.str("t")), t >= cutoff else { continue }
            kept.append(line)
        }
        let out = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        write(Data(out.utf8), to: historyURL)
    }

    @discardableResult
    private static func ensureDir() -> Bool {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            return true
        } catch { return false }
    }

    @discardableResult
    private static func write(_ data: Data, to url: URL) -> Bool {
        guard ensureDir() else { return false }
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch { return false }
    }
}
