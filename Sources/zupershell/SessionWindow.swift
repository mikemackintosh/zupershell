import AppKit
import SwiftTerm

// ─────────────────────────────────────────────────────────────────────────────
// SessionWindow — one window, one terminal, one audit log.
//
// Extracted from AppDelegate so multiple windows can coexist. Each window is
// its own security session: distinct sessionID, its own JSONL log, its own
// PTY child. Settings are app-wide (shared through SettingsStore) so a theme
// change fans out to every open window via the .zushSettingsChanged noti.
// ─────────────────────────────────────────────────────────────────────────────

final class SessionWindow: NSObject, LocalProcessTerminalViewDelegate, NSWindowDelegate {
    let window: NSWindow
    let terminal: LocalProcessTerminalView
    let audit: AuditLog
    private let store = SettingsStore.shared
    private weak var coordinator: AppDelegate?
    private var settingsObserver: NSObjectProtocol?

    /// Edge constraints on the terminal. Held so applyLiveSettings can update
    /// `.constant` on each in place (cheap, animates naturally, no re-activate).
    private var padTopConstraint: NSLayoutConstraint!
    private var padBottomConstraint: NSLayoutConstraint!
    private var padLeadingConstraint: NSLayoutConstraint!
    private var padTrailingConstraint: NSLayoutConstraint!

    init(coordinator: AppDelegate, isFirst: Bool, previousKey: NSWindow? = nil) {
        self.coordinator = coordinator
        self.audit = AuditLog()

        let frame = NSRect(x: 0, y: 0, width: 900, height: 560)
        self.terminal = LocalProcessTerminalView(frame: frame)
        self.window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)

        super.init()

        terminal.processDelegate = self
        window.delegate = self
        window.title = "zupershell"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.backgroundColor = Themes.byName(store.current.themeName).background
        // CRITICAL under ARC: NSWindow created via NSWindow(contentRect:...)
        // defaults isReleasedWhenClosed = true, which sends the window an
        // EXTRA `release` when it closes. Combined with our strong ref
        // (let window: NSWindow), that over-releases the window; its
        // _NSWindowTransformAnimation then holds a dangling reference and
        // the next CATransaction commit crashes in autorelease pool cleanup.
        window.isReleasedWhenClosed = false

        // Only the FIRST window drives frame autosave; further windows cascade
        // from the current key window so you don't get a stack of overlapped
        // windows on the same pixel.
        if isFirst && store.current.rememberWindowFrame {
            window.setFrameAutosaveName("io.zyp.zupershell.mainWindow")
        }

        // Install sensors on the underlying Terminal (safe to do pre-hosting).
        let term = terminal.getTerminal()
        term.registerOscHandler(code: 52)  { [weak self] d in self?.handleOSC52(Array(d)) }
        term.registerOscHandler(code: 133) { [weak self] d in self?.handleOSC133(Array(d)) }

        // NOTE: scrollback size is init-time inside SwiftTerm (options.scrollback
        // is read only when the Buffer is constructed). Setting it now and
        // calling setup(isReset:false) would NOT rebuild the buffer, so we don't
        // do that — it was a silent no-op that also involved touching the
        // terminal state before the view is hosted, which coincided with a
        // second-window crash during CATransaction commit. Applying scrollback
        // to future windows requires a fresh Terminal init; leave for a proper
        // fix later. Sessions log the *requested* scrollback for auditability.

