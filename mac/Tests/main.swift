// Tests/main.swift - run with ./build.sh --test (compiles against the Foundation-only
// sources, no AppKit). The network is stubbed at the transport, never our own
// functions, so deleting real logic makes these fail.

import Foundation

var failures = 0, passed = 0
func check(_ cond: @autoclosure () -> Bool, _ name: String, file: String = #file, line: Int = #line) {
    if cond() { passed += 1 } else { failures += 1; print("FAIL [\(line)] \(name)") }
}
func json(_ s: String) -> JSON { try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! JSON }

// MARK: stubs

final class MemStore: CredentialStore {
    var creds: [OAuthCred] = []
    var own: String?
    var writes: [(String, String?)] = []
    var failWrites = false
    func loadAll() -> [OAuthCred] { CredParse.rank(creds) }
    func writeBack(_ c: OAuthCred, access: String, refresh: String?, expiresAtMs: Double) -> Bool {
        if failWrites { return false }
        writes.append((access, refresh))
        if let i = creds.firstIndex(where: { $0.source == c.source }) {
            creds[i].accessToken = access; creds[i].refreshToken = refresh; creds[i].expiresAt = expiresAtMs
        }
        return true
    }
    func loadOwnRefresh() -> String? { own }
    func saveOwnRefresh(_ t: String?) { own = t }
}

