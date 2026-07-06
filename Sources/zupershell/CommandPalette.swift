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

    var id: String {
        switch self {
        case .runInNewWindow(let cmd): return "run:\(cmd)"
        case .focusSession(let s):     return "sess:\(s.id)"
        }
    }
    static func == (l: PaletteItem, r: PaletteItem) -> Bool { l.id == r.id }
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
        let q = query.trimmingCharacters(in: .whitespaces)
        // "Run in new window" — offer this first if the query isn't empty.
        if !q.isEmpty { out.append(.runInNewWindow(q)) }

        // Sessions matching the query (fuzzy match on title + cwd + cmd).
        // Attention-pending first, then running, then rest — same priority the
        // Overview uses so the palette matches the mental model.
        let sessions = registry.summaries.sorted { a, b in
            if a.pendingAttention != b.pendingAttention { return a.pendingAttention }
            if a.isRunning != b.isRunning { return a.isRunning }
            return a.lastActivity > b.lastActivity
        }
        let matches: [SessionSummary]
        if q.isEmpty {
            matches = sessions
        } else {
            matches = sessions.filter { s in
                PaletteView.fuzzyMatch(q.lowercased(), in: [
                    s.title, s.cwd, s.currentCommand ?? "", s.lastCommand ?? ""
                ].joined(separator: " ").lowercased())
            }
        }
        out.append(contentsOf: matches.map(PaletteItem.focusSession))
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
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        row(for: item, isSelected: idx == selection)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selection = idx
                                onAction(item)
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

    @ViewBuilder private func row(for item: PaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            switch item {
            case .runInNewWindow(let cmd):
                Image(systemName: "terminal.fill").foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run in new window").font(.caption).foregroundStyle(theme.dim)
                    Text(cmd).font(.system(.body, design: .monospaced)).foregroundStyle(theme.fg).lineLimit(1)
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

    /// Cheap ordered-subsequence match — the standard "letters appear in
    /// order" behavior Spotlight/VSCode use. Not scored (yet), but keeps
    /// results relevant enough for interactive typing.
    private static func fuzzyMatch(_ needle: String, in haystack: String) -> Bool {
        var it = haystack.makeIterator()
        for c in needle {
            var found = false
            while let h = it.next() { if h == c { found = true; break } }
            if !found { return false }
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
        let tf = PaletteTextField()
        tf.placeholderString = "Type a command or session…"
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: 18, weight: .regular)
        tf.textColor = NSColor.textColor
        tf.delegate = context.coordinator
        tf.paletteHandlers = context.coordinator
        DispatchQueue.main.async { tf.window?.makeFirstResponder(tf) }
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate, PaletteFieldHandlers {
        var parent: PaletteFocusedField
        init(_ p: PaletteFocusedField) { parent = p }
        func controlTextDidChange(_ obj: Notification) {
            if let tf = obj.object as? NSTextField { parent.text = tf.stringValue }
        }
        func paletteFieldEnter()  { parent.onSubmit() }
        func paletteFieldEscape() { parent.onCancel() }
        func paletteFieldUp()     { parent.onArrow(-1) }
        func paletteFieldDown()   { parent.onArrow(+1) }
    }
}

protocol PaletteFieldHandlers: AnyObject {
    func paletteFieldEnter()
    func paletteFieldEscape()
    func paletteFieldUp()
    func paletteFieldDown()
}

final class PaletteTextField: NSTextField {
    weak var paletteHandlers: PaletteFieldHandlers?
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: paletteHandlers?.paletteFieldEnter();  return    // Return / KeypadEnter
        case 53:     paletteHandlers?.paletteFieldEscape(); return    // Escape
        case 126:    paletteHandlers?.paletteFieldUp();     return    // ArrowUp
        case 125:    paletteHandlers?.paletteFieldDown();   return    // ArrowDown
        default: break
        }
        super.keyDown(with: event)
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
        // Explicitly force key + first responder on the hosted text field.
        // Without this, borderless panels can end up visible but not key,
        // so keystrokes leak through to whatever was previously focused
        // (the terminal window behind the palette).
        window?.makeKey()
        DispatchQueue.main.async { [weak self] in
            guard let host = self?.window?.contentView else { return }
            if let field = Self.findTextField(in: host) {
                self?.window?.makeFirstResponder(field)
            }
        }
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
        // Snapshot before we close (SwiftUI @State would reset).
        close()
        switch item {
        case .focusSession(let s):
            AppDelegateBridge.focusSession(s.id)
        case .runInNewWindow(let cmd):
            AppDelegateBridge.runInNewWindow(cmd)
        }
    }
}
