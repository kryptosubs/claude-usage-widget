// App.swift - menu-bar item, popover, optional floating widget.

import AppKit
import SwiftUI
import ServiceManagement

// MARK: - settings

enum MenuMetric: String, CaseIterable {
    case session, week, highest
    var title: String {
        switch self {
        case .session: return T("5-hour session", "5 小時工作階段")
        case .week:    return T("Weekly (all models)", "每週（全部模型）")
        case .highest: return T("Whichever is highest", "取最高者")
        }
    }
}

final class Settings {
    static let d = UserDefaults.standard
    static var lang: Lang {
        get { Lang(rawValue: d.string(forKey: "lang") ?? "") ?? Lang.systemDefault }
        set { d.set(newValue.rawValue, forKey: "lang") }
    }
    static var metric: MenuMetric {
        get { MenuMetric(rawValue: d.string(forKey: "metric") ?? "") ?? .session }
        set { d.set(newValue.rawValue, forKey: "metric") }
    }
    static var showWidget: Bool {
        get { d.bool(forKey: "showWidget") }
        set { d.set(newValue, forKey: "showWidget") }
    }
    static var widgetOrigin: NSPoint? {
        get {
            guard d.object(forKey: "widgetX") != nil else { return nil }
            return NSPoint(x: d.double(forKey: "widgetX"), y: d.double(forKey: "widgetY"))
        }
        set {
            if let p = newValue { d.set(p.x, forKey: "widgetX"); d.set(p.y, forKey: "widgetY") }
            else { d.removeObject(forKey: "widgetX"); d.removeObject(forKey: "widgetY") }
        }
    }
    /// Floating card stays above other apps' windows (default on, like Windows).
    static var widgetOnTop: Bool {
        get { d.object(forKey: "widgetOnTop") == nil ? true : d.bool(forKey: "widgetOnTop") }
        set { d.set(newValue, forKey: "widgetOnTop") }
    }
    static var launchedBefore: Bool {
        get { d.bool(forKey: "launchedBefore") }
        set { d.set(newValue, forKey: "launchedBefore") }
    }
    static var widgetOpacity: Double {
        get { d.object(forKey: "opacity") == nil ? 0.95 : d.double(forKey: "opacity") }
        set { d.set(newValue, forKey: "opacity") }
    }
}

// MARK: - model

enum Status: Equatable {
    case loading, live, ago(Int), stale, auth, throttled, offline, noToken
    var text: String {
        switch self {
        case .loading:     return T("loading", "載入中")
        case .live:        return T("live", "即時")
        case .ago(let m):  return T("\(m)m ago", "\(m) 分鐘前")
        case .stale:       return T("stale", "過時")
        case .auth:        return T("auth", "需登入")
        case .throttled:   return T("throttled", "限流中")
        case .offline:     return T("offline", "離線")
        case .noToken:     return T("no login", "未登入")
        }
    }
    var color: Color {
        switch self {
        case .live: return Palette.green
        case .stale, .throttled, .offline: return Palette.amber
        case .auth, .noToken: return Palette.red
        default: return Palette.dim
        }
    }
}

@MainActor
final class UsageModel: ObservableObject {
    @Published var data: JSON?
    @Published var account: String?
    @Published var status: Status = .loading
    @Published var hint: String?
    @Published var now = Date()
    @Published var lang: Lang = Settings.lang

    let store = MacCredentialStore()
    lazy var client = UsageClient(store: store)

    var refreshSeconds: Double = 180      // no faster: the endpoint rate-limits hard
    private var backoff = 0
    private var nextFetch = Date.distantPast
    private var lastOk: Date?
    private var fetching = false
    private var timer: Timer?
    var onChange: (@MainActor () -> Void)?

    var rows: [UsageRow] { data.map(UsageParser.rows(from:)) ?? [] }

