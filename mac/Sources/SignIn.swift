// SignIn.swift - signing the widget in on its own, in the browser.
//
// The same OAuth flow Claude Code's /login uses: PKCE, Claude Code's public
// client id, a localhost redirect. The browser opens claude.ai, where
// "Continue with Google" (or whatever the account uses) does the actual sign-in;
// if the browser is already signed in to claude.ai it is one "Authorize" click.
// claude.ai then redirects to a one-shot listener on the loopback interface with
// a code, which is exchanged for an access + refresh token pair.
//
// The result is the widget's OWN login, kept in its own Keychain item. It is a
// separate refresh chain from Claude Code's, so the widget refreshing never
// rotates Claude Code's token out from under it, and Claude Code logging out or
// expiring no longer leaves the widget with "no login".

import Foundation
import CryptoKit
import Network

enum SignInError: Error, CustomStringConvertible {
    case listener(String), timedOut, cancelled, denied(String), stateMismatch, noCode, badResponse, save

    var description: String {
        switch self {
        case .listener(let m):  return "could not listen for the browser (\(m))"
        case .timedOut:         return "timed out waiting for the browser"
        case .cancelled:        return "cancelled"
        case .denied(let m):    return "claude.ai said: \(m)"
        case .stateMismatch:    return "state mismatch (ignored a stray redirect)"
        case .noCode:           return "no code in the redirect"
        case .badResponse:      return "no access token in the token response"
        case .save:             return "could not save the login to the Keychain"
        }
    }
}

enum OAuthFlow {
    static let authorizeBase = "https://claude.ai/oauth/authorize"
    // What a claude.ai (subscription) login needs. org:create_api_key is a Console
    // scope and makes the claude.ai authorize page refuse the request.
    static let scopes = "user:profile user:inference user:sessions:claude_code user:mcp_servers"

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 32 random bytes -> 43 url-safe chars (a valid PKCE verifier, also used as state).
    /// SystemRandomNumberGenerator is the OS CSPRNG on Apple platforms.
    static func randomToken(bytes: Int = 32) -> String {
        var g = SystemRandomNumberGenerator()
        return base64url(Data((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &g) }))
    }

    static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func redirectURI(port: UInt16) -> String { "http://localhost:\(port)/callback" }

    static func authorizeURL(port: UInt16, challenge: String, state: String) -> URL {
        var c = URLComponents(string: authorizeBase)!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: UsageClient.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI(port: port)),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return c.url!
    }

    struct Callback: Equatable { var code: String?; var state: String?; var error: String? }

    /// First line of an HTTP request -> the redirect's parameters, or nil for any
    /// path other than /callback (browsers also ask for /favicon.ico).
    static func parseRequestLine(_ line: String) -> Callback? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let c = URLComponents(string: "http://localhost" + parts[1]), c.path == "/callback"
        else { return nil }
        func q(_ n: String) -> String? {
            guard let v = c.queryItems?.first(where: { $0.name == n })?.value, !v.isEmpty else { return nil }
            return v
        }
        var code = q("code"), state = q("state")
        // the manual flow hands out "code#state"; accept that shape too
        if let cd = code, let h = cd.firstIndex(of: "#") {
            if state == nil { state = String(cd[cd.index(after: h)...]) }
            code = String(cd[..<h])
        }
        return Callback(code: code, state: state, error: q("error_description") ?? q("error"))
    }

    /// Token response -> a document in Claude Code's own credential shape, so the
    /// existing parser, refresh and write-back code handle it unchanged.
    static func credentialDocument(fromTokenResponse j: JSON, nowMs: Double) -> JSON? {
        guard let at = j.str("access_token") else { return nil }
        var o: JSON = [
            "accessToken": at,
            "expiresAt": NSNumber(value: Int64(nowMs + (j.num("expires_in") ?? 3600) * 1000)),
        ]
        if let r = j.str("refresh_token") { o["refreshToken"] = r }
        if let s = j.str("scope") { o["scopes"] = s.split(separator: " ").map(String.init) }
        var doc: JSON = ["claudeAiOauth": o]
        if let a = j.obj("account"), let e = a.str("email_address") ?? a.str("email") { doc["account"] = e }
        return doc
    }

    static func email(fromDocument d: JSON) -> String? { d.str("account") }
}

/// One-shot HTTP listener on the loopback interface (127.0.0.1 and ::1) for the
/// OAuth redirect. Everything runs on one serial queue.
final class CallbackServer: @unchecked Sendable {
    typealias Outcome = Result<OAuthFlow.Callback, Error>