        // Fan-out settings changes to this window for its lifetime. Subscribe
        // BEFORE hosting the view so the first apply doesn't race a redraw.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .zushSettingsChanged, object: nil, queue: .main
        ) { [weak self] n in
            guard let self, let s = n.object as? Settings else { return }
            self.applyLiveSettings(s)
        }

        // Build container + host the terminal view BEFORE applying visual
        // settings. This matters: installColors/nativeBackgroundColor kick
        // CoreAnimation transactions; if they land while the view isn't in a
        // window's hierarchy, we saw over-release crashes on the next runloop
        // tick during CATransaction cleanup.
        //
        // Layout: with .fullSizeContentView the container fills the whole
        // window (behind the titlebar); the terminal is inset from the top
        // by the titlebar height via NSWindow.contentLayoutGuide so the
        // terminal doesn't cover the traffic-light buttons or block titlebar
        // drag. Since the window background matches the theme background,
        // the top strip visually blends — there's no seam.
        let container = NSView(frame: frame)
        container.autoresizingMask = [.width, .height]
        container.addSubview(terminal)
        window.contentView = container

        terminal.translatesAutoresizingMaskIntoConstraints = false
        let contentGuide = window.contentLayoutGuide as? NSLayoutGuide
        // Top is pinned to the WINDOW's contentLayoutGuide, which excludes the
        // titlebar strip — so paddingTop counts from BELOW the titlebar, and
        // hover/drag on the titlebar keep working. Fall back to container.top
        // if the guide isn't available (shouldn't happen on macOS 13+).
        padTopConstraint      = terminal.topAnchor.constraint(equalTo: contentGuide?.topAnchor ?? container.topAnchor)
        padBottomConstraint   = terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        padLeadingConstraint  = terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor)
        padTrailingConstraint = terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        NSLayoutConstraint.activate([padTopConstraint, padBottomConstraint, padLeadingConstraint, padTrailingConstraint])
        applyPadding(store.current)   // seed initial padding

        // Context menu — same JSON that powers the menubar.
        let spec = MenuLoader.load()
        terminal.menu = MenuBuilder.buildPopup(spec, target: coordinator,
                                               selector: #selector(AppDelegate.dispatchMenuAction(_:)))

        // NOW the terminal is hosted; apply visual settings.
        applyLiveSettings(store.current)

        // Spawn the login shell.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["POWERLEVEL9K_TERM_SHELL_INTEGRATION"] = "true"
        env["TERM_PROGRAM"] = "zupershell"
        let envArray = env.map { "\($0.key)=\($0.value)" }
        audit.log("session_start", ["shell": shell, "emulator": "zupershell",
                                    "theme": store.current.themeName,
                                    "scrollback_requested": store.current.scrollbackLines,
                                    "windowIndex": isFirst ? 0 : 1])
        terminal.startProcess(executable: shell, args: [], environment: envArray, execName: "-\(shellName)")

        if isFirst, !store.current.rememberWindowFrame { window.center() }
        window.makeKeyAndOrderFront(nil)
        if !isFirst, let prev = previousKey {
            window.cascadeTopLeft(from: NSPoint(x: prev.frame.minX, y: prev.frame.maxY))
        }
        window.makeFirstResponder(terminal)
        NSApp.activate(ignoringOtherApps: true)
    }

    deinit {
        if let obs = settingsObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Actions the coordinator dispatches to a specific session

    func clearBuffer()  { terminal.feed(text: "\u{1B}c") }
    func resetTerminal() { terminal.getTerminal().resetToInitialState() }

    // MARK: - Apply settings

    /// Push font/palette/cursor/bg/alpha from Settings into this window. Called
    /// at init and on every settings save (fanned out by NotificationCenter).
    func applyLiveSettings(_ s: Settings) {
        let theme = Themes.byName(s.themeName)
        terminal.font = s.nsFont()
        terminal.useBrightColors = s.useBrightColors
        terminal.installColors(theme.swiftTermPalette)
        terminal.nativeBackgroundColor = theme.background
        terminal.nativeForegroundColor = theme.foreground
        terminal.caretColor = theme.cursor
        terminal.getTerminal().setCursorStyle(s.swiftTermCursor)
        window.backgroundColor = theme.background
        window.alphaValue = CGFloat(max(0.5, min(1.0, s.windowOpacity)))
        applyPadding(s)
    }

    /// Update the four edge constraints from the current padding settings.
    /// Positive constants push edges INWARD: leading/top take +N, trailing/
    /// bottom take -N (the trailing/bottom anchors read "constraint from the
    /// outer edge", so inset is negative).
    private func applyPadding(_ s: Settings) {
        padTopConstraint.constant      =  CGFloat(s.paddingTop)
        padBottomConstraint.constant   = -CGFloat(s.paddingBottom)
        padLeadingConstraint.constant  =  CGFloat(s.paddingLeading)
        padTrailingConstraint.constant = -CGFloat(s.paddingTrailing)
    }

    // MARK: - Sensors

    private func handleOSC52(_ bytes: [UInt8]) {
        let s = String(decoding: bytes, as: UTF8.self)
        let parts = s.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        let targets = parts.first.map(String.init) ?? ""
        let payload = parts.count > 1 ? String(parts[1]) : ""

        if payload == "?" {
            audit.log("clipboard_read_attempt", ["targets": targets, "policy": "denied"])
            return
        }
        guard let content = Data(base64Encoded: payload) else {
            audit.log("clipboard_write", ["targets": targets, "policy": "rejected", "reason": "bad_base64"])
            return
        }
        let text = String(decoding: content, as: UTF8.self)
        let preview = String(text.prefix(80)).replacingOccurrences(of: "\n", with: "\\n")
        let allowed = store.current.clipboardWriteAllowed

        audit.log("clipboard_write", [
            "targets": targets,
            "bytes": content.count,
            "sha256": sha256hex(content),
            "preview": preview,
            "policy": allowed ? "allowed" : "denied",
        ])
        guard allowed else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func handleOSC133(_ bytes: [UInt8]) {
        let s = String(decoding: bytes, as: UTF8.self)
        let f = s.split(separator: ";", omittingEmptySubsequences: false)
        let phase = f.first.map(String.init) ?? ""
        let name = ["A": "prompt_start", "B": "command_start",
                    "C": "output_start", "D": "command_end"][phase] ?? "mark_\(phase)"
        var fields: [String: Any] = ["phase": phase, "name": name]
        if phase == "D", f.count > 1 { fields["exit"] = Int(f[1]) ?? -1 }
        if phase == "C", f.count > 1,
           let data = Data(base64Encoded: String(f[1])),
           let cmd = String(data: data, encoding: .utf8) {
            fields["cmd"] = cmd
            fields["sha256"] = sha256hex(data)
        }
        audit.log("osc133", fields)
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        audit.log("resize", ["cols": newCols, "rows": newRows])
    }
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        window.title = title.isEmpty ? "zupershell" : title
        audit.log("title", ["title": title])
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        audit.log("cwd", ["dir": directory ?? ""])
    }
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        audit.log("process_exit", ["code": exitCode.map { Int($0) } ?? -1])
        window.close()   // triggers windowWillClose, which unregisters this session
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        audit.log("window_closed", [:])
        audit.flush()
        // IMPORTANT: defer removeSession to the next runloop tick.
        //
        // AppKit runs a close animation (_NSWindowTransformAnimation) that
        // holds blocks capturing views/delegates from this window. If we
        // drop our last strong ref synchronously here, SessionWindow
        // deallocs immediately, its terminal view + observers tear down,
        // and the animation's cleanup on the NEXT CATransaction commit
        // over-releases a freed pointer — killing every window in the app.
        //
        // Posting async {} runs the removal on the next main-loop pass,
        // after AppKit's animation has finished with everything it borrowed.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.coordinator?.removeSession(self)
        }
    }
}
