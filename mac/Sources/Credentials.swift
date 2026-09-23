// Credentials.swift - finding Claude Code's OAuth login on a Mac and keeping it
// alive. Foundation only (talks to the Keychain through /usr/bin/security).
//
// Where Claude Code keeps its login on macOS:
//   * the login Keychain, generic password, service "Claude Code-credentials"
//     (a suffixed variant exists when CLAUDE_CONFIG_DIR is set), account = $USER
//   * ~/.claude/.credentials.json (older installs, or when the Keychain was locked)
// Both hold {"claudeAiOauth": {accessToken, refreshToken, expiresAt(ms), ...}}.
//
// Why /usr/bin/security instead of SecItemCopyMatching: Claude Code writes the
// item with that same tool, so it is already on the item's access list and reads
// from here do not raise a "wants to use your confidential information" prompt.

import Foundation

struct OAuthCred {
    enum Source: Equatable {
        case keychain(service: String, account: String)
        case file(path: String)
        case env
    }
    var source: Source
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Double          // epoch ms; 0 = not recorded
    var raw: JSON                  // whole document, so a write-back keeps every other field

    var label: String {
        switch source {
        case .keychain(let s, let a): return "Keychain: \(s) (\(a))"
        case .file(let p):            return "File: \(p)"
        case .env:                    return "CLAUDE_CODE_OAUTH_TOKEN"
        }
    }
    func isValid(nowMs: Double, marginMs: Double = 60_000) -> Bool {
        expiresAt == 0 || expiresAt > nowMs + marginMs
    }
}

protocol CredentialStore {
    /// Every login found, freshest first.
    func loadAll() -> [OAuthCred]
    /// Persist a refreshed token pair back into the source it came from.
    func writeBack(_ cred: OAuthCred, access: String, refresh: String?, expiresAtMs: Double) -> Bool
    /// The widget's own copy of a rotated refresh token, used only when a write-back failed.
    func loadOwnRefresh() -> String?
    func saveOwnRefresh(_ token: String?)
}

enum CredParse {
    static func cred(from data: Data, source: OAuthCred.Source) -> OAuthCred? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? JSON,
              let o = obj.obj("claudeAiOauth"),
              let at = o.str("accessToken") else { return nil }
        return OAuthCred(source: source, accessToken: at, refreshToken: o.str("refreshToken"),
                         expiresAt: o.num("expiresAt") ?? 0, raw: obj)
    }

    /// Same document with only the token fields replaced.
    static func updated(_ raw: JSON, access: String, refresh: String?, expiresAtMs: Double) -> Data? {
        var doc = raw
        var o = raw.obj("claudeAiOauth") ?? [:]
        o["accessToken"] = access
        if let r = refresh { o["refreshToken"] = r }
        o["expiresAt"] = NSNumber(value: Int64(expiresAtMs))
        doc["claudeAiOauth"] = o
        return try? JSONSerialization.data(withJSONObject: doc)
    }

    /// Rank by expiry, never "first found": a stale login and a live one commonly
    /// coexist, and taking the first meant authenticating with a month-dead token.
    static func rank(_ creds: [OAuthCred]) -> [OAuthCred] {
        creds.sorted { $0.expiresAt > $1.expiresAt }
    }

    /// `security -w` prints the secret as text, or as hex if it is not printable.
    static func decodeSecret(_ s: String) -> Data? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("{") { return t.data(using: .utf8) }
        guard t.count % 2 == 0, t.allSatisfy({ $0.isHexDigit }) else { return t.data(using: .utf8) }
        var out = Data(capacity: t.count / 2)
        var i = t.startIndex
        while i < t.endIndex {
            let j = t.index(i, offsetBy: 2)
            guard let b = UInt8(t[i..<j], radix: 16) else { return nil }
            out.append(b); i = j
        }
        return out
    }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// Pull (service, account) pairs for Claude Code items out of `security dump-keychain`.
    static func claudeItems(fromDump dump: String) -> [(String, String)] {
        var out: [(String, String)] = []
        var acct: String? = nil, svce: String? = nil
        func flush() {
            if let s = svce, s.hasPrefix("Claude Code-credentials") {
                let a = acct ?? NSUserName()
                if !out.contains(where: { $0.0 == s && $0.1 == a }) { out.append((s, a)) }
            }
            acct = nil; svce = nil
        }
        for line in dump.components(separatedBy: "\n") {
            if line.hasPrefix("keychain:") { flush(); continue }
            if let v = attr(line, "acct") { acct = v }
            if let v = attr(line, "svce") { svce = v }
        }
        flush()
        return out
    }

    private static func attr(_ line: String, _ name: String) -> String? {
        guard line.contains("\"\(name)\"<blob>=\"") else { return nil }
        guard let start = line.range(of: "<blob>=\"")?.upperBound,
              let end = line.range(of: "\"", options: .backwards), end.lowerBound > start else { return nil }
        return String(line[start..<end.lowerBound])
    }
}

// MARK: - process helper

struct ProcResult { var status: Int32; var out: String; var err: String }

