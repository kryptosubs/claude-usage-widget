// UsageCore.swift - Foundation-only logic: parsing the usage payload, money,
// countdowns, localisation. No AppKit here, so the test runner can compile it
// on its own.

import Foundation

// MARK: - Localisation

enum Lang: String, CaseIterable {
    case en, zh

    static var current: Lang = .en

    /// Traditional Chinese when the system prefers any Chinese variant, else English.
    static var systemDefault: Lang {
        let pref = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return pref.hasPrefix("zh") ? .zh : .en
    }

    var locale: Locale { Locale(identifier: self == .zh ? "zh_Hant_TW" : "en_US") }
    var displayName: String { self == .zh ? "繁體中文" : "English" }
}

/// Two-language string picker: T("Refresh now", "立即更新").
func T(_ en: String, _ zh: String) -> String { Lang.current == .zh ? zh : en }

// MARK: - Row model

struct UsageRow: Equatable, Identifiable {
    var id: String { key }
    var key: String          // stable id: session / weekly_all / weekly_scoped:Opus / spend
    var label: String        // long label (popover tooltip, diagnostics)
    var short: String        // compact label
    var percent: Double      // 0-100
    var resetsAt: Date?
    var literal: String?     // for the money row: shown instead of a countdown
    var severity: String
}

// MARK: - JSON helpers (the payload is undocumented, so read it loosely)

typealias JSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func obj(_ k: String) -> JSON? { self[k] as? JSON }
    func str(_ k: String) -> String? {
        if let s = self[k] as? String, !s.isEmpty { return s }
        return nil
    }
    func num(_ k: String) -> Double? {
        if let n = self[k] as? NSNumber { return n.doubleValue }
        if let d = self[k] as? Double { return d }
        if let i = self[k] as? Int { return Double(i) }
        if let s = self[k] as? String, let d = Double(s) { return d }
        return nil
    }
    func bool(_ k: String) -> Bool {
        if let b = self[k] as? Bool { return b }
        if let n = self[k] as? NSNumber { return n.intValue != 0 }
        return false
    }
}

// MARK: - Dates

