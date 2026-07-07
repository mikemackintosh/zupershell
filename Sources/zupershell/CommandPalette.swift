import AppKit
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// Command Palette — ⌘K anywhere in the app opens a Spotlight-style floating
// panel. Two things it can do:
//   1. Focus any existing session (fuzzy match against title / cwd / cmd).
//   2. "Run <query> in new window" — spawn a new SessionWindow and inject
//      the query as a command into that shell.
//
// Same visual family as Overview / Preferences: theme.background, theme.accent
// tint, dark appearance. Kept small — reuses AppDelegateBridge for lookup and
// SessionsRegistry for the session list.
// ─────────────────────────────────────────────────────────────────────────────

/// Item shown in the palette result list.
enum PaletteItem: Identifiable, Equatable {
    case runInNewWindow(String)             // command text
    case focusSession(SessionSummary)
    case settingAction(SettingAction)

    var id: String {
        switch self {
        case .runInNewWindow(let cmd): return "run:\(cmd)"
        case .focusSession(let s):     return "sess:\(s.id)"
        case .settingAction(let a):    return "set:\(a.id)"
        }
    }
    static func == (l: PaletteItem, r: PaletteItem) -> Bool { l.id == r.id }
}

/// One user-invokable settings action shown in the palette. Kept simple:
/// a title, an optional trailing status ("ON" / current value), a search
/// keyword blob, and an apply closure that mutates SettingsStore.
struct SettingAction: Identifiable {
    let id: String
    let title: String
    let status: String?        // e.g. "ON" / "OFF" / current value
    let keywords: String       // extra tokens the fuzzy matcher can hit
    let apply: () -> Void

    /// Enumerated on every palette render so status text (ON/OFF, current
    /// theme, etc.) reflects the live SettingsStore state.
    static func all() -> [SettingAction] {
        let store = SettingsStore.shared
        var actions: [SettingAction] = []

        func toggle(_ id: String, _ title: String,
                    _ get: @escaping (Settings) -> Bool,
                    _ set: @escaping (inout Settings, Bool) -> Void,
                    _ keywords: String = "") {
            let on = get(store.current)
            actions.append(SettingAction(
                id: id, title: title,
                status: on ? "ON" : "OFF",
                keywords: "toggle \(title.lowercased()) \(keywords)",
                apply: {
                    var s = store.current; set(&s, !get(s)); store.save(s)
                }))
        }

        // Boolean toggles — cover every switch in Preferences.
        toggle("glow",         "Toggle Window Glow",
               { $0.windowGlowEnabled }, { $0.windowGlowEnabled = $1 },
               "border tint accent")
        toggle("thinStrokes",  "Toggle Thin Strokes",
               { $0.thinStrokes }, { $0.thinStrokes = $1 },
               "font smoothing retina")
        toggle("brightColors", "Toggle Bright Colors for Bold",
               { $0.useBrightColors }, { $0.useBrightColors = $1 },
               "bold ansi")
        toggle("dragAnywhere", "Toggle Cmd-Drag Window Anywhere",
               { $0.dragWithCmdClick }, { $0.dragWithCmdClick = $1 },
               "move window")
        toggle("rememberFrame","Toggle Remember Window Position",
               { $0.rememberWindowFrame }, { $0.rememberWindowFrame = $1 },
               "save size")
        toggle("compact",      "Toggle Compact Overview",
               { $0.overviewCompact }, { $0.overviewCompact = $1 },
               "sessions dense")
        toggle("idleNotify",   "Toggle Long-Idle Notifications",
               { $0.idleNotifyEnabled }, { $0.idleNotifyEnabled = $1 },
               "alert notification")
        toggle("clipWrite",    "Toggle Programmatic Clipboard Writes (OSC 52)",
               { $0.clipboardWriteAllowed }, { $0.clipboardWriteAllowed = $1 },
               "security paste")

        // Themes — one entry per available theme; status = ✓ on current.
        let current = store.current.themeName
        for t in Themes.all {
            let title = "Theme: \(t.name)"
            let selected = (t.name == current)
            actions.append(SettingAction(
                id: "theme:\(t.name)", title: title,
                status: selected ? "✓" : nil,
                keywords: "theme color palette \(t.name.lowercased())",
                apply: { var s = store.current; s.themeName = t.name; store.save(s) }))
        }

        // Cursor styles — same pattern.
        let cursorLabels: [(String, String)] = [
            ("steadyBlock",     "Block"),
            ("blinkBlock",      "Block (blinking)"),
            ("steadyUnderline", "Underline"),
            ("blinkUnderline",  "Underline (blinking)"),
            ("steadyBar",       "Bar"),
            ("blinkBar",        "Bar (blinking)"),
        ]
        for (key, label) in cursorLabels {
            let selected = (store.current.cursorStyle == key)
            actions.append(SettingAction(
                id: "cursor:\(key)", title: "Cursor: \(label)",
                status: selected ? "✓" : nil,
                keywords: "cursor caret \(label.lowercased())",
                apply: { var s = store.current; s.cursorStyle = key; store.save(s) }))
        }

        // Font-size shortcuts.
        actions.append(SettingAction(
            id: "zoomIn", title: "Zoom In",
            status: "\(Int(store.current.fontSize + 1)) pt",
            keywords: "font bigger larger increase",
            apply: {
                var s = store.current; s.fontSize = min(24, s.fontSize + 1); store.save(s)
            }))
        actions.append(SettingAction(
            id: "zoomOut", title: "Zoom Out",
            status: "\(Int(store.current.fontSize - 1)) pt",
            keywords: "font smaller decrease",
            apply: {
                var s = store.current; s.fontSize = max(9, s.fontSize - 1); store.save(s)
            }))
        actions.append(SettingAction(
            id: "zoomReset", title: "Reset Font Size",
            status: "13 pt",
            keywords: "font default",
            apply: { var s = store.current; s.fontSize = 13; store.save(s) }))

        // Non-toggle actions that need the palette too.
        actions.append(SettingAction(
            id: "openPrefs", title: "Open Preferences…",
            status: nil,
            keywords: "settings config",
            apply: { PreferencesWindowController.shared.showPreferences(nil) }))
        actions.append(SettingAction(
            id: "openOverview", title: "Open Sessions Overview…",
            status: nil,
            keywords: "sessions list",
            apply: { OverviewWindowController.shared.showOverview(nil) }))

        return actions
    }
}

