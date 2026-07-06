import Foundation
import AppKit
import SwiftTerm

// ─────────────────────────────────────────────────────────────────────────────
// Settings — user-tunable config persisted to ~/.zush/settings.json.
//
// Fields are Codable; the file is written pretty-printed and sorted so diffs
// are readable and you can hand-edit it. Loads with sensible defaults for any
// missing keys (forward-compatible for future additions).
//
// The preferences pane binds directly to this struct; on save it calls
// SettingsStore.save + broadcasts a notification so the running view re-applies
// whatever's live-settable (font, colors, cursor). Fields marked "restart" in
// the UI need a fresh window to take effect (scrollback rebuilds the buffer).
// ─────────────────────────────────────────────────────────────────────────────

struct Settings: Codable, Equatable {
    var themeName: String = "Aura"
    var fontName: String = "Hack Nerd Font Mono"
    var fontSize: Double = 13
    /// "Thin strokes" on Retina — disables subpixel font smoothing which
    /// otherwise thickens glyphs on dark backgrounds. True = match iTerm's
    /// out-of-box thinner appearance; false = macOS default (heavier).
    var thinStrokes: Bool = true
    var cursorStyle: String = "steadyBlock"   // matches SwiftTerm.CursorStyle rawish name
    var scrollbackLines: Int = 10_000
    var useBrightColors: Bool = true
    var clipboardWriteAllowed: Bool = true

    // Window behavior
    var rememberWindowFrame: Bool = true
    var dragWithCmdClick: Bool = true
    var windowOpacity: Double = 1.0           // 0.5–1.0; anything lower gets illegible

    // Padding around the terminal grid (points). Top counts from below the
    // titlebar strip (contentLayoutGuide.top). Live-adjustable via Preferences.
    var paddingTop: Double = 0
    var paddingBottom: Double = 4
    var paddingLeading: Double = 0
    var paddingTrailing: Double = 0

    // Sessions Overview
    var overviewCompact: Bool = false

    // Long-idle notifications: alert when a command has been "running" (between
    // OSC 133;C and ;D) longer than idleNotifyThresholdSeconds. One alert per
    // stalled run — resets when the command completes.
    var idleNotifyEnabled: Bool = true
    var idleNotifyThresholdSeconds: Int = 60

    // Editor for ⌘-click on `path:line` — {path} and {line} are substituted.
    // Default uses `open` (system default handler, no line jump); override to
    // `code -g {path}:{line}` for VS Code or `subl {path}:{line}` for Sublime.
    var fileOpenCommand: String = "open {path}"

    // Per-window colored glow: deterministic tint per session so multiple
    // windows are visually distinguishable. Intensity is opacity 0.0-0.6.
    var windowGlowEnabled: Bool = true
    var windowGlowIntensity: Double = 0.40

    static let cursorStyles = ["blinkBlock","steadyBlock","blinkUnderline","steadyUnderline","blinkBar","steadyBar"]

    var swiftTermCursor: CursorStyle { CursorStyle.from(string: cursorStyle) ?? .steadyBlock }

    func nsFont() -> NSFont {
        NSFont(name: fontName, size: CGFloat(fontSize))
            ?? NSFont(name: "Menlo", size: CGFloat(fontSize))
            ?? NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
    }
}

/// Notification posted after Settings are saved so the running view can re-apply.
extension Notification.Name {
    static let zushSettingsChanged = Notification.Name("io.zyp.zupershell.settingsChanged")
}

final class SettingsStore {
    static let shared = SettingsStore()

    private let url: URL
    private(set) var current: Settings

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zush")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("settings.json")

        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            current = decoded
        } else {
            current = Settings()
            try? Self.write(current, to: url)   // seed the file on first launch
        }
    }

    func save(_ s: Settings) {
        current = s
        try? Self.write(s, to: url)
        NotificationCenter.default.post(name: .zushSettingsChanged, object: s)
    }

    private static func write(_ s: Settings, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(s).write(to: url, options: [.atomic])
    }

    var path: String { url.path }
}
