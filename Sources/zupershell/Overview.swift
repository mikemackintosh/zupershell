import AppKit
import SwiftUI
import Combine

// ─────────────────────────────────────────────────────────────────────────────
// Sessions Overview — "what's happening in each of my terminals right now."
//
// Themed to match the terminal: transparent titlebar, full-size content view,
// theme.background as window bg, theme-palette dots/badges. Live-retints when
// the theme changes in Preferences (subscribes to .zushSettingsChanged via
// ThemeObservable).
// ─────────────────────────────────────────────────────────────────────────────

/// Observable wrapper around the current theme so SwiftUI can re-render when
/// the user changes theme in Preferences.
final class ThemeObservable: ObservableObject {
    @Published var theme: Theme = Themes.byName(SettingsStore.shared.current.themeName)
    private var observer: NSObjectProtocol?
    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .zushSettingsChanged, object: nil, queue: .main
        ) { [weak self] n in
            guard let s = n.object as? Settings else { return }
            self?.theme = Themes.byName(s.themeName)
        }
    }
    deinit { if let obs = observer { NotificationCenter.default.removeObserver(obs) } }
}

/// Little semantic role → theme-palette color helper. Aura's palette does
/// double duty as the "status" palette because it's designed to be legible
/// on the dark terminal background.
private extension Theme {
    var okColor:    Color { Color(nsColor: ansi[10]) } // bright green
    var errColor:   Color { Color(nsColor: ansi[9])  } // bright red
    var runColor:   Color { Color(nsColor: ansi[11]) } // bright yellow
    var accent:     Color { Color(nsColor: cursor)   } // theme accent
    var fg:         Color { Color(nsColor: foreground) }
    var bg:         Color { Color(nsColor: background) }
    var dim:        Color { Color(nsColor: ansi[8])  } // bright black
    var warnColor:  Color { Color(nsColor: ansi[11]) } // yellow — for policy-blocked
}

@available(macOS 13, *)
struct OverviewView: View {
    @ObservedObject var registry: SessionsRegistry
    @ObservedObject var themeObs: ThemeObservable
    @State private var now = Date()
    /// Density: read from settings on appear, save on change. Keeping this
    /// as its own @State avoids re-reading the whole Settings struct on
    /// every ticker tick.
    @State private var compact: Bool = SettingsStore.shared.current.overviewCompact
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var theme: Theme { themeObs.theme }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                if registry.summaries.isEmpty { emptyState } else { sessionList }
            }
            .padding(.top, 8)  // breathing room below the titlebar strip
        }
        .frame(minWidth: 540, minHeight: 320)
        .onReceive(ticker) { now = $0 }
        .preferredColorScheme(.dark)
    }

    /// Density picker + total count. Dragged to the trailing edge so titlebar
    /// buttons on the leading side remain visually separate.
    private var header: some View {
        HStack {
            if !registry.summaries.isEmpty {
                Text("\(registry.summaries.count) session\(registry.summaries.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(theme.dim)
            }
            Spacer()
            Picker("", selection: $compact) {
                Text("Normal").tag(false)
                Text("Compact").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .onChange(of: compact) { new in
                var s = SettingsStore.shared.current
                if s.overviewCompact != new { s.overviewCompact = new; SettingsStore.shared.save(s) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 44))
                .foregroundStyle(theme.accent.opacity(0.8))
            Text("No sessions open")
                .font(.headline)
                .foregroundStyle(theme.fg)
            Text("Open a window with ⌘N to start.")
                .font(.caption)
                .foregroundStyle(theme.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionList: some View {
        ScrollView {
            VStack(spacing: compact ? 0 : 8) {
                ForEach(Array(registry.summaries.enumerated()), id: \.element.id) { idx, s in
                    if compact {
                        CompactSessionRow(s: s, theme: theme, now: now)
                        if idx < registry.summaries.count - 1 {
                            Divider().background(theme.dim.opacity(0.2))
                        }
                    } else {
                        SessionCard(s: s, theme: theme, now: now)
                    }
                }
            }
            .padding(compact ? 0 : 12)
        }
    }
}

@available(macOS 13, *)
struct CompactSessionRow: View {
    @ObservedObject var s: SessionSummary
    let theme: Theme
    let now: Date
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            statusDot
            Text(s.title)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(theme.fg)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            if !s.cwd.isEmpty {
                Text(shortCWD(s.cwd))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.dim)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .layoutPriority(-1)  // shrink this first if space is tight
            }

            Spacer(minLength: 8)

            // Current command (or last command with exit badge)
            if s.isRunning, let cmd = s.currentCommand {
                ProgressView().controlSize(.mini).tint(theme.runColor)
                Text(cmd)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.fg)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 200, alignment: .leading)
            } else if let last = s.lastCommand {
                if let ec = s.lastExit { exitBadge(ec) }
                Text(last)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.dim)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 200, alignment: .leading)
            }

            if s.clipboardWritesDenied > 0 {
                Image(systemName: "shield.fill")
                    .font(.caption2).foregroundStyle(theme.warnColor)
            }

            Text(relativeTime(from: s.lastActivity, to: now))
                .font(.caption2).monospacedDigit()
                .foregroundStyle(theme.dim)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(hovering ? theme.fg.opacity(0.06) : Color.clear)
        .overlay(alignment: .leading) {
            // Left-edge accent bar on hover, gives a distinct affordance for
            // dense compact rows without a full border.
            Rectangle()
                .fill(theme.accent)
                .frame(width: hovering ? 3 : 0)
        }
        .onHover { h in
            hovering = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
        .zushClickableRow(sessionID: s.id)
    }

    private var statusDot: some View {
        let color: Color = {
            if s.isRunning { return theme.runColor }
            if let ec = s.lastExit { return ec == 0 ? theme.okColor : theme.errColor }
            return theme.dim
        }()
        return Circle().fill(color).frame(width: 7, height: 7)
    }

    private func exitBadge(_ ec: Int) -> some View {
        let color = ec == 0 ? theme.okColor : theme.errColor
        return Text("\(ec)")
            .font(.system(.caption2, design: .monospaced).bold())
            .foregroundStyle(color)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.15)))
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

    private func relativeTime(from d: Date, to now: Date) -> String {
        let dt = Int(now.timeIntervalSince(d))
        if dt < 2 { return "just now" }
        if dt < 60 { return "\(dt)s ago" }
        if dt < 3600 { return "\(dt / 60)m ago" }
        return "\(dt / 3600)h ago"
    }
}