    func start() {
        Lang.current = lang
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    func setLang(_ l: Lang) {
        lang = l; Lang.current = l; Settings.lang = l
        updateStatusAge(); onChange?()
    }

    func refreshNow() { backoff = 0; nextFetch = .distantPast; tick() }

    private func tick() {
        now = Date()
        if now >= nextFetch && !fetching { fetching = true; Task { await fetch() } }
        updateStatusAge()
        onChange?()
    }

    private func updateStatusAge() {
        guard let ok = lastOk else { return }
        switch status {
        case .live, .ago, .stale:
            let age = Int(now.timeIntervalSince(ok))
            status = age < 90 ? .live : (age < 600 ? .ago(age / 60) : .stale)
        default: break
        }
    }

    func fetch() async {
        fetching = true
        defer {
            fetching = false
            nextFetch = Date().addingTimeInterval(refreshSeconds * pow(2, Double(backoff)))
            onChange?()
        }
        do {
            let u = try await client.usage()
            data = u; lastOk = Date(); backoff = 0; hint = nil; status = .live
            if account == nil, let p = try? await client.profile() {
                account = UsageParser.email(fromProfile: p)   // cosmetic; never blocks usage
            }
        } catch let e as UsageError {
            switch e {
            case .noToken:
                status = .noToken
                hint = T("No Claude Code login found. Run `claude` in Terminal and /login.",
                         "找不到 Claude Code 登入。請在終端機執行 `claude` 並 /login。")
                backoff = 4
                return
            default: break
            }
            switch e.status {
            case 401, 403:
                account = nil; status = .auth
                hint = T("Login expired - run /login in Claude Code.",
                         "登入已過期，請在 Claude Code 執行 /login。")
            case 429:
                status = .throttled
                hint = T("Rate limited - backing off.", "請求過於頻繁，稍後重試。")
            default:
                status = .offline
                var msg = e.description
                if let r = await client.lastRefreshError { msg += " / refresh: \(r)" }
                hint = T("Fetch failed (\(msg))", "讀取失敗（\(msg)）")
            }
            backoff = min(5, backoff + 1)      // 180s -> up to ~96 min
        } catch {
            status = .offline
            hint = "\(error)"
            backoff = min(5, backoff + 1)
        }
    }

    /// The number shown in the menu bar.
    func menuValue() -> (percent: Double, severity: String)? {
        let r = rows.filter { $0.literal == nil }
        switch Settings.metric {
        case .session: if let x = r.first(where: { $0.key == "session" }) { return (x.percent, x.severity) }
        case .week:    if let x = r.first(where: { $0.key == "weekly_all" }) { return (x.percent, x.severity) }
        case .highest: if let x = r.max(by: { $0.percent < $1.percent }) { return (x.percent, x.severity) }
        }
        return r.first.map { ($0.percent, $0.severity) }
    }
}

// MARK: - look

enum Palette {
    static let card   = Color(red: 0.106, green: 0.106, blue: 0.122)
    static let track  = Color.white.opacity(0.08)
    static let text   = Color(red: 0.85, green: 0.85, blue: 0.88)
    static let dim    = Color(red: 0.60, green: 0.60, blue: 0.65)
    static let green  = Color(red: 0.29, green: 0.87, blue: 0.50)
    static let amber  = Color(red: 0.98, green: 0.75, blue: 0.14)
    static let red    = Color(red: 0.97, green: 0.44, blue: 0.44)
    static func bar(_ rank: Int) -> Color { rank >= 2 ? red : (rank == 1 ? amber : green) }
    static func nsBar(_ rank: Int) -> NSColor {
        rank >= 2 ? NSColor(red: 0.97, green: 0.44, blue: 0.44, alpha: 1)
            : rank == 1 ? NSColor(red: 0.98, green: 0.75, blue: 0.14, alpha: 1)
            : NSColor(red: 0.29, green: 0.87, blue: 0.50, alpha: 1)
    }
}

/// Label, percent and reset on ONE line with the bar painted behind them -
/// the same compact row as the Windows widget.
struct RowView: View {
    let row: UsageRow
    let now: Date
    let compact: Bool

    var body: some View {
        let p = max(0, min(100, row.percent))
        let rank = Fmt.rank(percent: p, severity: row.severity)
        let reset = row.literal ?? Fmt.countdown(row.resetsAt, now: now, short: compact)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4).fill(Palette.track)
            GeometryReader { g in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Palette.bar(rank).opacity(0.35))
                    .frame(width: max(2, g.size.width * p / 100))
            }
            HStack(spacing: 6) {
                Text(compact ? row.short : row.label).foregroundColor(Palette.text)
                Text(String(format: "%.0f%%", row.percent)).fontWeight(.semibold).foregroundColor(.white)
                Spacer(minLength: 4)
                Text(reset).font(.system(size: compact ? 10 : 11)).foregroundColor(Palette.dim)
                    .lineLimit(1).truncationMode(.tail)
            }
            .font(.system(size: compact ? 11 : 12))
            .padding(.horizontal, 7)
        }
        .frame(height: compact ? 18 : 22)
        .help("\(row.label) - \(reset)")
    }
}

