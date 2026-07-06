import AppKit
import SwiftTerm

// ─────────────────────────────────────────────────────────────────────────────
// ZushTerminalView — LocalProcessTerminalView with a smarter link opener.
//
// Overrides requestOpenLink (default: NSWorkspace.open) to detect `path:line`
// patterns in Cmd-clicked text. If matched, spawns the user-configured
// fileOpenCommand with {path} and {line} substituted, so users can jump to
// specific lines in their editor (e.g. `code -g {path}:{line}` for VS Code).
//
// Anything that looks like a real URL (has a `://` scheme) or that we can't
// parse as a path:line pair falls through to the default NSWorkspace path.
// ─────────────────────────────────────────────────────────────────────────────

final class ZushTerminalView: LocalProcessTerminalView {
    // Note: not `override` because SwiftTerm's LocalProcessTerminalView inherits
    // requestOpenLink only via a TerminalViewDelegate protocol extension (not a
    // class method). Declaring it here satisfies the protocol requirement, and
    // dynamic dispatch on the protocol conformance picks our version.
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        // Real URL — just open it (matches upstream default).
        if link.contains("://") {
            if let url = URL(string: link) { NSWorkspace.shared.open(url) }
            return
        }

        // path:line pattern — trailing :<digits>. Strip and pass line separately.
        let (rawPath, line) = splitPathAndLine(link)
        let expandedPath = expandTilde(rawPath)

        // Verify the file exists before spawning; otherwise fall back to just
        // opening (best-effort). Avoids launching an editor at a bogus path.
        let fm = FileManager.default
        let cwd = keySessionCWD() ?? fm.currentDirectoryPath
        let absPath = expandedPath.hasPrefix("/")
            ? expandedPath
            : (cwd as NSString).appendingPathComponent(expandedPath)
        guard fm.fileExists(atPath: absPath) else {
            if let url = URL(string: link) { NSWorkspace.shared.open(url) }
            return
        }

        runFileOpenCommand(path: absPath, line: line)
    }

    /// Split `foo/bar.swift:42` → (`foo/bar.swift`, `42`). If no `:<digits>`
    /// suffix, returns (link, nil).
    private func splitPathAndLine(_ s: String) -> (String, String?) {
        guard let colonIdx = s.lastIndex(of: ":"), colonIdx < s.endIndex else { return (s, nil) }
        let tail = s[s.index(after: colonIdx)...]
        if !tail.isEmpty, tail.allSatisfy(\.isNumber) {
            return (String(s[..<colonIdx]), String(tail))
        }
        return (s, nil)
    }

    private func expandTilde(_ s: String) -> String {
        s.hasPrefix("~") ? (s as NSString).expandingTildeInPath : s
    }

    /// Resolve the currently-key session's OSC 7 cwd for relative-path resolution.
    /// Falls back to the process cwd if we can't find one.
    private func keySessionCWD() -> String? {
        guard let key = NSApp.keyWindow,
              let del = NSApp.delegate as? AppDelegate,
              let session = del.sessions.first(where: { $0.window === key }) else { return nil }
        var cwd = session.summary.cwd
        if cwd.hasPrefix("file://"),
           let firstSlash = cwd.dropFirst(7).firstIndex(of: "/") {
            cwd = String(cwd[firstSlash...])
        }
        return cwd.isEmpty ? nil : cwd
    }

    /// Spawn the user-configured fileOpenCommand with substitutions, via
    /// /bin/sh so shell PATH lookup works (e.g. `code`, `subl`, `mate`).
    private func runFileOpenCommand(path: String, line: String?) {
        var cmd = SettingsStore.shared.current.fileOpenCommand
        cmd = cmd.replacingOccurrences(of: "{path}", with: quoteForShell(path))
        cmd = cmd.replacingOccurrences(of: "{line}", with: line ?? "1")
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-lc", cmd]   // -l so PATH includes the user's login PATH
        do {
            try task.run()
        } catch {
            NSSound.beep()
        }
    }

    /// Minimal shell-safe quoting: wrap in single quotes, escape internal single quotes.
    private func quoteForShell(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