/// Shared clickable-row behavior: pointing-hand cursor on hover, tap focuses
/// the terminal window. Each row struct owns its own hover *visual* state
/// since the card and compact-row want different treatments.
@available(macOS 13, *)
extension View {
    func zushClickableRow(sessionID: String) -> some View {
        contentShape(Rectangle())
            .onTapGesture { AppDelegateBridge.focusSession(sessionID) }
    }
}

@available(macOS 13, *)
struct SessionCard: View {
    @ObservedObject var s: SessionSummary
    let theme: Theme
    let now: Date
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statusDot
                Text(s.title).font(.headline).foregroundStyle(theme.fg).lineLimit(1)
                Spacer()
                Text(relativeTime(from: s.lastActivity, to: now))
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(theme.dim)
            }

            if !s.cwd.isEmpty {
                Text(shortCWD(s.cwd))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.dim)
                    .lineLimit(1)
            }

            if s.isRunning, let cmd = s.currentCommand {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini).tint(theme.runColor)
                    Text(cmd)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(theme.fg)
                        .lineLimit(1)
                }
            } else if let last = s.lastCommand {
                HStack(spacing: 8) {
                    if let ec = s.lastExit {
                        exitBadge(ec)
                    }
                    Text(last)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(theme.dim)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 14) {
                statCell(systemImage: "arrow.triangle.2.circlepath",
                         text: "\(s.commandCount)",
                         tint: theme.dim)
                if s.clipboardWriteAttempts > 0 {
                    if s.clipboardWritesDenied > 0 {
                        statCell(systemImage: "shield.fill",
                                 text: "\(s.clipboardWritesDenied) blocked / \(s.clipboardWriteAttempts) cb",
                                 tint: theme.warnColor)
                    } else {
                        statCell(systemImage: "doc.on.clipboard",
                                 text: "\(s.clipboardWriteAttempts) cb writes",
                                 tint: theme.dim)
                    }
                }
                Spacer()
            }
            .font(.caption)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.fg.opacity(hovering ? 0.09 : 0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(hovering ? theme.accent.opacity(0.55) : theme.dim.opacity(0.25),
                                lineWidth: hovering ? 1.2 : 1)
                )
        )
        .onHover { h in
            hovering = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
        .zushClickableRow(sessionID: s.id)
    }

    private var statusDot: some View {
        let color: Color = {
            if s.isRunning { return theme.runColor }
            if let ec = s.lastExit { return ec == 0 ? theme.okColor : theme.errColor }
            return theme.dim
        }()
        return Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.7), radius: 3)
    }

    private func exitBadge(_ ec: Int) -> some View {
        let color = ec == 0 ? theme.okColor : theme.errColor
        return Text("\(ec)")
            .font(.system(.caption, design: .monospaced).bold())
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.5), lineWidth: 0.5))
            )
    }

    private func statCell(systemImage: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
        .foregroundStyle(tint)
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

    private func relativeTime(from d: Date, to now: Date) -> String {
        let dt = Int(now.timeIntervalSince(d))
        if dt < 2 { return "just now" }
        if dt < 60 { return "\(dt)s ago" }
        if dt < 3600 { return "\(dt / 60)m ago" }
        return "\(dt / 3600)h ago"
    }
}

final class OverviewWindowController: NSWindowController, NSWindowDelegate {
    static let shared = OverviewWindowController()
    private let registry = AppDelegateBridge.registry
    private let themeObs = ThemeObservable()
    private var settingsObserver: NSObjectProtocol?

    private init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "Sessions Overview"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        // Seed the window background from the current theme; keep it in sync as
        // the user changes theme in Preferences.
        let initial = Themes.byName(SettingsStore.shared.current.themeName)
        w.backgroundColor = initial.background
        w.appearance = NSAppearance(named: .darkAqua)
        if #available(macOS 13, *) {
            w.contentViewController = NSHostingController(
                rootView: OverviewView(registry: registry, themeObs: themeObs)
            )
        }
        super.init(window: w)
        w.delegate = self
        w.center()

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .zushSettingsChanged, object: nil, queue: .main
        ) { [weak w] n in
            guard let w, let s = n.object as? Settings else { return }
            w.backgroundColor = Themes.byName(s.themeName).background
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let o = settingsObserver { NotificationCenter.default.removeObserver(o) } }

    @objc func showOverview(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Static bridge so SwiftUI-hosted windows can reach app-wide state without
/// needing a compile-time reference to AppDelegate. Populated in
/// AppDelegate.applicationDidFinishLaunching.
enum AppDelegateBridge {
    static var registry = SessionsRegistry()
    /// Bring the terminal window that owns this sessionID forward and make
    /// it key. No-op if the ID doesn't match a live session.
    static var focusSession: (String) -> Void = { _ in }
}