func runProcess(_ path: String, _ args: [String], stdin: String? = nil, timeout: TimeInterval = 8) -> ProcResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let o = Pipe(), e = Pipe()
    p.standardOutput = o; p.standardError = e
    let i = Pipe()
    p.standardInput = i
    do { try p.run() } catch { return ProcResult(status: -1, out: "", err: "\(error)") }
    if let s = stdin { i.fileHandleForWriting.write(s.data(using: .utf8)!) }
    try? i.fileHandleForWriting.close()

    // read both pipes on background queues so a large dump cannot deadlock us
    final class Box: @unchecked Sendable { var data = Data() }
    let outBox = Box(), errBox = Box()
    let g = DispatchGroup()
    g.enter(); DispatchQueue.global().async { outBox.data = o.fileHandleForReading.readDataToEndOfFile(); g.leave() }
    g.enter(); DispatchQueue.global().async { errBox.data = e.fileHandleForReading.readDataToEndOfFile(); g.leave() }
    if g.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        _ = g.wait(timeout: .now() + 1)
        return ProcResult(status: -2, out: "", err: "timed out")
    }
    p.waitUntilExit()
    return ProcResult(status: p.terminationStatus,
                      out: String(data: outBox.data, encoding: .utf8) ?? "",
                      err: String(data: errBox.data, encoding: .utf8) ?? "")
}

// MARK: - the real store

final class MacCredentialStore: CredentialStore {
    static let security = "/usr/bin/security"
    static let defaultService = "Claude Code-credentials"
    static let ownService = "com.kryptohead.claude-usage"
    static let ownAccount = "refresh-token"

    private var cachedItems: [(String, String)]? = nil
    private let lock = NSLock()

    func rescan() { lock.lock(); cachedItems = nil; lock.unlock() }

    private func keychainItems() -> [(String, String)] {
        lock.lock(); defer { lock.unlock() }
        if let c = cachedItems { return c }
        var items: [(String, String)] = []
        // dump-keychain lists attributes only (no secrets), so it never prompts
        let r = runProcess(Self.security, ["dump-keychain"], timeout: 10)
        if r.status == 0 { items = CredParse.claudeItems(fromDump: r.out) }
        if !items.contains(where: { $0.0 == Self.defaultService }) {
            items.insert((Self.defaultService, NSUserName()), at: 0)
        }
        cachedItems = items
        return items
    }

    private func filePaths() -> [String] {
        var paths: [String] = []
        if let d = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !d.isEmpty {
            paths.append((d as NSString).appendingPathComponent(".credentials.json"))
        }
        paths.append((NSHomeDirectory() as NSString).appendingPathComponent(".claude/.credentials.json"))
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    func loadAll() -> [OAuthCred] {
        var found: [OAuthCred] = []
        for (svc, acct) in keychainItems() {
            // -a narrows to the right item when several accounts share a service name
            var r = runProcess(Self.security, ["find-generic-password", "-s", svc, "-a", acct, "-w"])
            if r.status != 0 {
                r = runProcess(Self.security, ["find-generic-password", "-s", svc, "-w"])
            }
            guard r.status == 0, let data = CredParse.decodeSecret(r.out) else { continue }
            if let c = CredParse.cred(from: data, source: .keychain(service: svc, account: acct)) { found.append(c) }
        }
        for p in filePaths() {
            if let d = FileManager.default.contents(atPath: p),
               let c = CredParse.cred(from: d, source: .file(path: p)) { found.append(c) }
        }
        return CredParse.rank(found)
    }

    func writeBack(_ cred: OAuthCred, access: String, refresh: String?, expiresAtMs: Double) -> Bool {
        guard let data = CredParse.updated(cred.raw, access: access, refresh: refresh, expiresAtMs: expiresAtMs)
        else { return false }
        switch cred.source {
        case .keychain(let svc, let acct):
            return setKeychain(service: svc, account: acct, data: data)
        case .file(let path):
            let url = URL(fileURLWithPath: path)
            do {
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
                return true
            } catch { return false }
        case .env:
            return false
        }
    }

    /// `security -i` reads the command from stdin, so the secret never shows up
    /// in the process list the way an -w/-X argument would.
    private func setKeychain(service: String, account: String, data: Data) -> Bool {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                                                 .replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let cmd = "add-generic-password -U -a \(q(account)) -s \(q(service)) -X \(CredParse.hex(data))\n"
        let r = runProcess(Self.security, ["-i"], stdin: cmd)
        return r.status == 0 && !r.err.lowercased().contains("error")
    }

    func loadOwnRefresh() -> String? {
        let r = runProcess(Self.security, ["find-generic-password", "-s", Self.ownService, "-a", Self.ownAccount, "-w"])
        guard r.status == 0 else { return nil }
        let t = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    func saveOwnRefresh(_ token: String?) {
        if let t = token, let d = t.data(using: .utf8) {
            _ = setKeychain(service: Self.ownService, account: Self.ownAccount, data: d)
        } else {
            _ = runProcess(Self.security, ["delete-generic-password", "-s", Self.ownService, "-a", Self.ownAccount])
        }
    }
}
