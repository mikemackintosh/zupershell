import AppKit
import SwiftTerm

// ─────────────────────────────────────────────────────────────────────────────
// zupershell — macOS terminal emulator with a built-in audit/security tap.
//
// SwiftTerm provides the VT core (parser, grid, renderer, PTY). On top we
// install sensors: OSC 52 (clipboard), OSC 133 (command marks + text), plus
// title / cwd / process events via the delegate. Everything lands in a signed
// JSONL feed (see AuditLog.swift). User config lives in ~/.zush/settings.json
// (see Settings.swift). The menu bar + right-click popup are built from a
// declarative JSON spec (see Menu.swift + Resources/menus.default.json).
// ─────────────────────────────────────────────────────────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate {
    var window: NSWindow!
    var terminal: LocalProcessTerminalView!
    let audit = AuditLog.shared
    let store = SettingsStore.shared

    /// Action name → closure. Populated in installMenus(); every menu item
    /// (menubar or popup) routes here via dispatchMenuAction:.
    private var actions: [String: () -> Void] = [:]

    /// Held so we can remove it before Prefs windows etc. get their events eaten.
    private var cmdDragMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()

        let frame = NSRect(x: 0, y: 0, width: 900, height: 560)

        terminal = LocalProcessTerminalView(frame: frame)
        terminal.processDelegate = self

        // ── Install sensors on the underlying Terminal ──────────────────────
        let term = terminal.getTerminal()
        term.registerOscHandler(code: 52)  { [weak self] d in self?.handleOSC52(Array(d)) }
        term.registerOscHandler(code: 133) { [weak self] d in self?.handleOSC133(Array(d)) }

        term.options.scrollback = store.current.scrollbackLines
        term.setup(isReset: false)

        applyLiveSettings(store.current)

        NotificationCenter.default.addObserver(forName: .zushSettingsChanged, object: nil, queue: .main) { [weak self] n in
            guard let self, let s = n.object as? Settings else { return }
            self.applyLiveSettings(s)
        }

        // Spawn the login shell with a tuned environment.
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
                                    "scrollback": store.current.scrollbackLines])
        terminal.startProcess(executable: shell, args: [], environment: envArray, execName: "-\(shellName)")

        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "zupershell"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.backgroundColor = Themes.byName(store.current.themeName).background

        // Persist window frame across launches (AppKit built-in — one line of work).
        // Applied only when the setting is on; otherwise the window centers each time.
        if store.current.rememberWindowFrame {
            window.setFrameAutosaveName("io.zyp.zupershell.mainWindow")
        }

        let container = NSView(frame: frame)
        container.autoresizingMask = [.width, .height]
        terminal.frame = container.bounds.insetBy(dx: 0, dy: 4)
        terminal.autoresizingMask = [.width, .height]
        container.addSubview(terminal)

        // Attach the right-click popup to the terminal view.
        let spec = MenuLoader.load()
        terminal.menu = MenuBuilder.buildPopup(spec, target: self, selector: #selector(dispatchMenuAction(_:)))

        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        if !store.current.rememberWindowFrame { window.center() }
        window.makeFirstResponder(terminal)
        NSApp.activate(ignoringOtherApps: true)

        // Cmd-drag anywhere to move the window (Ghostty-style). Guarded by setting.
        // We install a local monitor scoped to leftMouseDown, only act when Cmd is
        // held AND the event's window is our main window (so Prefs stays untouched).
        installCmdDragMonitor()

        FileHandle.standardError.write("zupershell audit log: \(audit.path)\n".data(using: .utf8)!)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Menus & actions

    /// Build the menubar from JSON, then populate the action registry with
    /// concrete closures. To add a new action: register it here + add a
    /// matching item to menus.default.json (or ~/.zush/menus.json).
    private func installMenus() {
        let spec = MenuLoader.load()
        NSApp.mainMenu = MenuBuilder.buildMenubar(spec, target: self, selector: #selector(dispatchMenuAction(_:)))

        actions = [
            // App
            "about":            { NSApp.orderFrontStandardAboutPanel(nil) },
            "showPreferences":  { PreferencesWindowController.shared.showPreferences(nil) },
            "hide":             { NSApp.hide(nil) },
            "hideOthers":       { NSApp.hideOtherApplications(nil) },
            "showAll":          { NSApp.unhideAllApplications(nil) },
            "quit":             { NSApp.terminate(nil) },
            // File
            "newWindow":        { [weak self] in self?.newWindow() },
            "closeWindow":      { [weak self] in self?.window?.performClose(nil) },
            // Edit — route through responder chain so terminal handles them
            "copy":             { NSApp.sendAction(#selector(NSText.copy(_:)),       to: nil, from: nil) },
            "paste":            { NSApp.sendAction(#selector(NSText.paste(_:)),      to: nil, from: nil) },
            "selectAll":        { NSApp.sendAction(#selector(NSText.selectAll(_:)),  to: nil, from: nil) },
            // View
            "clearBuffer":      { [weak self] in self?.clearBuffer() },
            "resetTerminal":    { [weak self] in self?.resetTerminal() },
            "zoomIn":           { [weak self] in self?.zoomFont(by:  1) },
            "zoomOut":          { [weak self] in self?.zoomFont(by: -1) },
            "zoomReset":        { [weak self] in self?.zoomFont(by:  0) },
            // Window
            "minimize":         { [weak self] in self?.window?.miniaturize(nil) },
            "zoomWindow":       { [weak self] in self?.window?.zoom(nil) },
            "bringAllToFront":  { NSApp.arrangeInFront(nil) },
        ]
    }

    @objc func dispatchMenuAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        audit.log("menu_action", ["name": name, "source": sender.menu?.title.isEmpty == false ? "menubar" : "popup"])
        actions[name]?()
    }

    // MARK: - Concrete action bodies

    private func newWindow() {
        // Stub for now — a real "new window" needs to extract terminal creation
        // into a factory that this delegate can call multiple times. Log the ask
        // so we know it's exercised; wire the second-window path in a later pass.
        audit.log("action_stub", ["name": "newWindow", "note": "not yet implemented"])
    }

    private func clearBuffer() {
        // ESC c is a hard reset that clears both viewport and scrollback.
        // ESC[H\e[2J = home + erase display (viewport only). We use the former.
        terminal.feed(text: "\u{1B}c")
    }

    private func resetTerminal() {
        terminal.getTerminal().resetToInitialState()
    }

    private func zoomFont(by delta: Double) {
        var s = store.current
        s.fontSize = delta == 0 ? 13 : max(9, min(24, s.fontSize + delta))
        store.save(s)
    }

    // MARK: - Apply settings

    private func applyLiveSettings(_ s: Settings) {
        let theme = Themes.byName(s.themeName)
        terminal.font = s.nsFont()
        terminal.useBrightColors = s.useBrightColors
        terminal.installColors(theme.swiftTermPalette)
        terminal.nativeBackgroundColor = theme.background
        terminal.nativeForegroundColor = theme.foreground
        terminal.caretColor = theme.cursor
        terminal.getTerminal().setCursorStyle(s.swiftTermCursor)
        window?.backgroundColor = theme.background
        window?.alphaValue = CGFloat(max(0.5, min(1.0, s.windowOpacity)))
        // Frame autosave & drag monitor are set at window creation; on toggle changes we
        // update the monitor state so Cmd-drag can be turned off without a restart.
        installCmdDragMonitor()
    }

    // MARK: - Cmd-drag anywhere

    /// Add/remove the Cmd-drag monitor based on the current setting. The monitor
    /// intercepts left-mouse-down in the main window when Cmd is held, hands the
    /// event to window.performDrag, and swallows it so the terminal doesn't see
    /// a phantom click. Any other event flows through unchanged.
    private func installCmdDragMonitor() {
        if let m = cmdDragMonitor { NSEvent.removeMonitor(m); cmdDragMonitor = nil }
        guard store.current.dragWithCmdClick else { return }
        cmdDragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === self.window,
                  event.modifierFlags.contains(.command) else { return event }
            self.window.performDrag(with: event)
            return nil
        }
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
        NSApp.terminate(nil)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Bootstrap
// ─────────────────────────────────────────────────────────────────────────────

if CommandLine.arguments.contains("--audit-selftest") {
    let a = AuditLog.shared
    a.log("session_start", ["shell": "/bin/zsh", "emulator": "zupershell"])
    a.log("osc133", ["phase": "A", "name": "prompt_start"])
    a.log("clipboard_write", ["targets": "c", "bytes": 11,
                              "sha256": sha256hex(Data("hello world".utf8)),
                              "preview": "hello world", "policy": "allowed"])
    a.log("cwd", ["dir": "/Users/duppster/src/zupershell"])
    a.log("osc133", ["phase": "D", "name": "command_end", "exit": 0])
    a.log("process_exit", ["code": 0])
    a.flush()
    print(a.path)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
