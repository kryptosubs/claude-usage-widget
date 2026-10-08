// Tests/SnapshotTests.swift - the files the menu-bar app hands to other local tools.
// Built as its own small binary by ./build.sh --test (after Tests/main.swift).

import Foundation

@main
enum SnapshotTests {
    static var failures = 0, passed = 0
    static func check(_ cond: Bool, _ name: String, line: Int = #line) {
        if cond { passed += 1 } else { failures += 1; print("FAIL [snapshot:\(line)] \(name)") }
    }

    static func main() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-usage-snapshot-\(UUID().uuidString)", isDirectory: true)
        Snapshot.dir = tmp
        defer { try? FileManager.default.removeItem(at: tmp) }

        let payload = try! JSONSerialization.jsonObject(with: Data("""
        {"limits": [
          {"kind": "session", "percent": 42, "resets_at": "2026-10-09T00:00:00Z"},
          {"kind": "weekly_all", "percent": 71.04, "resets_at": "2026-10-12T16:00:00Z"},
          {"kind": "weekly_scoped", "percent": 30, "resets_at": "2026-10-12T16:00:00Z", "scope": {"model": {"display_name": "Opus"}}}
         ],
         "spend": {"enabled": true, "percent": 25, "used": {"amount_minor": 1250, "currency": "USD", "exponent": 2}}}
        """.utf8)) as! JSON
        let t0 = ISODate.parse("2026-10-08T21:46:00Z")!

        // latest.json
        check(Snapshot.writeLatest(payload: payload, account: "kryptosubs@gmail.com", status: "live",
                                   lastOk: t0, now: t0), "latest.json written")
        let raw = (try? Data(contentsOf: Snapshot.latestURL)) ?? Data()
        let latest = (try? JSONSerialization.jsonObject(with: raw)) as? JSON ?? [:]
        check(latest.str("status") == "live", "status recorded")
        check(latest.str("fetched_at") == "2026-10-08T21:46:00Z", "fetch time recorded: \(latest.str("fetched_at") ?? "nil")")
        check(latest.str("account") == "kryptosubs@gmail.com", "account recorded")
        check((latest.obj("payload")?["limits"] as? [Any])?.count == 3, "raw payload kept for other parsers")
        let text = String(data: raw, encoding: .utf8) ?? ""
        check(!text.lowercased().contains("token"), "nothing token-like in the snapshot")
        let attrs = (try? FileManager.default.attributesOfItem(atPath: Snapshot.latestURL.path)) ?? [:]
        check(((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) == 0o600, "snapshot is owner-only")

        // a failed fetch keeps the last good numbers and says how stale they are
        check(Snapshot.writeLatest(payload: payload, account: nil, status: "offline", lastOk: t0,
                                   now: t0.addingTimeInterval(600)), "rewritten after a failure")
        let after = ((try? Data(contentsOf: Snapshot.latestURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? JSON ?? [:]
        check(after.str("status") == "offline" && after.obj("payload") != nil
              && after.str("fetched_at") == "2026-10-08T21:46:00Z", "last good payload survives a failed fetch")

        // history.jsonl: keys not labels, spend left out, old lines pruned
        Lang.current = .zh
        let rows = UsageParser.rows(from: payload)
        check(Snapshot.appendHistory(rows: rows, now: t0.addingTimeInterval(-40 * 86_400)), "old line appended")
        check(Snapshot.appendHistory(rows: rows, now: t0), "new line appended")
        Lang.current = .en
        let lines = ((try? String(contentsOf: Snapshot.historyURL, encoding: .utf8)) ?? "")
            .split(separator: "\n")
        check(lines.count == 1, "lines older than 35 days pruned (\(lines.count) left)")
        let h = lines.first.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? JSON ?? [:]
        let ks = (h["rows"] as? [JSON])?.compactMap { $0.str("k") } ?? []
        check(ks == ["session", "weekly_all", "weekly_scoped:Opus"], "history uses keys and skips spend: \(ks)")
        let weekly = (h["rows"] as? [JSON])?.first { $0.str("k") == "weekly_all" }
        check(weekly?.num("p") == 71, "percent rounded to one decimal: \(weekly?.num("p") ?? -1)")
        check(weekly?.str("r") == "2026-10-12T16:00:00Z", "reset time kept")
        check(h.str("t") == "2026-10-08T21:46:00Z", "line timestamp")

        // appending keeps earlier lines
        check(Snapshot.appendHistory(rows: rows, now: t0.addingTimeInterval(180)), "third line appended")
        let n = ((try? String(contentsOf: Snapshot.historyURL, encoding: .utf8)) ?? "").split(separator: "\n").count
        check(n == 2, "append does not overwrite (\(n) lines)")

        print("snapshot: \(passed) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