@available(macOS 13, *)
struct PaletteView: View {
    @ObservedObject var registry: SessionsRegistry
    @ObservedObject var themeObs: ThemeObservable
    @State private var query: String = ""
    @State private var selection: Int = 0
    /// Injected by the controller so the view can dismiss itself without
    /// needing a reference to the NSWindow.
    var onDismiss: () -> Void
    /// Called with the picked item; the controller handles focusing /
    /// spawning and then dismisses.
    var onAction: (PaletteItem) -> Void

    private var theme: Theme { themeObs.theme }

    private var items: [PaletteItem] {
        var out: [PaletteItem] = []
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()

        // 1) Sessions matching the query (highest priority — the common case).
        let sessions = registry.summaries.sorted { a, b in
            if a.pendingAttention != b.pendingAttention { return a.pendingAttention }
            if a.isRunning != b.isRunning { return a.isRunning }
            return a.lastActivity > b.lastActivity
        }
        let sessionMatches: [SessionSummary]
        if q.isEmpty {
            sessionMatches = sessions
        } else {
            sessionMatches = sessions.filter { s in
                PaletteView.matches(q, in: [
                    s.title, s.cwd, s.currentCommand ?? "", s.lastCommand ?? ""
                ].joined(separator: " ").lowercased())
            }
        }
        out.append(contentsOf: sessionMatches.map(PaletteItem.focusSession))

        // 2) "Run in new window" is ABOVE settings — a plain typed command
        // is more often a "just run this" than a "reach into config" intent.
        if !q.isEmpty { out.append(.runInNewWindow(q)) }

        // 3) Settings actions (only when a query is typed).
        if !q.isEmpty {
            for a in SettingAction.all() {
                if PaletteView.matches(q, in: (a.title + " " + a.keywords).lowercased()) {
                    out.append(.settingAction(a))
                }
            }
        }

        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.dim)
                PaletteFocusedField(text: $query,
                                    onSubmit: { activate() },
                                    onCancel: { onDismiss() },
                                    onArrow: { d in moveSelection(by: d) })
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider().background(theme.dim.opacity(0.3))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Track "which session number is this row?" — increments
                    // only for .focusSession items, so ⌘1 always means the
                    // first session even if a "Run in new window" row sits above.
                    let numbered = itemsWithSessionIndex()
                    ForEach(Array(numbered.enumerated()), id: \.element.item.id) { idx, entry in
                        row(for: entry.item, isSelected: idx == selection, sessionNumber: entry.sessionN)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selection = idx
                                onAction(entry.item)
                            }
                    }
                    if items.isEmpty {
                        Text("No matches — type a command to run it in a new window")
                            .font(.caption).foregroundStyle(theme.dim)
                            .padding(14)
                    }
                }
            }

            Divider().background(theme.dim.opacity(0.3))
            HStack(spacing: 12) {
                footerHint("↑↓", "navigate")
                footerHint("↩", "run/focus")
                footerHint("⌘1-9", "jump")
                footerHint("esc", "close")
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(width: 620, height: 420)
        .background(theme.bg)
        .preferredColorScheme(.dark)
        .onChange(of: query) { _ in selection = 0 }
    }

    private func itemsWithSessionIndex() -> [(item: PaletteItem, sessionN: Int?)] {
        var n = 0
        return items.map { it in
            if case .focusSession = it { n += 1; return (it, n <= 9 ? n : nil) }
            return (it, nil)
        }
    }

    @ViewBuilder private func row(for item: PaletteItem, isSelected: Bool, sessionNumber: Int?) -> some View {
        HStack(spacing: 10) {
            switch item {
            case .runInNewWindow(let cmd):
                Image(systemName: "terminal.fill").foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run in new window").font(.caption).foregroundStyle(theme.dim)
                    Text(cmd).font(.system(.body, design: .monospaced)).foregroundStyle(theme.fg).lineLimit(1)
                }
            case .settingAction(let a):
                Image(systemName: "slider.horizontal.3").foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Setting").font(.caption).foregroundStyle(theme.dim)
                    Text(a.title).font(.body).foregroundStyle(theme.fg).lineLimit(1)
                }
            case .focusSession(let s):
                Circle().fill(sessionStatus(s)).frame(width: 8, height: 8)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(nsColor: SessionWindow.neonColor(for: s.id)))
                    .frame(width: 3, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(s.title).font(.body).bold().foregroundStyle(theme.fg).lineLimit(1)
                        if s.pendingAttention {
                            Text("NEEDS INPUT")
                                .font(.system(.caption2, design: .rounded).bold())
                                .foregroundStyle(theme.bg)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 3).fill(theme.errColor))
                        }
                    }
                    if !s.cwd.isEmpty {
                        Text(shortCWD(s.cwd)).font(.caption).foregroundStyle(theme.dim).lineLimit(1)
                    }
                }
            }
            Spacer()
            // Settings actions show their status (ON/OFF, current value, ✓).
            if case .settingAction(let a) = item, let status = a.status {
                let isOn = (status == "ON" || status == "✓")
                Text(status)
                    .font(.system(.caption, design: .monospaced).bold())
                    .foregroundStyle(isOn ? theme.okColor : theme.dim)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill((isOn ? theme.okColor : theme.dim).opacity(0.18))
                    )
            }
            // ⌘N hint on the first 9 session rows so the shortcut is discoverable.
            if let n = sessionNumber {
                Text("⌘\(n)")
                    .font(.system(.caption, design: .monospaced).bold())
                    .foregroundStyle(theme.dim)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(theme.dim.opacity(0.18)))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(isSelected ? theme.accent.opacity(0.22) : Color.clear)
    }

    private func footerHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key).font(.system(.caption2, design: .monospaced).bold())
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(theme.dim.opacity(0.25)))
                .foregroundStyle(theme.dim)
            Text(label).font(.caption2).foregroundStyle(theme.dim)
        }
    }

    private func sessionStatus(_ s: SessionSummary) -> Color {
        if s.pendingAttention { return theme.errColor }
        if s.isRunning { return theme.runColor }
        if let ec = s.lastExit { return ec == 0 ? theme.okColor : theme.errColor }
        return theme.dim
    }

    private func moveSelection(by delta: Int) {
        let n = items.count
        guard n > 0 else { return }
        selection = ((selection + delta) % n + n) % n
    }

    private func activate() {
        guard !items.isEmpty, items.indices.contains(selection) else { return }
        onAction(items[selection])
    }

    private func shortCWD(_ p: String) -> String {
        var s = p
        if s.hasPrefix("file://"), let idx = s.dropFirst(7).firstIndex(of: "/") {
            s = String(s[idx...])
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if s.hasPrefix(home) { s = "~" + s.dropFirst(home.count) }
        return s
    }

    /// Match a query against a haystack. Two acceptance criteria (either
    /// hits): (a) haystack contains the query as a contiguous substring, or
    /// (b) each character of the query appears at a WORD-START in the
    /// haystack, in order. The word-start requirement is what makes "lol"
    /// stop matching "toggle window glow" — "l" isn't the start of any
    /// word there. Contiguous-substring is the fast happy path for short
    /// queries like "lol", "prefs", session titles, etc.
    static func matches(_ needle: String, in haystack: String) -> Bool {
        guard !needle.isEmpty else { return true }
        if haystack.contains(needle) { return true }

        // Collect word-start indices (0 + any position after a whitespace or
        // punctuation character).
        let chars = Array(haystack)
        var wordStarts: [Int] = []
        for i in chars.indices {
            if i == 0 { wordStarts.append(i); continue }
            let prev = chars[i - 1]
            if prev.isWhitespace || prev.isPunctuation || prev == "-" || prev == "_" || prev == "/" {
                wordStarts.append(i)
            }
        }
        // Greedy walk: for each needle char, find the next word-start in
        // haystack that matches.
        var wi = 0
        for c in needle {
            var matched = false
            while wi < wordStarts.count {
                let idx = wordStarts[wi]; wi += 1
                if chars[idx] == c { matched = true; break }
            }
            if !matched { return false }
        }
        return true
    }
}

