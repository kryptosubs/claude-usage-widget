// UsageClient.swift - token selection/refresh and the two API calls.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum UsageError: Error, CustomStringConvertible {
    case noToken
    case http(call: String, status: Int, body: String)
    case refreshRejected(Int)
    case network(String)

    var status: Int {
        switch self {
        case .http(_, let s, _):        return s
        case .refreshRejected(let s):   return s
        default:                        return 0
        }
    }
    var description: String {
        switch self {
        case .noToken:                  return "no Claude Code login found"
        case .http(let c, let s, let b): return "\(c): HTTP \(s)" + (b.isEmpty ? "" : " \(b.prefix(160))")
        case .refreshRejected(let s):   return "refresh rejected (\(s))"
        case .network(let m):           return m
        }
    }
}

/// Anything that can send one request. The real one is URLSession; tests stub the
/// network here, not the refresh function (stubbing our own function once hid its
/// accidental deletion).
protocol HTTPTransport {
    func send(_ req: URLRequest) async throws -> (Int, Data)
}

struct URLSessionTransport: HTTPTransport {
    func send(_ req: URLRequest) async throws -> (Int, Data) {
        try await withCheckedThrowingContinuation { cont in
            URLSession.shared.dataTask(with: req) { data, resp, err in
                if let err = err { cont.resume(throwing: UsageError.network(err.localizedDescription)); return }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                cont.resume(returning: (code, data ?? Data()))
            }.resume()
        }
    }
}

actor UsageClient {
    static let usageURL   = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    // console.anthropic.com was retired (404). api.anthropic.com is live; the
    // others stay as fallbacks in case it moves again.
    static let tokenURLs = [
        "https://api.anthropic.com/v1/oauth/token",
        "https://platform.claude.com/v1/oauth/token",
    ].compactMap(URL.init(string:))
    static let clientId  = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"   // Claude Code's public OAuth client
    static let userAgent = "claude-code/2.0.0"   // without it you land in a much harsher rate-limit bucket

    let store: CredentialStore
    let http: HTTPTransport
    let now: () -> Date

    private var cachedToken: String?
    private var cachedExpiresMs: Double = 0
    private var rejectedToken: String?

    private(set) var usedSource: String?
    private(set) var lastRefreshError: String?

    init(store: CredentialStore, http: HTTPTransport = URLSessionTransport(), now: @escaping () -> Date = Date.init) {
        self.store = store; self.http = http; self.now = now
    }

    private var nowMs: Double { now().timeIntervalSince1970 * 1000 }

    /// Call after a 401/403: forget the token and look again next time.
    func invalidate() {
        if let t = cachedToken { rejectedToken = t }
        cachedToken = nil
        cachedExpiresMs = 0
        (store as? MacCredentialStore)?.rescan()
    }

    private var inflight: Task<String, Error>?

    /// One resolution at a time: the actor is re-entrant across awaits, and two
    /// parallel refreshes would spend the same rotating refresh token twice.
    func accessToken() async throws -> String {
        if let t = inflight { return try await t.value }
        let t = Task { try await self.resolveToken() }
        inflight = t
        defer { inflight = nil }
        return try await t.value
    }

    private func resolveToken() async throws -> String {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], !env.isEmpty {
            usedSource = "CLAUDE_CODE_OAUTH_TOKEN"; return env
        }
        if let t = cachedToken, cachedExpiresMs > nowMs + 60_000 { return t }

        // Re-read every time the cache is cold: Claude Code refreshes its own token
        // while you use it, and picking that up costs nothing.
        let sources = store.loadAll()

        // pass 1: any login whose access token is still valid (and not just rejected)
        for c in sources where c.isValid(nowMs: nowMs) && c.accessToken != rejectedToken {
            cachedToken = c.accessToken
            cachedExpiresMs = c.expiresAt == 0 ? nowMs + 300_000 : c.expiresAt
            usedSource = c.label
            return c.accessToken
        }

        // pass 2: expired - refresh.
        //
        // Refresh tokens ROTATE: the server returns a new one and invalidates the
        // one just spent. So the new pair is written BACK into Claude Code's own
        // Keychain item. That keeps Claude Code signed in too; otherwise the widget
        // would silently log Claude Code out the first time it refreshed. Only if the
        // write-back fails is the new refresh token kept in the widget's own item,
        // and that one is tried first next time because it is then the only live one.
        var candidates: [(label: String, token: String, own: Bool, target: OAuthCred?)] = []
        let target = sources.first(where: { $0.refreshToken != nil }) ?? sources.first
        if let own = store.loadOwnRefresh() {
            candidates.append(("widget keychain item", own, true, target))
        }
        for c in sources {
            if let r = c.refreshToken { candidates.append((c.label, r, false, c)) }
        }

        var errs: [String] = []
        for cand in candidates {
            do {
                let (access, refresh, ttl) = try await refreshTokens(cand.token)
                let exp = nowMs + ttl * 1000
                cachedToken = access; cachedExpiresMs = exp; rejectedToken = nil
                var wrote = false
                if let t = cand.target {
                    wrote = store.writeBack(t, access: access, refresh: refresh ?? cand.token, expiresAtMs: exp)
                }
                store.saveOwnRefresh(wrote ? nil : (refresh ?? cand.token))
                usedSource = cand.label + " (refreshed" + (wrote ? ", saved back)" : ")")
                lastRefreshError = errs.isEmpty ? nil : errs.joined(separator: " | ")
                return access
            } catch {
                errs.append("\(cand.label) -> \(error)")
                if cand.own { store.saveOwnRefresh(nil) }   // spent or revoked
            }
        }
        lastRefreshError = errs.isEmpty ? nil : errs.joined(separator: " | ")

        // pass 3: nothing refreshed - send the freshest token and let the server decide
        guard let first = sources.first else { throw UsageError.noToken }
        usedSource = first.label + " (stale)"
        return first.accessToken
    }

    private func refreshTokens(_ token: String) async throws -> (String, String?, Double) {
        let body = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": token, "client_id": Self.clientId,
        ])
        var last: Error = UsageError.network("no token endpoint reachable")
        for url in Self.tokenURLs {
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            do {
                let (code, data) = try await http.send(req)
                // 400/401: the endpoint is alive and said no; other hosts would repeat it
                if code == 400 || code == 401 { throw UsageError.refreshRejected(code) }
                guard code == 200,
                      let j = try? JSONSerialization.jsonObject(with: data) as? JSON,
                      let at = j.str("access_token") else {
                    last = UsageError.http(call: "token", status: code, body: "")
                    continue
                }
                return (at, j.str("refresh_token"), j.num("expires_in") ?? 3600)
            } catch let e as UsageError {
                if case .refreshRejected = e { throw e }
                last = e
            }
        }
        throw last
    }

    private func get(_ url: URL, call: String) async throws -> JSON {
        let token = try await accessToken()
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (code, data) = try await http.send(req)
        guard code == 200 else {
            if code == 401 || code == 403 { invalidate() }
            throw UsageError.http(call: call, status: code, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let j = try? JSONSerialization.jsonObject(with: data) as? JSON else {
            throw UsageError.http(call: call, status: code, body: "not JSON")
        }
        return j
    }

    func usage() async throws -> JSON   { try await get(Self.usageURL, call: "usage endpoint") }
    func profile() async throws -> JSON { try await get(Self.profileURL, call: "profile endpoint") }

    /// Probe a token endpoint unauthenticated: 400/401 = alive, 404 = retired.
    func probe(_ url: URL) async -> String {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"; req.httpBody = Data("{}".utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (code, _) = try await http.send(req)
            switch code {
            case 400, 401: return "OK (alive, \(code))"
            case 404:      return "404 - retired"
            default:       return "HTTP \(code)"
            }
        } catch { return "unreachable (\(error))" }
    }
}