enum ISODate {
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Accepts "2026-09-22T18:00:00Z", "+00:00" offsets, and any number of
    /// fractional digits (the API has sent 6; ISO8601DateFormatter chokes on those),
    /// and naive timestamps, which are treated as UTC.
    static func parse(_ s: String?) -> Date? {
        guard var t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if let r = t.range(of: #"\.\d+"#, options: .regularExpression) { t.removeSubrange(r) }
        if t.range(of: #"(Z|[+-]\d{2}:?\d{2})$"#, options: .regularExpression) == nil { t += "Z" }
        if let d = plain.date(from: t) { return d }
        // "+0000" without the colon
        if let r = t.range(of: #"([+-]\d{2})(\d{2})$"#, options: .regularExpression) {
            let off = String(t[r])
            t.replaceSubrange(r, with: String(off.prefix(3)) + ":" + String(off.suffix(2)))
            return plain.date(from: t)
        }
        return nil
    }
}

// MARK: - Formatting

enum Fmt {
    /// "2h13m  3:45 PM" (short) or "resets in 2h 13m (3:45 PM)" (long).
    static func countdown(_ t: Date?, now: Date = Date(), short: Bool,
                          timeZone: TimeZone = .current) -> String {
        guard let t = t else { return "" }
        let secs = t.timeIntervalSince(now)
        if secs <= 0 { return T("resetting", "重置中") }

        // round UP to the next whole minute so a countdown never reads low
        let mins = Int((secs / 60).rounded(.up))
        let d = mins / 1440, h = (mins % 1440) / 60, m = mins % 60
        let hTotal = mins / 60

        let rel: String
        if short {
            if mins >= 1440      { rel = T("\(d)d\(h)h", "\(d)天\(h)時") }
            else if mins >= 60   { rel = T("\(hTotal)h\(m)m", "\(hTotal)時\(m)分") }
            else                 { rel = T("\(m)m", "\(m)分") }
        } else {
            if mins >= 1440      { rel = T("resets in \(d)d \(h)h", "\(d) 天 \(h) 小時後重置") }
            else if mins >= 60   { rel = T("resets in \(hTotal)h \(m)m", "\(hTotal) 小時 \(m) 分後重置") }
            else                 { rel = T("resets in \(m)m", "\(m) 分鐘後重置") }
        }

        // ...plus the wall-clock time it lands on
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let f = DateFormatter()
        f.locale = Lang.current.locale
        f.timeZone = timeZone
        let today = cal.startOfDay(for: now)
        let day = cal.startOfDay(for: t)
        let days = cal.dateComponents([.day], from: today, to: day).day ?? 0
        // the compact form drops detail as the reset gets further away, so a
        // weekly row still fits the 224pt widget
        if days == 0      { f.setLocalizedDateFormatFromTemplate("jmm") }
        else if days < 7  { f.setLocalizedDateFormatFromTemplate(short ? "EEEj" : "EEEjmm") }
        else              { f.setLocalizedDateFormatFromTemplate(short ? "MMMd" : "MMMdj") }
        let abs = f.string(from: t)

        if short { return "\(rel)  \(abs)" }
        return Lang.current == .zh ? "\(rel)（\(abs)）" : "\(rel) (\(abs))"
    }

    static func clampExponent(_ e: Double?) -> Int {
        guard let e = e else { return 2 }
        let i = Int(e)
        return (0...6).contains(i) ? i : 2
    }

    /// Money arrives in MINOR units (cents) with an explicit exponent. Reading it
    /// raw overstates every amount 100x.
    static func fromMinor(_ v: Double?, exponent: Double?) -> Double? {
        guard let v = v else { return nil }
        return v / pow(10, Double(clampExponent(exponent)))
    }

    static func money(_ amount: Double, currency: String?, exponent: Double?) -> String {
        let e = clampExponent(exponent)
        let cur = (currency?.isEmpty == false ? currency! : "USD").uppercased()
        let sym: String
        switch cur {
        case "USD": sym = "$"
        case "EUR": sym = "€"
        case "GBP": sym = "£"
        case "JPY": sym = "¥"
        default:    sym = ""
        }
        let nf = NumberFormatter()
        nf.locale = Locale(identifier: "en_US")
        nf.numberStyle = .decimal
        nf.minimumFractionDigits = e
        nf.maximumFractionDigits = e
        let num = nf.string(from: NSNumber(value: amount)) ?? String(amount)
        return sym.isEmpty ? "\(num) \(cur)" : sym + num
    }

    /// 0 = green, 1 = amber, 2 = red. The server's own severity can raise it.
    static func rank(percent: Double, severity: String) -> Int {
        var r = percent >= 90 ? 2 : (percent >= 75 ? 1 : 0)
        switch severity.lowercased() {
        case "warn", "warning", "elevated", "medium": r = max(r, 1)
        case "critical", "severe", "high", "exceeded", "blocked", "locked": r = 2
        default: break
        }
        return r
    }
}

// MARK: - Payload -> rows

enum UsageParser {
    enum Scale: String { case auto, percent, fraction }
    static var scale: Scale = .auto

    static func toPercent(_ v: Double?) -> Double? {
        guard let v = v else { return nil }
        switch scale {
        case .percent:  return v
        case .fraction: return v * 100
        case .auto:
            // the API reports 0-100; a fractional value at or below 1 is a 0-1 ratio
            if v <= 1 && v != v.rounded(.down) { return v * 100 }
            return v
        }
    }

    static func scopeName(_ l: JSON) -> String? {
        guard let sc = l.obj("scope") else { return nil }
        if let m = sc.obj("model"), let n = m.str("display_name") { return n }
        if let s = sc.str("surface") { return s }
        if let s = sc.obj("surface"), let n = s.str("display_name") { return n }
        return nil
    }

    /// Prefer the `limits` array: unambiguous 0-100 percent, server-side severity,
    /// and new limit kinds appear without a code change. The payload also carries
    /// null placeholders under internal codenames; those are not in `limits`.
    static func rows(from d: JSON) -> [UsageRow] {
        var rows: [UsageRow] = []

        if let limits = d["limits"] as? [Any] {
            for case let l as JSON in limits {
                guard let pct = l.num("percent") else { continue }
                let kind = l.str("kind") ?? ""
                let resetStr = l.str("resets_at")
                let sev = l.str("severity") ?? ""

                // a scoped cap with no usage and no window has not kicked in - noise
                if kind == "weekly_scoped" && pct <= 0 && resetStr == nil { continue }

                var label: String, short: String, key = kind
                switch kind {
                case "session":
                    label = T("Session (5h)", "工作階段（5 小時）"); short = "5h"
                case "weekly_all":
                    label = T("Week (all models)", "本週（全部模型）"); short = "7d"
                case "weekly_scoped":
                    label = T("Week", "本週"); short = T("wk", "週")
                default:
                    label = kind.replacingOccurrences(of: "_", with: " ").capitalized
                    short = label
                }
                if kind == "weekly_scoped", let n = scopeName(l) {
                    label = T("Week - \(n)", "本週 · \(n)"); short = n; key = "weekly_scoped:\(n)"
                }
                rows.append(UsageRow(key: key, label: label, short: short, percent: pct,
                                     resetsAt: ISODate.parse(resetStr), literal: nil, severity: sev))
            }
        }

        if rows.isEmpty {
            let defs: [(String, String, String, String)] = [
                ("five_hour",        "session",           T("Session (5h)", "工作階段（5 小時）"), "5h"),
                ("seven_day",        "weekly_all",        T("Week (all models)", "本週（全部模型）"), "7d"),
                ("seven_day_opus",   "weekly_scoped:Opus", T("Week - Opus", "本週 · Opus"), "Opus"),
                ("seven_day_sonnet", "weekly_scoped:Sonnet", T("Week - Sonnet", "本週 · Sonnet"), "Sonnet"),
            ]
            for (field, key, label, short) in defs {
                guard let w = d.obj(field), let pct = toPercent(w.num("utilization")) else { continue }
                rows.append(UsageRow(key: key, label: label, short: short, percent: pct,
                                     resetsAt: ISODate.parse(w.str("resets_at")), literal: nil, severity: ""))
            }
        }

        if let s = spendRow(d) { rows.append(s) }
        return rows
    }

    /// Either the newer `spend` object (amount_minor / exponent) or the older
    /// `extra_usage` (used_credits / monthly_limit scaled by decimal_places).
    static func spendRow(_ d: JSON) -> UsageRow? {
        let label = T("Extra usage", "額外用量"), short = T("Extra", "額外")
        let perMonth = T("mo", "每月")

        if let sp = d.obj("spend"), sp.bool("enabled") {
            var exp: Double? = nil, cur: String? = nil, used: Double? = nil
            if let u = sp.obj("used") {
                exp = u.num("exponent"); cur = u.str("currency")
                used = Fmt.fromMinor(u.num("amount_minor"), exponent: exp)
            }
            var limit: Double? = nil
            if let lo = sp.obj("limit") {
                if exp == nil { exp = lo.num("exponent") }
                if cur == nil { cur = lo.str("currency") }
                limit = Fmt.fromMinor(lo.num("amount_minor"), exponent: exp)
            } else if let lv = sp.num("limit") {
                limit = Fmt.fromMinor(lv, exponent: exp)
            }
            var pct = sp.num("percent") ?? 0
            if sp.num("percent") == nil, let u = used, let l = limit, l > 0 { pct = u / l * 100 }
            return UsageRow(key: "spend", label: label, short: short, percent: pct, resetsAt: nil,
                            literal: moneyLine(used, limit, cur, exp, perMonth),
                            severity: sp.str("severity") ?? "")
        }

        if let e = d.obj("extra_usage"), e.bool("is_enabled") {
            let dp = e.num("decimal_places"), cur = e.str("currency")
            let used = Fmt.fromMinor(e.num("used_credits"), exponent: dp)
            let limit = Fmt.fromMinor(e.num("monthly_limit"), exponent: dp)
            var pct = toPercent(e.num("utilization")) ?? 0
            if e.num("utilization") == nil, let u = used, let l = limit, l > 0 { pct = u / l * 100 }
            return UsageRow(key: "spend", label: label, short: short, percent: pct, resetsAt: nil,
                            literal: moneyLine(used, limit, cur, dp, perMonth), severity: "")
        }
        return nil
    }

    private static func moneyLine(_ used: Double?, _ limit: Double?, _ cur: String?,
                                  _ exp: Double?, _ perMonth: String) -> String {
        if let u = used, let l = limit {
            return "\(Fmt.money(u, currency: cur, exponent: exp)) / \(Fmt.money(l, currency: cur, exponent: exp)) \(perMonth)"
        }
        if let u = used { return T("\(Fmt.money(u, currency: cur, exponent: exp)) used", "已用 \(Fmt.money(u, currency: cur, exponent: exp))") }
        return T("extra usage", "額外用量")
    }

    /// The profile payload is undocumented too, so dig for an email.
    static func email(fromProfile p: JSON?) -> String? {
        guard let p = p else { return nil }
        for k in ["email", "email_address"] { if let v = p.str(k) { return v } }
        for o in ["account", "user", "organization"] {
            if let sub = p.obj(o) {
                for k in ["email", "email_address", "name"] { if let v = sub.str(k) { return v } }
            }
        }
        return nil
    }
}
