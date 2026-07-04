import AppKit
import SwiftTerm

// ─────────────────────────────────────────────────────────────────────────────
// zupershell — a minimal macOS terminal emulator with a built-in audit/security tap.
//
// SwiftTerm gives us the VT core (parser, grid, renderer, PTY). On top of it we
// install sensors: OSC 52 (clipboard) and OSC 133 (command marks) via the
// Terminal's registerOscHandler, plus title / cwd / process events via the
// delegate. Everything lands in a signed JSONL feed (see AuditLog.swift).
// ─────────────────────────────────────────────────────────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate {
    var window: NSWindow!
    var terminal: LocalProcessTerminalView!
    let audit = AuditLog.shared

    /// POLICY: flip to false to *block* programmatic clipboard writes (OSC 52).
    /// Every attempt is logged either way. This is Part IV.3's defense-as-feature.
    var clipboardWriteAllowed = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 900, height: 560)

        terminal = LocalProcessTerminalView(frame: frame)
        terminal.processDelegate = self

        // ── Install sensors on the underlying Terminal ──────────────────────
        let term = terminal.getTerminal()

        // OSC 52 — clipboard write/read. We now OWN this: log + policy + perform.
        term.registerOscHandler(code: 52) { [weak self] data in
            self?.handleOSC52(Array(data))
        }
        // OSC 133 — semantic command marks (prompt/command/output/exit).
        term.registerOscHandler(code: 133) { [weak self] data in
            self?.handleOSC133(Array(data))
        }

        // Nerd Font so Powerlevel10k / prompt glyphs render (no more tofu boxes).
        if let f = NSFont(name: "Hack Nerd Font Mono", size: 13) {
            terminal.font = f
        }

        // Spawn the user's login shell (argv[0] = "-zsh"), inheriting the FULL
        // environment (startProcess replaces env, so we must copy it) plus:
        //   • TERM / COLORTERM  — advertise 256-color + truecolor
        //   • POWERLEVEL9K_TERM_SHELL_INTEGRATION=true — make p10k emit OSC 133
        //     command marks, so the audit tap captures command_start/end + exit
        //   • TERM_PROGRAM=zupershell — identify ourselves
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["POWERLEVEL9K_TERM_SHELL_INTEGRATION"] = "true"
        env["TERM_PROGRAM"] = "zupershell"
        let envArray = env.map { "\($0.key)=\($0.value)" }
        audit.log("session_start", ["shell": shell, "emulator": "zupershell"])
        terminal.startProcess(executable: shell, args: [], environment: envArray, execName: "-\(shellName)")

        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "zupershell"
        // Unified, transparent titlebar so it blends into the terminal background
        // (iTerm/Ghostty-style). Matches SwiftTerm's default black bg.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.backgroundColor = .black

        // Host the terminal in a container that autoresizes with the window.
        // Fixes: (a) dead space above the view when the window grew, and
        //        (b) the last row's cursor clipping against the bottom edge.
        let container = NSView(frame: frame)
        container.autoresizingMask = [.width, .height]
        terminal.frame = container.bounds.insetBy(dx: 0, dy: 4) // 4pt bottom+top breathing room
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

    // MARK: - Sensors

    /// OSC 52 payload = "<targets>;<base64 | ?>"
    private func handleOSC52(_ bytes: [UInt8]) {
        let s = String(decoding: bytes, as: UTF8.self)
        let parts = s.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        let targets = parts.first.map(String.init) ?? ""
        let payload = parts.count > 1 ? String(parts[1]) : ""

        if payload == "?" {
            // An app is trying to READ your clipboard — deny by default, always log.
            audit.log("clipboard_read_attempt", ["targets": targets, "policy": "denied"])
            return
        }
        guard let content = Data(base64Encoded: payload) else {
            audit.log("clipboard_write", ["targets": targets, "policy": "rejected", "reason": "bad_base64"])
            return
        }
        let text = String(decoding: content, as: UTF8.self)
        let preview = String(text.prefix(80)).replacingOccurrences(of: "\n", with: "\\n")

        audit.log("clipboard_write", [
            "targets": targets,
            "bytes": content.count,
            "sha256": sha256hex(content),
            "preview": preview,
            "policy": clipboardWriteAllowed ? "allowed" : "denied",
        ])
        guard clipboardWriteAllowed else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// OSC 133 payload = phase char, optionally ";<extra>":
    ///   • "D;<exit>"       — command finished with that exit code
    ///   • "C;<base64-cmd>" — zupershell extension: the command text as typed
    ///     (base64 so control chars in the command can't break OSC parsing).
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

// Headless self-test: write a representative signed log and exit (no GUI).
// Lets us validate the writer + verifier without driving a window.
if CommandLine.arguments.contains("--audit-selftest") {
    let a = AuditLog.shared
    a.log("session_start", ["shell": "/bin/zsh", "emulator": "zupershell"])
    a.log("osc133", ["phase": "A", "name": "prompt_start"])
    a.log("clipboard_write", ["targets": "c", "bytes": 11,
                              "sha256": sha256hex(Data("hello world".utf8)),
                              "preview": "hello world", "policy": "allowed"])
    a.log("cwd", ["dir": "/Users/duppster/src/zupershell"])   // slashes exercise \/ escaping
    a.log("osc133", ["phase": "D", "name": "command_end", "exit": 0])
    a.log("process_exit", ["code": 0])
    a.flush()
    print(a.path)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let mainMenu = NSMenu()

let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit zupershell",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q")
appMenuItem.submenu = appMenu

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