    private let q = DispatchQueue(label: "com.kryptohead.claude-usage.signin")
    private var listener: NWListener?
    private var finished = false
    private var pending: Outcome?
    private var waiter: ((Outcome) -> Void)?

    /// Start listening on a free port and return it.
    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let l: NWListener
        do { l = try NWListener(using: params, on: .any) }
        catch { throw SignInError.listener("\(error)") }
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }

        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        return try await withCheckedThrowingContinuation { cont in
            l.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready:
                    if !once.done { once.done = true; cont.resume(returning: l.port?.rawValue ?? 0) }
                case .failed(let e):
                    if !once.done { once.done = true; cont.resume(throwing: SignInError.listener("\(e)")) }
                    else { self?.finish(.failure(SignInError.listener("\(e)"))) }
                case .cancelled:
                    if !once.done { once.done = true; cont.resume(throwing: SignInError.cancelled) }
                default: break
                }
            }
            l.start(queue: q)
        }
    }

    /// Wait for the browser to come back. Task cancellation stops the listener.
    func waitForCallback(timeout: TimeInterval) async throws -> OAuthFlow.Callback {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<OAuthFlow.Callback, Error>) in
                q.async {
                    if let p = self.pending { cont.resume(with: p); return }
                    self.waiter = { cont.resume(with: $0) }
                    self.q.asyncAfter(deadline: .now() + timeout) { self.finish(.failure(SignInError.timedOut)) }
                }
            }
        } onCancel: { self.cancel() }
    }

    func cancel() { q.async { self.finish(.failure(SignInError.cancelled)) } }

    /// On q only.
    private func finish(_ r: Outcome) {
        guard !finished else { return }
        finished = true
        listener?.cancel(); listener = nil
        if let w = waiter { waiter = nil; w(r) } else { pending = r }
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: q)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { c.cancel(); return }
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let first = text.components(separatedBy: "\r\n").first ?? ""
            guard !self.finished, let cb = OAuthFlow.parseRequestLine(first) else {
                Self.respond(c, status: "404 Not Found", html: ""); return
            }
            Self.respond(c, status: "200 OK", html: SignInPage.html(ok: cb.code != nil && cb.error == nil, error: cb.error))
            self.finish(.success(cb))
        }
    }

    private static func respond(_ c: NWConnection, status: String, html: String) {
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
                 + "Content-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }
}

/// The page the browser lands on after claude.ai redirects back. Both languages,
/// since it is rendered off the main thread and the browser is not the app.
enum SignInPage {
    static func html(ok: Bool, error: String?) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let title = ok ? "Signed in to Claude Usage" : "Sign-in did not finish"
        let zh = ok ? "Claude Usage 已登入，可以關閉這個分頁。" : "登入沒有完成，請回到 Claude Usage 再試一次。"
        let en = ok ? "You can close this tab." : "Go back to Claude Usage and try again."
        let detail = (error.map { "<p class=e>\(esc($0))</p>" }) ?? ""
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title>
        <style>body{font:15px -apple-system,system-ui,sans-serif;background:#1f1f1f;color:#eee;
        display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
        div{text-align:center}h1{font-size:20px;color:\(ok ? "#5fd38d" : "#ff6b6b")}.e{color:#aaa;font-size:13px}</style>
        </head><body><div><h1>\(title)</h1><p>\(en)</p><p>\(zh)</p>\(detail)</div></body></html>
        """
    }
}

/// The whole browser sign-in. Returns a credential document ready for the Keychain.
enum BrowserSignIn {
    static func run(client: UsageClient, timeout: TimeInterval = 300,
                    open: @escaping @Sendable (URL) -> Void) async throws -> JSON {
        let server = CallbackServer()
        let port = try await server.start()
        let verifier = OAuthFlow.randomToken(), state = OAuthFlow.randomToken()
        open(OAuthFlow.authorizeURL(port: port, challenge: OAuthFlow.challenge(for: verifier), state: state))

        let cb = try await server.waitForCallback(timeout: timeout)
        if let e = cb.error { throw SignInError.denied(e) }
        guard cb.state == state else { throw SignInError.stateMismatch }
        guard let code = cb.code else { throw SignInError.noCode }

        let j = try await client.exchangeCode(code, verifier: verifier,
                                              redirectURI: OAuthFlow.redirectURI(port: port), state: state)
        guard let doc = OAuthFlow.credentialDocument(fromTokenResponse: j, nowMs: Date().timeIntervalSince1970 * 1000)
        else { throw SignInError.badResponse }
        return doc
    }
}
