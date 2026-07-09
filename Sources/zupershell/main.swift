import AppKit
import SwiftTerm
import UserNotifications

// ─────────────────────────────────────────────────────────────────────────────
// zupershell — macOS terminal emulator with a built-in audit/security tap.
//
// AppDelegate here is the app-wide COORDINATOR:
//   • owns the sessions array (one entry per open window)
//   • owns the menu action registry
//   • owns the Cmd-drag mouse monitor
//   • fans out settings changes via .zushSettingsChanged
//
// Per-window state (terminal, PTY, audit log, OSC handlers, delegate methods)
// lives in SessionWindow. This split is what makes multi-window sane.
// ─────────────────────────────────────────────────────────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate {
    var sessions: [SessionWindow] = []
    let store = SettingsStore.shared

    private var actions: [String: () -> Void] = [:]
    private var cmdDragMonitor: Any?

    /// Session IDs we've already notified about a long-running command in the
    /// CURRENT run. Cleared when the command finishes (isRunning goes false).
    private var idleAlerted = Set<String>()
    private var idleTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        // Populate the AppDelegateBridge focus closure so Overview rows can
        // bring a specific window forward when clicked.
        AppDelegateBridge.focusSession = { [weak self] sessionID in
            guard let self,
                  let match = self.sessions.first(where: { $0.audit.sessionID == sessionID })
            else { return }
            NSApp.activate(ignoringOtherApps: true)
            match.window.makeKeyAndOrderFront(nil)
        }

        // Run a command in a NEW window (Command Palette's "Run in new
        // window" action). Spawn a fresh SessionWindow, then wait one runloop
        // tick for the shell to be up before injecting the command as bytes
        // to the PTY. \n at the end so the shell executes it immediately.
        AppDelegateBridge.runInNewWindow = { [weak self] cmd in
            guard let self else { return }
            let session = self.newWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak session] in
                guard let session else { return }
                let bytes = Array((cmd + "\n").utf8)
                session.terminal.send(source: session.terminal, data: bytes[...])
            }
        }

        _ = newWindow()      // first window
        installCmdDragMonitor()
        installIdleNotifier()

        // Request notification permission (silent no-op if user says no).
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        NotificationCenter.default.addObserver(forName: .zushSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.installCmdDragMonitor()
        }

        // Repro/soak affordance:
        //   ZUSH_AUTO_OPEN_N=N       → open N extra windows, 400ms apart
        //   ZUSH_AUTO_CLOSE_FIRST=1  → close the first window after all opened
        //                              (exercises the close-teardown code path)
        // Together they turn "press ⌘N N times then ⌘W once" into a headless
        // soak test we can invoke from a shell script.
        if let n = ProcessInfo.processInfo.environment["ZUSH_AUTO_OPEN_N"].flatMap(Int.init), n > 0 {
            for i in 1...n {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400 * i)) { [weak self] in
                    _ = self?.newWindow()
                }
            }
            if ProcessInfo.processInfo.environment["ZUSH_AUTO_CLOSE_FIRST"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400 * (n + 2))) { [weak self] in
                    self?.sessions.first?.window.performClose(nil)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Session lifecycle

    /// Open a new terminal window. First-window path uses frame autosave;
    /// subsequent windows cascade off the current key window. New windows
    /// inherit the key session's OSC 7 cwd so `⌘N` opens where you are.
    @discardableResult
    func newWindow() -> SessionWindow {
        let isFirst = sessions.isEmpty
        let inheritedCwd: String? = {
            guard !isFirst,
                  let key = NSApp.keyWindow,
                  let src = sessions.first(where: { $0.window === key }) else { return nil }
            let c = src.summary.cwd
            return c.isEmpty ? nil : c
        }()
        let s = SessionWindow(coordinator: self, isFirst: isFirst,
                              previousKey: NSApp.keyWindow, startCwd: inheritedCwd)
        sessions.append(s)
        AppDelegateBridge.registry.register(s.summary)
        FileHandle.standardError.write("zupershell window[\(sessions.count - 1)] audit log: \(s.audit.path)\n".data(using: .utf8)!)
        return s
    }

    /// Called by SessionWindow.windowWillClose.
    func removeSession(_ s: SessionWindow) {
        AppDelegateBridge.registry.unregister(id: s.summary.id)
        sessions.removeAll { $0 === s }
    }

    /// Route a menu action to the frontmost window's SessionWindow (if any).
    /// Falls back to the first session if no window is currently key.
    private func keySession() -> SessionWindow? {
        if let key = NSApp.keyWindow, let s = sessions.first(where: { $0.window === key }) {
            return s
        }
        return sessions.first
    }

    // MARK: - Menus & actions

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
            "newWindow":        { [weak self] in _ = self?.newWindow() },
            "closeWindow":      { [weak self] in self?.keySession()?.window.performClose(nil) },
            // Edit — responder chain routes to the terminal view in the key window
            "copy":             { NSApp.sendAction(#selector(NSText.copy(_:)),       to: nil, from: nil) },
            "paste":            { NSApp.sendAction(#selector(NSText.paste(_:)),      to: nil, from: nil) },
            "selectAll":        { NSApp.sendAction(#selector(NSText.selectAll(_:)),  to: nil, from: nil) },
            // View — target key session directly
            "clearBuffer":      { [weak self] in self?.keySession()?.clearBuffer() },
            "resetTerminal":    { [weak self] in self?.keySession()?.resetTerminal() },
            "zoomIn":           { [weak self] in self?.zoomFont(by:  1) },
            "zoomOut":          { [weak self] in self?.zoomFont(by: -1) },
            "zoomReset":        { [weak self] in self?.zoomFont(by:  0) },
            // Window
            "minimize":         { [weak self] in self?.keySession()?.window.miniaturize(nil) },
            "zoomWindow":       { [weak self] in self?.keySession()?.window.zoom(nil) },
            "bringAllToFront":  { NSApp.arrangeInFront(nil) },
            "showOverview":     { OverviewWindowController.shared.showOverview(nil) },
            "showPalette":      { PaletteWindowController.shared.showPalette(nil) },
            // Find — route through the responder chain so SwiftTerm's terminal
            // view (which implements performTextFinderAction) handles it. A
            // synthetic NSMenuItem carries the NSTextFinder.Action raw value.
            "findShow":         { [weak self] in self?.sendFindAction(.showFindInterface) },
            "findNext":         { [weak self] in self?.sendFindAction(.nextMatch) },
            "findPrevious":     { [weak self] in self?.sendFindAction(.previousMatch) },
            "findUseSelection": { [weak self] in self?.sendFindAction(.setSearchString) },
        ]
    }

    /// Dispatch a find-menu action to the terminal via the responder chain.
    /// We build a synthetic NSMenuItem carrying the tag so SwiftTerm's
    /// performTextFinderAction(_:) implementation can decode it. Falls back
    /// to focusing the key terminal first if nothing responds.
    private func sendFindAction(_ action: NSTextFinder.Action) {
        // Make sure a terminal is first responder — the menu item might be
        // firing while the app menu itself briefly held focus.
        if let s = keySession() { s.window.makeFirstResponder(s.terminal) }
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.tag = action.rawValue
        let ok = NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item)
        if !ok {
            // Diagnostic: something is off with the responder chain.
            FileHandle.standardError.write("[find] no responder handled performTextFinderAction: (action=\(action.rawValue))\n".data(using: .utf8)!)
        }
    }

    @objc func dispatchMenuAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        keySession()?.audit.log("menu_action", ["name": name])
        actions[name]?()
    }

    private func zoomFont(by delta: Double) {
        var s = store.current
        s.fontSize = delta == 0 ? 13 : max(9, min(24, s.fontSize + delta))
        store.save(s)   // fans out to every open window
    }

    // MARK: - Cmd-drag anywhere

    /// Ticks every 2s to poll two things per session:
    ///   1. PTY silence while running → mark pendingAttention (catches TUIs
    ///      like Claude Code that don't emit BEL on approval prompts).
    ///   2. Long-idle notification threshold → post macOS notification once.
    func installIdleNotifier() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.checkIdleSessions()
        }
    }

    private func checkIdleSessions() {
        let s = store.current
        let now = Date()
        for session in sessions {
            // Reliable attention detector: scan the rendered terminal grid
            // for approval-prompt phrases. Runs regardless of the idle-
            // notification setting because it's the primary attention signal.
            session.scanRenderedBufferForAttention()

            guard s.idleNotifyEnabled else { continue }
            let sum = session.summary
            if sum.isRunning, let cmd = sum.currentCommand,
               now.timeIntervalSince(sum.lastActivity) >= TimeInterval(s.idleNotifyThresholdSeconds),
               !idleAlerted.contains(sum.id) {
                idleAlerted.insert(sum.id)
                postIdleNotification(cmd: cmd, title: sum.title,
                                     elapsed: Int(now.timeIntervalSince(sum.lastActivity)))
            }
            if !sum.isRunning { idleAlerted.remove(sum.id) }
        }
    }

    private func postIdleNotification(cmd: String, title: String, elapsed: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Still running (\(elapsed)s)"
        content.body = "[\(title)] \(cmd)"
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    /// Install (or refresh) the local mouse monitor: on left-mouse-down with
    /// Cmd held, if the event's window belongs to any of our sessions, hand
    /// it off to performDrag and swallow so the terminal never sees the click.
    func installCmdDragMonitor() {
        if let m = cmdDragMonitor { NSEvent.removeMonitor(m); cmdDragMonitor = nil }
        guard store.current.dragWithCmdClick else { return }
        cmdDragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.contains(.command),
                  let w = event.window,
                  self.sessions.contains(where: { $0.window === w })
            else { return event }
            w.performDrag(with: event)
            return nil
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Bootstrap
// ─────────────────────────────────────────────────────────────────────────────

if CommandLine.arguments.contains("--audit-selftest") {
    let a = AuditLog()
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
