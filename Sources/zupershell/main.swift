import AppKit
import SwiftTerm

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        _ = newWindow()      // first window
        installCmdDragMonitor()

        NotificationCenter.default.addObserver(forName: .zushSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.installCmdDragMonitor()
        }

        // Repro/soak affordance: if $ZUSH_AUTO_OPEN_N is set to a positive
        // integer, open that many additional windows staggered by 400ms each.
        // Lets us reproduce multi-window crashes without depending on the
        // human pressing ⌘N. Bail out on shutdown to be safe.
        if let n = ProcessInfo.processInfo.environment["ZUSH_AUTO_OPEN_N"].flatMap(Int.init), n > 0 {
            for i in 1...n {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400 * i)) { [weak self] in
                    _ = self?.newWindow()
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Session lifecycle

    /// Open a new terminal window. First-window path uses frame autosave;
    /// subsequent windows cascade off the current key window.
    @discardableResult
    func newWindow() -> SessionWindow {
        let isFirst = sessions.isEmpty
        let s = SessionWindow(coordinator: self, isFirst: isFirst, previousKey: NSApp.keyWindow)
        sessions.append(s)
        FileHandle.standardError.write("zupershell window[\(sessions.count - 1)] audit log: \(s.audit.path)\n".data(using: .utf8)!)
        return s
    }

    /// Called by SessionWindow.windowWillClose.
    func removeSession(_ s: SessionWindow) {
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
        ]
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