// MARK: - diagnostics (shared by --diagnose and the "Copy diagnostics" menu item)

enum Diagnostics {
    static func report(client: UsageClient, store: CredentialStore) async -> String {
        var out: [String] = ["Claude Usage (macOS) - diagnostics", String(repeating: "-", count: 34)]
        let nowMs = Date().timeIntervalSince1970 * 1000
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"

        let sources = store.loadAll()
        out.append("Claude Code logins found:")
        if sources.isEmpty {
            out.append("  (none) - run `claude` in Terminal and /login")
        }
        for c in sources {
            var when = "no expiry recorded"
            if c.expiresAt > 0 {
                let d = df.string(from: Date(timeIntervalSince1970: c.expiresAt / 1000))
                when = c.isValid(nowMs: nowMs) ? "valid until \(d)" : "EXPIRED \(d)"
            }
            out.append("  \(c.label)")
            out.append("      \(when), " + (c.refreshToken != nil ? "refresh token present" : "no refresh token"))
        }
        if store.loadOwnRefresh() != nil {
            out.append("  widget keychain item: holds its own rotated refresh token")
        }

        out.append(""); out.append("refresh endpoints:")
        for u in UsageClient.tokenURLs { out.append("  \(u.absoluteString)  \(await client.probe(u))") }

        out.append("")
        do {
            let u = try await client.usage()
            out.append("usage endpoint: OK")
            if let s = await client.usedSource { out.append("  authenticated via: \(s)") }
            if let e = await client.lastRefreshError { out.append("  (note: refresh said \(e))") }
            if let p = try? await client.profile() {
                out.append("  account: \(UsageParser.email(fromProfile: p) ?? "(no email in profile)")")
            }
            out.append(""); out.append("as the widget shows it:")
            for r in UsageParser.rows(from: u) {
                let reset = r.literal ?? Fmt.countdown(r.resetsAt, short: false)
                out.append(String(format: "  %@  %3.0f%%   %@", r.label.padding(toLength: 22, withPad: " ", startingAt: 0), r.percent, reset))
            }
            out.append(""); out.append("raw response:")
            if let d = try? JSONSerialization.data(withJSONObject: u, options: [.prettyPrinted, .sortedKeys]),
               let s = String(data: d, encoding: .utf8) { out.append(s) }
        } catch {
            out.append("usage endpoint: FAILED  \(error)")
            if let s = await client.usedSource { out.append("  tried with: \(s)") }
            if let e = await client.lastRefreshError { out.append("  refresh error: \(e)") }
            let st = (error as? UsageError)?.status ?? 0
            if st == 401 || st == 403 {
                out.append("  -> no usable login. Run `claude` in Terminal, then /login.")
                out.append("     `claude setup-token` tokens do NOT work here (the usage endpoint 403s them).")
            }
            if st == 429 { out.append("  -> rate limited; wait a few minutes.") }
        }
        return out.joined(separator: "\n")
    }
}