/// SwiftUI's TextField doesn't give us ↑/↓/enter/escape handling cleanly on
/// macOS 13, so we host a small NSTextField and forward key events via
/// NSViewRepresentable. Also auto-focuses on appear.
@available(macOS 13, *)
struct PaletteFocusedField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onArrow: (Int) -> Void      // +1 for down, -1 for up

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.placeholderString = "Type a command or session…"
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: 18, weight: .regular)
        tf.textColor = NSColor.textColor
        tf.delegate = context.coordinator
        // No manual makeFirstResponder here — the controller sets it after
        // the SwiftUI hosting hierarchy is populated.
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        // Keep the coordinator's `parent` fresh so closures see the latest
        // @State/@Binding-backed callbacks (SwiftUI recreates the struct on
        // every re-render; the coordinator persists).
        context.coordinator.parent = self
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteFocusedField
        init(_ p: PaletteFocusedField) { parent = p }

        func controlTextDidChange(_ obj: Notification) {
            if let tf = obj.object as? NSTextField { parent.text = tf.stringValue }
        }

        /// The AppKit-idiomatic hook for special keys inside an NSTextField.
        /// The field editor (shared NSTextView) intercepts keyDown before it
        /// reaches the NSTextField subclass; instead it calls this delegate
        /// method with the mapped command selector (insertNewline:, moveUp:,
        /// cancelOperation:, …). Return true when we've handled it so the
        /// default (e.g. beep on ↩ in a single-line field) is suppressed.
        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertLineBreak(_:)):
                parent.onSubmit();  return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel();  return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onArrow(-1); return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onArrow(+1); return true
            default:
                return false
            }
        }
    }
}

