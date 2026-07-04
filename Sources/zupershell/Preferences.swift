import AppKit
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// Preferences window — SwiftUI form hosted in a native NSWindow.
//
// A tiny window controller keeps a strong reference so the window survives
// close-and-reopen; the SwiftUI Form binds directly to an @State copy of the
// Settings struct and calls SettingsStore.save on any edit, which fans out a
// notification to the running terminal view for live re-application.
//
// Fields that require restart to take effect (currently: scrollback) are shown
// with an inline note; everything else applies live.
// ─────────────────────────────────────────────────────────────────────────────

@available(macOS 13, *)
struct PreferencesView: View {
    @State private var s: Settings = SettingsStore.shared.current
    @State private var monospaceFonts: [String] = PreferencesView.discoverMonospaceFonts()

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $s.themeName) {
                    ForEach(Themes.all, id: \.name) { t in Text(t.name).tag(t.name) }
                }
                Picker("Font", selection: $s.fontName) {
                    ForEach(monospaceFonts, id: \.self) { Text($0).tag($0) }
                }
                Stepper(value: $s.fontSize, in: 9...24, step: 0.5) {
                    Text("Size: \(String(format: "%.1f", s.fontSize)) pt")
                }
                Toggle("Use bright colors for bold text", isOn: $s.useBrightColors)
            }

            Section("Cursor") {
                Picker("Style", selection: $s.cursorStyle) {
                    ForEach(Settings.cursorStyles, id: \.self) { Text(label(for: $0)).tag($0) }
                }
            }

            Section("Buffer") {
                Stepper(value: $s.scrollbackLines, in: 500...200_000, step: 500) {
                    Text("Scrollback: \(s.scrollbackLines.formatted()) lines")
                }
                Text("Scrollback changes apply on next window.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Security") {
                Toggle("Allow programmatic clipboard writes (OSC 52)", isOn: $s.clipboardWriteAllowed)
                Text("When off, sequences that write to your clipboard are logged and blocked. Every attempt is audited either way.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Reset to Defaults") { s = Settings(); save() }
                    Spacer()
                    Text(SettingsStore.shared.path)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 480, height: 520)
        .onChange(of: s) { _ in save() }
    }

    private func save() { SettingsStore.shared.save(s) }

    private func label(for key: String) -> String {
        switch key {
        case "blinkBlock":     return "Block (blinking)"
        case "steadyBlock":    return "Block"
        case "blinkUnderline": return "Underline (blinking)"
        case "steadyUnderline":return "Underline"
        case "blinkBar":       return "Bar (blinking)"
        case "steadyBar":      return "Bar"
        default: return key
        }
    }

    /// Enumerate mono-traited fonts from the system font manager; if any of our
    /// preferred families ("Nerd Font", "SF Mono", "Menlo") aren't classified
    /// mono by CoreText, they get added anyway so users can pick them.
    private static func discoverMonospaceFonts() -> [String] {
        let fm = NSFontManager.shared
        var set = Set(fm.availableFontFamilies.compactMap { family -> String? in
            guard let members = fm.availableMembers(ofFontFamily: family) else { return nil }
            for m in members {
                if let traits = m[3] as? Int, (NSFontTraitMask(rawValue: UInt(traits)).contains(.fixedPitchFontMask)) {
                    return family
                }
            }
            return nil
        })
        // Force-include common families (some Nerd Font TTFs miss the mono trait bit).
        for name in ["Hack Nerd Font Mono","JetBrains Mono","MesloLGS NF","SF Mono","Menlo","Monaco","Fira Code"]
            where NSFont(name: name, size: 12) != nil { set.insert(name) }
        return set.sorted()
    }
}

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PreferencesWindowController()

    private init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        w.title = "Zupershell Preferences"
        w.isReleasedWhenClosed = false
        if #available(macOS 13, *) {
            w.contentViewController = NSHostingController(rootView: PreferencesView())
        }
        super.init(window: w)
        w.delegate = self
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func showPreferences(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