/// A token server that rotates refresh tokens: each one works exactly once.
final class RotatingServer: HTTPTransport, @unchecked Sendable {
    var live: Set<String> = ["r0"]
    var n = 0
    var refreshCalls = 0
    var usageAuth: [String] = []
    let q = DispatchQueue(label: "server")
    func send(_ req: URLRequest) async throws -> (Int, Data) {
        try q.sync { try handle(req) }
    }
    private func handle(_ req: URLRequest) throws -> (Int, Data) {
        let url = req.url!.absoluteString
        if url.hasSuffix("/oauth/token") {
            refreshCalls += 1
            let b = try JSONSerialization.jsonObject(with: req.httpBody!) as! JSON
            let rt = b["refresh_token"] as! String
            guard live.remove(rt) != nil else { return (400, Data(#"{"error":"invalid_grant"}"#.utf8)) }
            n += 1
            live.insert("r\(n)")
            return (200, Data(#"{"access_token":"a\#(n)","refresh_token":"r\#(n)","expires_in":3600}"#.utf8))
        }
        usageAuth.append(req.value(forHTTPHeaderField: "Authorization") ?? "")
        check(req.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("claude-code/") == true, "UA header sent")
        check(req.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20", "beta header sent")
        return (200, Data(#"{"limits":[]}"#.utf8))
    }
}

func expired(_ at: String, _ rt: String?, src: OAuthCred.Source = .keychain(service: "Claude Code-credentials", account: "cp"), exp: Double = 1000) -> OAuthCred {
    OAuthCred(source: src, accessToken: at, refreshToken: rt, expiresAt: exp,
              raw: ["claudeAiOauth": ["accessToken": at, "refreshToken": rt as Any, "expiresAt": exp], "other": 1])
}

func runAsync(_ f: @escaping () async -> Void) {
    let s = DispatchSemaphore(value: 0)
    Task.detached { await f(); s.signal() }
    s.wait()
}

// MARK: parsing

Lang.current = .en
let payload = json("""
{
  "five_hour": {"utilization": 12.0, "resets_at": "2026-09-22T20:00:00.123456+00:00"},
  "tangelo": null, "nimbus_quill": null,
  "limits": [
    {"kind": "session", "percent": 42, "resets_at": "2026-09-22T20:00:00Z", "severity": "ok"},
    {"kind": "weekly_all", "percent": 77.4, "resets_at": "2026-09-25T17:00:00Z"},
    {"kind": "weekly_scoped", "percent": 0, "scope": {"model": {"display_name": "Sonnet"}}},
    {"kind": "weekly_scoped", "percent": 91, "resets_at": "2026-09-25T17:00:00Z", "scope": {"model": {"display_name": "Opus"}}, "severity": "critical"}
  ],
  "spend": {"enabled": true, "percent": 25, "used": {"amount_minor": 1250, "currency": "USD", "exponent": 2},
            "limit": {"amount_minor": 5000, "currency": "USD", "exponent": 2}}
}
""")
let rows = UsageParser.rows(from: payload)
check(rows.map(\.key) == ["session", "weekly_all", "weekly_scoped:Opus", "spend"], "limits drive rows; idle scoped cap and codenames skipped")
check(rows[0].percent == 42, "limits percent preferred over five_hour.utilization")
check(rows[2].short == "Opus", "scoped row named from scope.model.display_name")
check(Fmt.rank(percent: rows[2].percent, severity: rows[2].severity) == 2, "critical -> red")
check(Fmt.rank(percent: 10, severity: "warning") == 1, "server severity raises rank")
check(Fmt.rank(percent: 76, severity: "") == 1 && Fmt.rank(percent: 74, severity: "") == 0, "75% threshold")
check(rows[3].literal == "$12.50 / $50.00 mo", "money is in minor units: \(rows[3].literal ?? "nil")")

let legacy = UsageParser.rows(from: json("""
{"five_hour": {"utilization": 0.35, "resets_at": "2026-09-22T20:00:00Z"},
 "seven_day": {"utilization": 60}, "seven_day_opus": null,
 "extra_usage": {"is_enabled": true, "used_credits": 250000, "monthly_limit": 1000000, "decimal_places": 4, "currency": "USD"}}
"""))
check(legacy.map(\.key) == ["session", "weekly_all", "spend"], "named-field fallback; null per-model skipped")
check(abs(legacy[0].percent - 35) < 0.001, "fractional utilization scaled to percent")
check(legacy[2].literal == "$25.0000 / $100.0000 mo", "extra_usage scaled by decimal_places: \(legacy[2].literal ?? "nil")")
check(abs(legacy[2].percent - 25) < 0.001, "extra_usage percent derived when utilization missing")

check(UsageParser.email(fromProfile: json(#"{"account":{"email":"kryptosubs@gmail.com"}}"#)) == "kryptosubs@gmail.com", "email from account")

// MARK: dates and countdowns

let base = ISODate.parse("2026-09-22T18:00:00Z")!
check(ISODate.parse("2026-09-22T18:00:00.123456+00:00") == base, "6-digit fractions parse")
check(ISODate.parse("2026-09-22T18:00:00") == base, "naive timestamp = UTC")
check(ISODate.parse("2026-09-22T11:00:00-0700") == base, "offset without colon")
check(ISODate.parse("garbage") == nil && ISODate.parse(nil) == nil, "bad input -> nil")

let utc = TimeZone(identifier: "UTC")!
let c1 = Fmt.countdown(base.addingTimeInterval(90 * 60 - 1), now: base, short: true, timeZone: utc)
check(c1.hasPrefix("1h30m"), "rounds up to the minute and floors hours (no banker's rounding): \(c1)")
let c2 = Fmt.countdown(base.addingTimeInterval(3 * 86400 + 3600), now: base, short: true, timeZone: utc)
check(c2.hasPrefix("3d1h"), "days: \(c2)")
check(Fmt.countdown(base.addingTimeInterval(-5), now: base, short: true) == "resetting", "past -> resetting")
Lang.current = .zh
let c3 = Fmt.countdown(base.addingTimeInterval(45 * 60), now: base, short: false, timeZone: utc)
check(c3.hasPrefix("45 分鐘後重置"), "zh long form: \(c3)")
check(UsageParser.rows(from: payload)[0].label == "工作階段（5 小時）", "zh labels")
Lang.current = .en

// MARK: credentials helpers

check(CredParse.decodeSecret("7b2261223a317d") == Data(#"{"a":1}"#.utf8), "hex secret decoded")
check(CredParse.decodeSecret(#"{"a":1}"#) == Data(#"{"a":1}"#.utf8), "plain secret passed through")
let dump = """
keychain: "/Users/cp/Library/Keychains/login.keychain-db"
class: "genp"
attributes:
    "acct"<blob>="cp"
    "svce"<blob>="Claude Code-credentials"
keychain: "/Users/cp/Library/Keychains/login.keychain-db"
class: "genp"
attributes:
    "acct"<blob>="cp"
    "svce"<blob>="Claude Code-credentials-1a2b3c"
keychain: "/Users/cp/Library/Keychains/login.keychain-db"
class: "genp"
attributes:
    "acct"<blob>="someone"
    "svce"<blob>="Unrelated"
"""
let items = CredParse.claudeItems(fromDump: dump)
check(items.count == 2 && items[1].0 == "Claude Code-credentials-1a2b3c" && items[1].1 == "cp", "dump-keychain parsing")

let upd = CredParse.updated(["claudeAiOauth": ["accessToken": "old", "scopes": ["x"]], "keep": true],
                            access: "new", refresh: "rN", expiresAtMs: 123)!
let updJ = try! JSONSerialization.jsonObject(with: upd) as! JSON
check(updJ.obj("claudeAiOauth")?.str("refreshToken") == "rN" && updJ["keep"] as? Bool == true
      && updJ.obj("claudeAiOauth")?["scopes"] != nil, "write-back keeps every other field")

let ranked = CredParse.rank([expired("stale", nil, exp: 5), expired("fresh", nil, exp: 9e15)])
check(ranked.first?.accessToken == "fresh", "rank by expiry, not by order found")

// MARK: token lifecycle against a rotating server

runAsync {
    // 1) three consecutive refreshes survive rotation, and Claude Code's item is kept in sync
    let store = MemStore(); store.creds = [expired("a0", "r0")]
    let server = RotatingServer()
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    let client = UsageClient(store: store, http: server, now: { clock })
    var ok = 0
    for _ in 0..<3 {
        if (try? await client.usage()) != nil { ok += 1 }
        clock = clock.addingTimeInterval(7200)          // token expires between polls
    }
    check(ok == 3, "3 of 3 consecutive refreshes succeed (got \(ok))")
    check(store.creds[0].refreshToken == "r3", "rotated refresh token written back to source")
    check(store.own == nil, "no private copy needed when write-back works")
    check(server.usageAuth == ["Bearer a1", "Bearer a2", "Bearer a3"], "fresh access token used each time")

    // 2) write-back fails -> widget keeps its own copy and prefers it next time
    let s2 = MemStore(); s2.creds = [expired("a0", "r0")]; s2.failWrites = true
    let srv2 = RotatingServer()
    var clk2 = Date(timeIntervalSince1970: 1_800_000_000)
    let c2 = UsageClient(store: s2, http: srv2, now: { clk2 })
    _ = try? await c2.usage()
    check(s2.own == "r1", "own copy kept when write-back fails")
    clk2 = clk2.addingTimeInterval(7200)
    let r2 = try? await c2.usage()
    check(r2 != nil && s2.own == "r2", "own copy used and rotated on the next refresh")

    // 3) a still-valid token is used without refreshing
    let s3 = MemStore(); s3.creds = [expired("live", "r0", exp: 9e15)]
    let srv3 = RotatingServer()
    let c3 = UsageClient(store: s3, http: srv3)
    _ = try? await c3.usage()
    check(srv3.refreshCalls == 0 && srv3.usageAuth == ["Bearer live"], "valid token -> no refresh")

    // 4) parallel callers share one refresh (never spend a rotating token twice)
    let s4 = MemStore(); s4.creds = [expired("a0", "r0")]
    let srv4 = RotatingServer()
    let c4 = UsageClient(store: s4, http: srv4, now: { Date(timeIntervalSince1970: 1_800_000_000) })
    async let x = try? c4.usage()
    async let y = try? c4.profile()
    let (rx, ry) = await (x, y)
    check(rx != nil && ry != nil && srv4.refreshCalls == 1, "concurrent calls -> one refresh (\(srv4.refreshCalls))")

    // 5) no login at all
    let c5 = UsageClient(store: MemStore(), http: RotatingServer())
    do { _ = try await c5.usage(); check(false, "noToken expected") }
    catch let e as UsageError { if case .noToken = e { check(true, "") } else { check(false, "noToken expected, got \(e)") } }
    catch { check(false, "noToken expected") }

    // 6) HTTP status survives to the caller (the PowerShell version once lost it)
    struct Deny: HTTPTransport { func send(_ r: URLRequest) async throws -> (Int, Data) { (401, Data()) } }
    let s6 = MemStore(); s6.creds = [expired("x", nil, exp: 9e15)]
    let c6 = UsageClient(store: s6, http: Deny())
    do { _ = try await c6.usage() } catch { check((error as? UsageError)?.status == 401, "401 reaches the UI") }
}

print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