struct UsageCard: View {
    @ObservedObject var model: UsageModel
    let compact: Bool
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            HStack(spacing: 6) {
                Text(model.account ?? "Claude Usage")
                    .font(.system(size: compact ? 10 : 11)).foregroundColor(Palette.dim)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(model.status.text).font(.system(size: compact ? 9 : 10)).foregroundColor(model.status.color)
                if let close = onClose {
                    Button(action: close) {
                        Text("✕").font(.system(size: 10)).foregroundColor(Palette.dim)
                    }
                    .buttonStyle(.plain)
                    .help(T("Hide widget", "隱藏小工具"))
                }
            }
            .padding(.bottom, 2)

            let rows = model.rows
            if rows.isEmpty {
                Text(model.data == nil ? T("Loading…", "載入中…") : T("No usage windows reported.", "沒有回報任何用量。"))
                    .font(.system(size: 11)).foregroundColor(Palette.text)
            }
            ForEach(rows) { r in RowView(row: r, now: model.now, compact: compact) }

            if let h = model.hint {
                Text(h).font(.system(size: 9.5)).foregroundColor(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10).padding(.top, 7).padding(.bottom, 8)
        .frame(width: compact ? 224 : 372, alignment: .leading)
    }
}

struct PopoverView: View {
    @ObservedObject var model: UsageModel
    let app: AppDelegate
    var inWindow = false

    var body: some View {
        VStack(spacing: 0) {
            UsageCard(model: model, compact: false)
            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 14) {
                Button(T("Refresh", "更新")) { model.refreshNow() }
                Button(app.widgetVisible ? T("Hide widget", "隱藏小工具") : T("Show widget", "顯示小工具")) {
                    app.toggleWidget()
                }
                if !inWindow {
                    Button(T("Open in window", "開成視窗")) { app.openDetailWindow() }
                }
                Spacer()
                Menu {
                    Picker(T("Menu bar shows", "選單列顯示"), selection: Binding(
                        get: { Settings.metric }, set: { Settings.metric = $0; app.updateStatusItem() })) {
                        ForEach(MenuMetric.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker(T("Language", "語言"), selection: Binding(
                        get: { model.lang }, set: { model.setLang($0) })) {
                        ForEach(Lang.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Toggle(T("Keep on top", "保持在最上層"), isOn: Binding(
                        get: { Settings.widgetOnTop }, set: { app.setWidgetOnTop($0) }))
                    Toggle(T("Open at login", "開機登入時啟動"), isOn: Binding(
                        get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
                    Divider()
                    Button(T("Copy diagnostics", "複製診斷資訊")) { app.copyDiagnostics() }
                    Button(T("Quit", "結束")) { NSApp.terminate(nil) }
                } label: { Image(systemName: "gearshape") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundColor(Palette.text)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(Palette.card)
    }
}

struct WidgetView: View {
    @ObservedObject var model: UsageModel
    let app: AppDelegate
    var body: some View {
        UsageCard(model: model, compact: true, onClose: { app.toggleWidget() })
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card.opacity(0.95)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.15), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            // Drag anywhere on the card to move it. SwiftUI's hosting view swallows the
            // mouse-down that isMovableByWindowBackground relies on, so the window is
            // moved by hand, from the global mouse position (the view's own coordinate
            // space moves with the window and would make the drag jitter).
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { _ in app.dragWidget() }
                .onEnded { _ in app.endWidgetDrag() })
            .contextMenu {
                Button(T("Refresh now", "立即更新")) { model.refreshNow() }
                Toggle(T("Keep on top", "保持在最上層"), isOn: Binding(
                    get: { Settings.widgetOnTop }, set: { app.setWidgetOnTop($0) }))
                Toggle(T("Open at login", "開機登入時啟動"), isOn: Binding(
                    get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
                Button(T("Toggle transparency", "切換透明度")) { app.toggleOpacity() }
                Button(T("Hide widget", "隱藏小工具")) { app.toggleWidget() }
                Divider()
                Button(T("Quit", "結束")) { NSApp.terminate(nil) }
            }
    }
}

// MARK: - floating panel

final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    /// When "Keep on top" is off the card is an ordinary window: clicking it brings
    /// it forward, and other apps' windows can cover it again.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown { orderFrontRegardless() }
        super.sendEvent(event)
    }
}

// MARK: - app delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    let model = UsageModel()
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var panel: WidgetPanel?
    var hosting: NSHostingView<WidgetView>?
    var widgetVisible: Bool { panel?.isVisible ?? false }
    private var popoverMonitor: Any?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(togglePopover(_:))
            b.imagePosition = .imageLeading
        }

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model, app: self))

        model.onChange = { [weak self] in self?.updateStatusItem(); self?.fitPanel() }
        model.start()
        updateStatusItem()

        // A second launch (Finder, Spotlight, Launchpad) asks this instance to show itself.
        DistributedNotificationCenter.default().addObserver(
            forName: Main.showNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reveal() }
        }

        // A menu-bar-only app gives no sign of life on its own, and the menu bar may
        // hide the item (too many icons, or System Settings > Menu Bar). So the first
        // launch always shows the floating card, and so does any launch where the
        // menu-bar item turns out not to be on screen.
        let first = !Settings.launchedBefore
        Settings.launchedBefore = true
        if Settings.showWidget || first { showWidget() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            Log.write("launched; status item on screen: \(self.statusItemOnScreen)")
            if !self.statusItemOnScreen && !self.widgetVisible { self.showWidget() }
        }
    }