/// Borderless panel that CAN take key focus — the default NSPanel with
/// .borderless / .nonactivatingPanel refuses first-responder status, which
/// is why keystrokes were falling through to the terminal window behind it.
private final class KeyableFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // Esc anywhere in the panel should dismiss — AppKit's default cancel op.
    override func cancelOperation(_ sender: Any?) { close() }
}

/// Floating panel — borderless, keyable, with a visual-effect blur backdrop
/// so it sits above the terminal windows Spotlight-style.
final class PaletteWindowController: NSWindowController {
    static let shared = PaletteWindowController()
    private let themeObs = ThemeObservable()
    private var keyMonitor: Any?

    private init() {
        let panel = KeyableFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        super.init(window: panel)
        // Rounded corners via a container hosting SwiftUI, so the theme.bg
        // fill inside PaletteView clips to a rounded rectangle nicely.
        let host = NSHostingView(rootView: paletteView())
        host.wantsLayer = true
        host.layer?.cornerRadius = 12
        host.layer?.masksToBounds = true
        panel.contentView = host
    }
    required init?(coder: NSCoder) { fatalError() }

    private func paletteView() -> some View {
        PaletteView(
            registry: AppDelegateBridge.registry,
            themeObs: themeObs,
            onDismiss: { [weak self] in self?.close() },
            onAction:  { [weak self] item in self?.perform(item) }
        )
    }

