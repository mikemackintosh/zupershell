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

    /// Rolling window of the most recent PTY text (ANSI-stripped). Used to
    /// detect approval-prompt patterns across chunk boundaries — Ink-based
    /// TUIs like Claude Code paint their prompts by cursor-positioning and
    /// writing colored fragments, so "Do you want to proceed?" arrives split
    /// across many PTY reads with ANSI escapes interleaved. A single-chunk
    /// substring match won't catch that.
    private var attentionBuffer: String = ""
    private static let attentionBufferMax = 4096

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

        // Attention signals — two ways a session can flag "needs input":
        //   1. BEL (0x07) — universal, but many modern TUIs don't emit it.
        //   2. Prompt pattern match — scan PTY output for known "waiting
        //      for user" strings ("Do you want to proceed?", "(y/n)", etc.).
        //
        // Pattern matching was chosen over PTY-silence detection because
        // Claude Code re-renders its selector/footer every ~200ms while
        // waiting for input — silence never crosses any reasonable
        // threshold. Diagnostic: silence values seen were 0.05–2.14s.
        terminal.onBell = { [weak self] in
            self?.summary.markNeedsAttention()
            self?.audit.log("bell", [:])
        }
        terminal.onDataChunk = { [weak self] chunk in
            guard let self, self.summary.isRunning else { return }
            self.appendAndScanForAttention(chunk)
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

        // Rounded-rect ring + Gaussian-shadow glow, matching the window's
        // corner radius so the halo actually follows the corners instead of
        // forming a boxy frame. Real neon color from a curated palette.
        let alpha = CGFloat(max(0.0, min(1.0, s.windowGlowIntensity)))
        overlay.ringColor = SessionWindow.neonColor(for: audit.sessionID)
            .withAlphaComponent(alpha)
        overlay.rebuildRing()
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
        var ringColor: NSColor = .clear {
            didSet { needsDisplay = true }
        }
        var cornerRadius: CGFloat = 10 {
            didSet { needsDisplay = true }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            // Do NOT set wantsLayer = true — we want the view's draw(_:) to
            // run in the window's native context, which handles Retina and
            // coordinate systems automatically. A layer-backed view routes
            // draw through a display-list flow that we were fighting.
        }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var isOpaque: Bool { false }
        // Keep the effect method used by the caller.
        func rebuildRing() { needsDisplay = true }

        /// Draw the CSS-equivalent effect directly. AppKit gives us a properly
        /// scaled CGContext with the view's coordinates, so no scaling, no
        /// origin-flip juggling, no bitmap-vs-layer.contents mismatch.
        override func draw(_ dirtyRect: NSRect) {
            guard bounds.width > 0, bounds.height > 0,
                  ringColor.alphaComponent > 0,
                  let ctx = NSGraphicsContext.current?.cgContext else { return }

            let pathRect = bounds.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: pathRect,
                                     xRadius: cornerRadius, yRadius: cornerRadius)

            // 1. INSET GLOW: clip to inside the rounded shape, then draw a
            // thick stroke with a Gaussian shadow. The clip means the outer
            // half of the stroke (and its blurred halo) is discarded; only
            // the INSIDE portion remains — that's CSS `inset` behavior.
            ctx.saveGState()
            path.addClip()
            let glowAlpha = ringColor.alphaComponent * 0.55
            let glowColor = ringColor.withAlphaComponent(glowAlpha)
            ctx.setShadow(offset: .zero, blur: 6, color: glowColor.cgColor)
            glowColor.setStroke()
            path.lineWidth = 3
            path.stroke()
            ctx.restoreGState()

            // 2. CRISP OUTLINE: 1pt fully-opaque stroke on top, no shadow.
            ringColor.setStroke()
            path.lineWidth = 1.0
            path.stroke()
        }

        /// Manual rounded-rect path (macOS-13 compatible; NSBezierPath.cgPath
        /// is macOS-14 only).
        private func roundedRectPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
            let r = min(radius, min(rect.width, rect.height) / 2)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
                     startAngle: -.pi / 2, endAngle: 0, clockwise: false)
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
                     startAngle: 0, endAngle: .pi / 2, clockwise: false)
            p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
            p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                     startAngle: .pi / 2, endAngle: .pi, clockwise: false)
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                     startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: false)
            p.closeSubpath()
            return p
        }
    }

    /// Curated palette of vivid neon primaries. HSB-derived continuous hues
    /// still read as muted on dark backgrounds (yellow becomes olive, blue
    /// becomes muddy purple, etc.); explicit RGB triples of pure "neon"
    /// primaries pop way harder. Deterministic pick via FNV-1a hash of the
    /// session ID.
    /// Append a chunk to the rolling buffer, keep the tail, strip ANSI,
    /// and scan for approval-prompt phrases. Runs on every PTY read; the
    /// buffer is bounded so total work per call stays roughly constant.
    private func appendAndScanForAttention(_ chunk: String) {
        attentionBuffer += chunk
        if attentionBuffer.count > Self.attentionBufferMax {
            attentionBuffer = String(attentionBuffer.suffix(Self.attentionBufferMax))
        }
        let stripped = Self.stripANSI(attentionBuffer).lowercased()
        for p in Self.attentionPhrases where stripped.contains(p) {
            if !summary.pendingAttention {
                audit.log("attention_prompt", ["match": p])
                FileHandle.standardError.write("[attn-match] session=\(summary.id.suffix(8)) phrase=\(p)\n".data(using: .utf8)!)
            }
            summary.markNeedsAttention()
            // Truncate the buffer past the match so we don't refire on the
            // same rendered prompt every 200ms.
            attentionBuffer = ""
            return
        }
    }

    /// Strip common ANSI escape sequences so pattern matching can find
    /// text that Ink-style TUIs write with color/cursor escapes interleaved
    /// between individual characters or words.
    static func stripANSI(_ s: String) -> String {
        // CSI sequences: ESC [ ... final-byte (@ through ~), possibly with
        // intermediate parameter/intermediate bytes in between.
        // OSC sequences: ESC ] ... BEL (0x07) or ST (ESC \).
        // Also strip lone BEL and other C0 controls except newlines/tabs.
        var out = ""
        out.reserveCapacity(s.count)
        var it = s.unicodeScalars.makeIterator()
        while let c = it.next() {
            if c.value == 0x1B {                                 // ESC
                guard let next = it.next() else { break }
                if next == "[" {                                 // CSI
                    while let n = it.next() {
                        if (0x40...0x7E).contains(n.value) { break }
                    }
                } else if next == "]" {                          // OSC
                    while let n = it.next() {
                        if n.value == 0x07 { break }             // BEL terminator
                        if n.value == 0x1B {                     // ST = ESC \
                            _ = it.next()
                            break
                        }
                    }
                } else {
                    // Two-byte escape (charset, single-char), skip both.
                }
                continue
            }
            if c.value < 0x20, c.value != 0x0A, c.value != 0x09 { continue }
            out.unicodeScalars.append(c)
        }
        return out
    }

    private static let attentionPhrases: [String] = [
        "do you want to proceed",     // Claude Code approval prompt
        "do you want to continue",
        "are you sure",
        "press any key",
        "(y/n)",
        "(y/n):",
        "(y/n)?",
        "[y/n]",
        "[y/n]:",
        "[y/n]?",
        "confirm (y/n)",
    ]

    /// Exposed so the Overview can tag each session row with the same
    /// palette color as its window glow.
    static func neonColor(for id: String) -> NSColor {
        let palette: [NSColor] = [
            NSColor(srgbRed: 1.00, green: 0.20, blue: 0.65, alpha: 1),  // hot pink
            NSColor(srgbRed: 0.20, green: 1.00, blue: 0.50, alpha: 1),  // lime
            NSColor(srgbRed: 0.20, green: 0.80, blue: 1.00, alpha: 1),  // electric blue
            NSColor(srgbRed: 1.00, green: 0.55, blue: 0.15, alpha: 1),  // hot orange
            NSColor(srgbRed: 0.85, green: 0.30, blue: 1.00, alpha: 1),  // violet
            NSColor(srgbRed: 1.00, green: 1.00, blue: 0.15, alpha: 1),  // neon yellow
            NSColor(srgbRed: 0.15, green: 1.00, blue: 1.00, alpha: 1),  // cyan
            NSColor(srgbRed: 1.00, green: 0.20, blue: 0.30, alpha: 1),  // hot red
        ]
        var h: UInt32 = 2166136261
        for b in id.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return palette[Int(h % UInt32(palette.count))]
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // User focused the window — they've presumably seen the prompt now,
        // so clear the "needs attention" flag.
        summary.clearAttention()
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