    /// Double-clicking the app while it is already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reveal()
        return false
    }

    /// Whether the menu-bar item is actually visible, not just created.
    var statusItemOnScreen: Bool {
        guard statusItem.isVisible, let w = statusItem.button?.window else { return false }
        guard w.occlusionState.contains(.visible) else { return false }
        return NSScreen.screens.contains { $0.frame.intersects(w.frame) }
    }

    /// Show something: the popover under the menu-bar item if it is visible,
    /// otherwise the floating card.
    func reveal() {
        Log.write("reveal; status item on screen: \(statusItemOnScreen)")
        if statusItemOnScreen, let b = statusItem.button {
            NSApp.activate(ignoringOtherApps: true)
            if !popover.isShown { popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY) }
            popover.contentViewController?.view.window?.makeKey()
        } else {
            showWidget()
        }
    }

    // --- menu bar

    func updateStatusItem() {
        guard let b = statusItem?.button else { return }
        let v = model.menuValue()
        let rank = v.map { Fmt.rank(percent: $0.percent, severity: $0.severity) } ?? -1
        b.image = Self.gauge(percent: v?.percent ?? 0, rank: rank)
        let title = v.map { String(format: " %.0f%%", $0.percent) } ?? " –"
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        ])
        var tip = "Claude Usage"
        for r in model.rows where r.literal == nil { tip += "\n\(r.label)  \(Int(r.percent.rounded()))%" }
        b.toolTip = tip
    }

    /// A small ring gauge: grey track, arc in green / amber / red.
    static func gauge(percent: Double, rank: Int) -> NSImage {
        let size = NSSize(width: 15, height: 15)
        let img = NSImage(size: size, flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY), r: CGFloat = 5.5
            let track = NSBezierPath()
            track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
            track.lineWidth = 2.4
            NSColor.labelColor.withAlphaComponent(0.25).setStroke()
            track.stroke()
            if rank >= 0 {
                let p = max(0.02, min(1, percent / 100))
                let arc = NSBezierPath()
                arc.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - 360 * p, clockwise: true)
                arc.lineWidth = 2.4
                arc.lineCapStyle = .round
                Palette.nsBar(rank).setStroke()
                arc.stroke()
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    @objc func togglePopover(_ sender: Any?) {
        guard let b = statusItem.button else { return }
        if popover.isShown { popover.performClose(sender); return }
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // --- detail window
    //
    // v1.2.3 let the popover detach into AppKit's default detached window. That
    // window has no title bar, and the SwiftUI content claims every mouse-down,
    // so after the tear-off drag it could never be moved again. The detail view
    // now tears off into (or opens as) an ordinary titled window instead, which
    // moves by its title bar like any other app's window and remembers its frame.

    private var detailWindow: NSWindow?

    func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }

    func detachableWindow(for popover: NSPopover) -> NSWindow? {
        Log.write("popover torn off into the detail window")
        return makeDetailWindow()
    }

    func openDetailWindow() {
        popover.performClose(nil)
        let w = makeDetailWindow()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        Log.write("detail window opened")
    }

    private func makeDetailWindow() -> NSWindow {
        if let w = detailWindow { return w }
        let host = NSHostingController(rootView: PopoverView(model: model, app: self, inWindow: true))
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.title = "Claude Usage"
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.level = Settings.widgetOnTop ? .floating : .normal
        w.collectionBehavior.insert(.canJoinAllSpaces)
        if !w.setFrameUsingName("ClaudeUsageDetail") { w.center() }
        w.setFrameAutosaveName("ClaudeUsageDetail")
        detailWindow = w
        return w
    }

    // --- floating widget

    func toggleWidget() {
        if widgetVisible { panel?.orderOut(nil); Settings.showWidget = false }
        else { showWidget() }
        popover.performClose(nil)
    }

    func showWidget() {
        if panel == nil {
            let p = WidgetPanel(contentRect: NSRect(x: 0, y: 0, width: 224, height: 100),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            p.level = Settings.widgetOnTop ? .floating : .normal
            p.isFloatingPanel = Settings.widgetOnTop
            p.hidesOnDeactivate = false
            p.isMovableByWindowBackground = false      // moved by dragWidget() instead
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.alphaValue = Settings.widgetOpacity
            p.delegate = self
            let h = NSHostingView(rootView: WidgetView(model: model, app: self))
            p.contentView = h
            hosting = h
            panel = p
            fitPanel()
            if let o = Settings.widgetOrigin, NSScreen.screens.contains(where: { $0.visibleFrame.contains(o) }) {
                p.setFrameOrigin(o)
            } else if let s = NSScreen.main?.visibleFrame {
                p.setFrameTopLeftPoint(NSPoint(x: s.maxX - 244, y: s.maxY - 20))
            }
        }
        panel?.orderFrontRegardless()
        Settings.showWidget = true
    }

    /// Resize to the SwiftUI content, keeping the top-left corner where it is.
    func fitPanel() {
        guard let p = panel, let h = hosting else { return }
        let size = h.fittingSize
        guard size.height > 0, abs(size.height - p.frame.height) > 0.5 || abs(size.width - p.frame.width) > 0.5 else { return }
        let top = p.frame.maxY
        p.setFrame(NSRect(x: p.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    private var dragAnchor: (mouse: NSPoint, origin: NSPoint)?

    func dragWidget() {
        guard let p = panel else { return }
        let m = NSEvent.mouseLocation
        if dragAnchor == nil { dragAnchor = (m, p.frame.origin) }
        guard let a = dragAnchor else { return }
        p.setFrameOrigin(NSPoint(x: a.origin.x + m.x - a.mouse.x, y: a.origin.y + m.y - a.mouse.y))
    }

    func endWidgetDrag() {
        dragAnchor = nil
        if let p = panel { Settings.widgetOrigin = p.frame.origin }
        Log.write("widget moved to \(panel.map { NSStringFromPoint($0.frame.origin) } ?? "-")")
    }

    func setWidgetOnTop(_ on: Bool) {
        Settings.widgetOnTop = on
        panel?.level = on ? .floating : .normal
        panel?.isFloatingPanel = on
        panel?.orderFrontRegardless()
        detailWindow?.level = on ? .floating : .normal
        Log.write("widget on top: \(on)")
    }

    func toggleOpacity() {
        let v = (panel?.alphaValue ?? 1) > 0.8 ? 0.62 : 0.95
        panel?.alphaValue = v
        Settings.widgetOpacity = v
    }

    func windowDidMove(_ note: Notification) {
        if let p = panel { Settings.widgetOrigin = p.frame.origin }
    }

    // --- misc

    // Open at login: SMAppService first (shows up under System Settings > General >
    // Login Items). An ad-hoc-signed build can be refused by it, so the fallback is a
    // plain LaunchAgent in ~/Library/LaunchAgents, which needs no signature at all.
    static let agentURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.kryptohead.claude-usage.plist")

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled || FileManager.default.fileExists(atPath: Self.agentURL.path)
    }

    func setLaunchAtLogin(_ on: Bool) {
        if on {
            do {
                try SMAppService.mainApp.register()
                Log.write("open at login: SMAppService registered")
            } catch {
                Log.write("open at login: SMAppService refused (\(error.localizedDescription)); using LaunchAgent")
                if !writeLaunchAgent() {
                    let a = NSAlert()
                    a.messageText = T("Could not turn on Open at Login", "無法開啟「開機登入時啟動」")
                    a.informativeText = T("Add Claude Usage in System Settings > General > Login Items.",
                                          "請在 System Settings > General > Login Items 手動加入 Claude Usage。")
                    a.runModal()
                }
            }
        } else {
            try? SMAppService.mainApp.unregister()
            try? FileManager.default.removeItem(at: Self.agentURL)
            Log.write("open at login: off")
        }
    }

    private func writeLaunchAgent() -> Bool {
        guard let exe = Bundle.main.executablePath else { return false }
        let plist: [String: Any] = [
            "Label": "com.kryptohead.claude-usage",
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        do {
            try FileManager.default.createDirectory(at: Self.agentURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: Self.agentURL, options: .atomic)
            Log.write("open at login: LaunchAgent written")
            return true
        } catch {
            Log.write("open at login: LaunchAgent failed (\(error.localizedDescription))")
            return false
        }
    }

    func copyDiagnostics() {
        popover.performClose(nil)
        let client = model.client, store = model.store
        Task {
            let text = await Diagnostics.report(client: client, store: store)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let a = NSAlert()
            a.messageText = T("Diagnostics copied to the clipboard", "診斷資訊已複製到剪貼簿")
            a.informativeText = String(text.prefix(900))
            a.runModal()
        }
    }
}

// MARK: - entry point

/// Tiny append-only log: ~/Library/Logs/ClaudeUsage.log (no tokens ever go here).
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ClaudeUsage.log")
    static func write(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}

@main
@MainActor
enum Main {
    static let showNotification = Notification.Name("com.kryptohead.claude-usage.show")
    static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            Lang.current = .en
            let store = MacCredentialStore()
            let client = UsageClient(store: store)
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                print(await Diagnostics.report(client: client, store: store))
                sem.signal()
            }
            sem.wait()
            exit(0)
        }
        if CommandLine.arguments.contains("--check-login-item") {
            // Round-trips Open at Login and leaves it off: proves the toggle works here.
            let d = AppDelegate()
            d.setLaunchAtLogin(true)
            print("after on:  smapp=\(SMAppService.mainApp.status.rawValue) agent=\(FileManager.default.fileExists(atPath: AppDelegate.agentURL.path)) -> \(d.launchAtLogin)")
            d.setLaunchAtLogin(false)
            print("after off: smapp=\(SMAppService.mainApp.status.rawValue) agent=\(FileManager.default.fileExists(atPath: AppDelegate.agentURL.path)) -> \(d.launchAtLogin)")
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            snapshot(to: CommandLine.arguments[i + 1]); exit(0)
        }
        // One instance only: a second launch hands over to the running one and quits.
        let me = ProcessInfo.processInfo.processIdentifier
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != me }) {
            Log.write("already running; asking it to show itself")
            DistributedNotificationCenter.default().postNotificationName(
                showNotification, object: nil, userInfo: nil, deliverImmediately: true)
            exit(0)
        }
        Log.write("starting \(Bundle.main.bundlePath)")
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)     // menu-bar only: no Dock icon
        withExtendedLifetime(delegate) { app.run() }
    }

    /// --snapshot <dir>: fetch once and render the popover and widget to PNGs
    /// (both languages). Used to check the layout without clicking the menu bar.
    static func snapshot(to dir: String) {
        _ = NSApplication.shared
        let model = UsageModel()
        let done = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var payload: JSON?; var email: String? }
        let box = Box()
        let client = model.client
        Task.detached {
            box.payload = try? await client.usage()
            box.email = (try? await client.profile()).flatMap { UsageParser.email(fromProfile: $0) }
            done.signal()
        }
        done.wait()
        model.data = box.payload; model.account = box.email; model.status = box.payload == nil ? .offline : .live
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let delegate = AppDelegate()
        for lang in Lang.allCases {
            Lang.current = lang; model.lang = lang
            let views: [(String, AnyView)] = [
                ("popover", AnyView(PopoverView(model: model, app: delegate).environment(\.colorScheme, .dark))),
                ("widget", AnyView(WidgetView(model: model, app: delegate).padding(8))),
            ]
            for (name, v) in views {
                let r = ImageRenderer(content: v)
                r.scale = 2
                if let cg = r.cgImage {
                    let rep = NSBitmapImageRep(cgImage: cg)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: "\(dir)/\(name)-\(lang.rawValue).png"))
                }
            }
        }
        print("snapshots written to \(dir)")
    }
}