    /// Rebuild the hosting view so the initial state is fresh (query cleared,
    /// selection at 0). SwiftUI's own @State would persist otherwise.
    private func resetContent() {
        let host = NSHostingView(rootView: paletteView())
        host.wantsLayer = true
        host.layer?.cornerRadius = 12
        host.layer?.masksToBounds = true
        window?.contentView = host
    }

    @objc func showPalette(_ sender: Any?) {
        resetContent()
        centerOnKeyScreen()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeKey()
        DispatchQueue.main.async { [weak self] in
            guard let host = self?.window?.contentView else { return }
            if let field = Self.findTextField(in: host) {
                self?.window?.makeFirstResponder(field)
            }
        }
        installKeyMonitor()
    }

    /// Local key-down monitor: catches ⌘1..⌘9 while the palette is key and
    /// focuses the Nth SESSION in the current result list (skipping any
    /// "Run in new window" row, since that's not indexable by position).
    /// The field editor swallows keyDown, so a local monitor is the right
    /// place to intercept — it sees the event before the responder chain.
    private func installKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window,
                  event.modifierFlags.contains(.command),
                  let chars = event.charactersIgnoringModifiers, chars.count == 1,
                  let digit = Int(chars), (1...9).contains(digit) else { return event }
            self.focusNthSession(digit)
            return nil   // swallow — don't insert a digit into the field
        }
    }

    private func focusNthSession(_ n: Int) {
        // Uses the same ordering the palette displays: attention → running →
        // recent activity. If a query is active, filter first.
        let sorted = AppDelegateBridge.registry.summaries.sorted { a, b in
            if a.pendingAttention != b.pendingAttention { return a.pendingAttention }
            if a.isRunning != b.isRunning { return a.isRunning }
            return a.lastActivity > b.lastActivity
        }
        guard sorted.indices.contains(n - 1) else { NSSound.beep(); return }
        close()
        AppDelegateBridge.focusSession(sorted[n - 1].id)
    }

    override func close() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        super.close()
    }

    private static func findTextField(in view: NSView) -> NSTextField? {
        if let tf = view as? NSTextField { return tf }
        for sub in view.subviews {
            if let found = findTextField(in: sub) { return found }
        }
        return nil
    }

    private func centerOnKeyScreen() {
        guard let w = window, let screen = NSScreen.main else { return }
        let sf = screen.visibleFrame
        let size = w.frame.size
        w.setFrameOrigin(NSPoint(
            x: sf.midX - size.width / 2,
            y: sf.midY - size.height / 2 + 60   // slightly above center, Spotlight-ish
        ))
    }

    private func perform(_ item: PaletteItem) {
        close()
        switch item {
        case .focusSession(let s):
            AppDelegateBridge.focusSession(s.id)
        case .runInNewWindow(let cmd):
            AppDelegateBridge.runInNewWindow(cmd)
        case .settingAction(let a):
            a.apply()
        }
    }
}
