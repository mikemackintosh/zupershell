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
    let terminal: ZushTerminalView
    let audit: AuditLog
    /// Live "what's happening now" view of this session — read by the overview.
    let summary: SessionSummary
    private let store = SettingsStore.shared
    private weak var coordinator: AppDelegate?
    private var settingsObserver: NSObjectProtocol?

    /// Edge constraints on the terminal. Held so applyLiveSettings can update
    /// `.constant` on each in place (cheap, animates naturally, no re-activate).
    private var padTopConstraint: NSLayoutConstraint!
    private var padBottomConstraint: NSLayoutConstraint!
    private var padLeadingConstraint: NSLayoutConstraint!
    private var padTrailingConstraint: NSLayoutConstraint!

    /// Container view holding the terminal. Held so applyLiveSettings can
    /// paint the per-window glow (gradient sublayers on its layer).
    private var containerView: NSView!

    /// Overlay view holding the four-edge gradient layers. Sits ABOVE the
    /// terminal in the subview stack so AppKit guarantees paint-on-top, and
    /// passes mouse events through via hitTest→nil.
    private var glowOverlay: GlowOverlayView?

    init(coordinator: AppDelegate, isFirst: Bool, previousKey: NSWindow? = nil) {
        self.coordinator = coordinator
        self.audit = AuditLog()
        self.summary = SessionSummary(id: audit.sessionID)

        let frame = NSRect(x: 0, y: 0, width: 900, height: 560)
        self.terminal = ZushTerminalView(frame: frame)
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
        container.wantsLayer = true                        // enables layer.borderColor for the glow
        container.addSubview(terminal)
        window.contentView = container
        self.containerView = container

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
        // "Thin strokes" — invert the SwiftTerm fontSmoothing default so
        // Retina glyphs don't render bolded. Matches iTerm2's out-of-box look.
        terminal.fontSmoothing = !s.thinStrokes
        terminal.useBrightColors = s.useBrightColors
        terminal.installColors(theme.swiftTermPalette)
        terminal.nativeBackgroundColor = theme.background
        terminal.nativeForegroundColor = theme.foreground
        terminal.caretColor = theme.cursor
        terminal.getTerminal().setCursorStyle(s.swiftTermCursor)
        window.backgroundColor = theme.background
        window.alphaValue = CGFloat(max(0.5, min(1.0, s.windowOpacity)))
        applyPadding(s)
        applyGlow(s)
    }

    /// Four-edge soft glow using an OVERLAY subview added after the terminal.
    /// Subview stack order is authoritative in AppKit, so the overlay is
    /// guaranteed to paint above the terminal — a plain container-layer
    /// sublayer approach didn't (glow was hidden behind the opaque terminal
    /// background on 3 of 4 edges).
    ///
    /// The overlay's own layer holds the four CAGradientLayer sides. Mouse
    /// events pass through via hitTest→nil so clicks / selection still land
    /// on the terminal.
    private func applyGlow(_ s: Settings) {
        guard let container = containerView else { return }

        guard s.windowGlowEnabled else {
            glowOverlay?.removeFromSuperview()
            glowOverlay = nil
            return
        }

        // Lazy create the overlay and add it AS THE LAST subview so it's on top.
        let overlay: GlowOverlayView
        if let existing = glowOverlay {
            overlay = existing
            overlay.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        } else {
            overlay = GlowOverlayView(frame: container.bounds)
            overlay.autoresizingMask = [.width, .height]
            container.addSubview(overlay)   // added AFTER terminal → z-order on top
            glowOverlay = overlay
        }

        // Very tight edge glow: 1pt of solid color hugging the edge, then a
        // gaussian-shaped fade over 5pt. Multi-stop gradient approximates the
        // curved falloff so it reads as a proper glow instead of a linear
        // ramp. Total width = 6pt.
        let alpha = CGFloat(max(0.0, min(1.0, s.windowGlowIntensity)))
        let hue = SessionWindow.hue(for: audit.sessionID)
        // Wider "solid" section so the color reads at full saturation before
        // the fade begins — 1pt of solid gets blended with the window shadow
        // on Retina and reads muted. 2pt solid + 6pt curved fade = 8pt total.
        let stops: [(CGFloat, CGFloat)] = [
            (0.000, 1.00),   // 0pt (edge): full solid
            (0.250, 1.00),   // 2pt: still fully solid ← the punchy line
            (0.375, 0.85),   // 3pt: still strong
            (0.500, 0.55),   // 4pt: e^(-0.6)
            (0.625, 0.25),   // 5pt: e^(-1.4)
            (0.750, 0.08),   // 6pt: e^(-2.5)
            (0.875, 0.02),   // 7pt: almost gone
            (1.000, 0.00),   // 8pt: clear
        ]
        let cgColors: [CGColor] = stops.map {
            NSColor(calibratedHue: hue, saturation: 0.95, brightness: 1.0, alpha: alpha * $0.1).cgColor
        }
        let locations: [NSNumber] = stops.map { NSNumber(value: Double($0.0)) }
        let blur: CGFloat = 8
        let b = overlay.bounds

        // Top edge: solid at top, fading down.
        let top = CAGradientLayer()
        top.colors = cgColors; top.locations = locations
        top.startPoint = CGPoint(x: 0.5, y: 1.0)
        top.endPoint   = CGPoint(x: 0.5, y: 0.0)
        top.frame = CGRect(x: 0, y: b.height - blur, width: b.width, height: blur)
        top.autoresizingMask = [.layerWidthSizable, .layerMinYMargin]

        // Bottom edge: solid at bottom, fading up.
        let bottom = CAGradientLayer()
        bottom.colors = cgColors; bottom.locations = locations
        bottom.startPoint = CGPoint(x: 0.5, y: 0.0)
        bottom.endPoint   = CGPoint(x: 0.5, y: 1.0)
        bottom.frame = CGRect(x: 0, y: 0, width: b.width, height: blur)
        bottom.autoresizingMask = [.layerWidthSizable, .layerMaxYMargin]

        // Left edge: solid at left, fading right.
        let left = CAGradientLayer()
        left.colors = cgColors; left.locations = locations
        left.startPoint = CGPoint(x: 0.0, y: 0.5)
        left.endPoint   = CGPoint(x: 1.0, y: 0.5)
        left.frame = CGRect(x: 0, y: 0, width: blur, height: b.height)
        left.autoresizingMask = [.layerHeightSizable, .layerMaxXMargin]

        // Right edge: solid at right, fading left.
        let right = CAGradientLayer()
        right.colors = cgColors; right.locations = locations
        right.startPoint = CGPoint(x: 1.0, y: 0.5)
        right.endPoint   = CGPoint(x: 0.0, y: 0.5)
        right.frame = CGRect(x: b.width - blur, y: 0, width: blur, height: b.height)
        right.autoresizingMask = [.layerHeightSizable, .layerMinXMargin]

        for gl in [top, bottom, left, right] {
            overlay.layer?.addSublayer(gl)
        }
    }

    /// Deterministic hue in [0, 1) from a session ID. Uses a small FNV-1a-ish
    /// hash so consecutive sessions get visually distinct hues rather than
    /// clumping together the way plain Swift `hashValue` sometimes does.
    private static func hue(for id: String) -> CGFloat {
        var h: UInt32 = 2166136261
        for b in id.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return CGFloat(h % 1000) / 1000.0
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
        summary.noteClipboardWrite(denied: !allowed)
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
        var decodedCmd: String? = nil
        var decodedExit: Int? = nil
        if phase == "D", f.count > 1 {
            decodedExit = Int(f[1]) ?? -1
            fields["exit"] = decodedExit!
        }
        if phase == "C", f.count > 1,
           let data = Data(base64Encoded: String(f[1])),
           let cmd = String(data: data, encoding: .utf8) {
            decodedCmd = cmd
            fields["cmd"] = cmd
            fields["sha256"] = sha256hex(data)
        }
        audit.log("osc133", fields)

        // Feed the live overview: C → command running, D → command done.
        if phase == "C", let cmd = decodedCmd { summary.noteCommandStart(cmd) }
        if phase == "D", let ec = decodedExit { summary.noteCommandEnd(exit: ec) }
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        audit.log("resize", ["cols": newCols, "rows": newRows])
    }
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        window.title = title.isEmpty ? "zupershell" : title
        audit.log("title", ["title": title])
        summary.noteTitle(title)
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        let d = directory ?? ""
        audit.log("cwd", ["dir": d])
        summary.noteCWD(d)
    }
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        audit.log("process_exit", ["code": exitCode.map { Int($0) } ?? -1])
        window.close()   // triggers windowWillClose, which unregisters this session
    }

    // MARK: - NSWindowDelegate

    private final class GlowOverlayView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { fatalError() }
        // Pass ALL mouse events through — this is a decorative overlay only.
        // Without this, clicks land here instead of the terminal.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

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
