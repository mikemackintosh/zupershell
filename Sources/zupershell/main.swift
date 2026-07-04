import AppKit
import SwiftTerm

// ─────────────────────────────────────────────────────────────────────────────
// zupershell — macOS terminal emulator with a built-in audit/security tap.
//
// SwiftTerm gives us the VT core (parser, grid, renderer, PTY). On top of it we
// install sensors: OSC 52 (clipboard) and OSC 133 (command marks) via the
// Terminal's registerOscHandler, plus title / cwd / process events via the
// delegate. Everything lands in a signed JSONL feed (see AuditLog.swift).
// User-tunable config lives in ~/.zush/settings.json (see Settings.swift).
// ─────────────────────────────────────────────────────────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate {
    var window: NSWindow!
    var terminal: LocalProcessTerminalView!
    let audit = AuditLog.shared
    let store = SettingsStore.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 900, height: 560)

        terminal = LocalProcessTerminalView(frame: frame)
        terminal.processDelegate = self

        // ── Install sensors on the underlying Terminal ──────────────────────
        let term = terminal.getTerminal()
        term.registerOscHandler(code: 52)  { [weak self] d in self?.handleOSC52(Array(d)) }
        term.registerOscHandler(code: 133) { [weak self] d in self?.handleOSC133(Array(d)) }

        // Apply scrollback BEFORE any output arrives (buffer rebuild is safe here
        // since setup runs on a virgin terminal; live changes require a restart).
        term.options.scrollback = store.current.scrollbackLines
        term.setup(isReset: false)

        // Apply all live-settable properties (font/colors/cursor) from settings.
        applyLiveSettings(store.current)

        // React to preference changes for as long as the app lives.
        NotificationCenter.default.addObserver(forName: .zushSettingsChanged, object: nil, queue: .main) { [weak self] n in
            guard let self, let s = n.object as? Settings else { return }
            self.applyLiveSettings(s)
        }

        // Spawn the user's login shell (argv[0] = "-zsh"), inheriting the FULL
        // environment (startProcess replaces env, so we must copy it) plus:
        //   • TERM / COLORTERM  — advertise 256-color + truecolor
        //   • POWERLEVEL9K_TERM_SHELL_INTEGRATION=true — make p10k emit OSC 133
        //   • TERM_PROGRAM=zupershell — identify ourselves + gate shell integration
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

        let container = NSView(frame: frame)
        container.autoresizingMask = [.width, .height]
        terminal.frame = container.bounds.insetBy(dx: 0, dy: 4)
        terminal.autoresizingMask = [.width, .height]
        container.addSubview(terminal)

        window.contentView = container
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminal)
        NSApp.activate(ignoringOtherApps: true)

        FileHandle.standardError.write("zupershell audit log: \(audit.path)\n".data(using: .utf8)!)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Apply settings

    /// Push font, palette, cursor, and window bg into the running terminal view.
    /// Called at startup and on every settings save.
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
    }

    // MARK: - Sensors

    /// OSC 52 payload = "<targets>;<base64 | ?>"
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

    /// OSC 133 payload = phase char, optionally ";<extra>":
    ///   • "D;<exit>"       — command finished with that exit code
    ///   • "C;<base64-cmd>" — zupershell extension: the command text as typed
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
// Bootstrap (SPM executable, no .xib).
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

let mainMenu = NSMenu()

// App menu (⌘, and ⌘Q)
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
let prefsItem = NSMenuItem(title: "Preferences…",
                           action: #selector(PreferencesWindowController.showPreferences(_:)),
                           keyEquivalent: ",")
prefsItem.target = PreferencesWindowController.shared
appMenu.addItem(prefsItem)
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(withTitle: "Quit zupershell",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q")
appMenuItem.submenu = appMenu

// Edit menu (⌘C / ⌘V via responder chain to the terminal view)
let editMenuItem = NSMenuItem()
mainMenu.addItem(editMenuItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Copy",  action: #selector(NSText.copy(_:)),  keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenuItem.submenu = editMenu

app.mainMenu = mainMenu

let delegate = AppDelegate()
app.delegate = delegate
app.run()
