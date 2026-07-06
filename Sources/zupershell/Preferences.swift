import AppKit
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// Preferences — SwiftUI Form themed to match the terminal windows.
//
// Same design family as SessionsOverview: transparent titlebar, full-size
// content view, theme background flush behind the Form. Reactive via
// ThemeObservable so switching theme in this window re-tints the chrome + the
// tint on toggles/pickers/steppers in the same runloop tick.
// ─────────────────────────────────────────────────────────────────────────────

@available(macOS 13, *)
struct PreferencesView: View {
    @State private var s: Settings = SettingsStore.shared.current
    @State private var monospaceFonts: [String] = PreferencesView.discoverMonospaceFonts()
    @ObservedObject var themeObs: ThemeObservable

    private var theme: Theme { themeObs.theme }

    var body: some View {
        ZStack {
            Color(nsColor: theme.background).ignoresSafeArea()

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

                Section("Padding") {
                    Stepper(value: $s.paddingTop,      in: 0...40) { Text("Top: \(Int(s.paddingTop)) pt") }
                    Stepper(value: $s.paddingBottom,   in: 0...40) { Text("Bottom: \(Int(s.paddingBottom)) pt") }
                    Stepper(value: $s.paddingLeading,  in: 0...40) { Text("Leading: \(Int(s.paddingLeading)) pt") }
                    Stepper(value: $s.paddingTrailing, in: 0...40) { Text("Trailing: \(Int(s.paddingTrailing)) pt") }
                    caption("Space between the terminal grid and the window edges. Top starts below the titlebar strip. All four apply live.")
                }

                Section("Buffer") {
                    Stepper(value: $s.scrollbackLines, in: 500...200_000, step: 500) {
                        Text("Scrollback: \(s.scrollbackLines.formatted()) lines")
                    }
                    caption("Scrollback changes apply on next window.")
                }

                Section("Window") {
                    Toggle("Remember window position and size", isOn: $s.rememberWindowFrame)
                    Toggle("Move window with Cmd-drag from anywhere", isOn: $s.dragWithCmdClick)
                    Stepper(value: $s.windowOpacity, in: 0.5...1.0, step: 0.05) {
                        Text("Opacity: \(Int(s.windowOpacity * 100))%")
                    }
                    caption("Window frame changes apply on next window. Opacity and Cmd-drag apply live.")
                }

                Section("Security") {
                    Toggle("Allow programmatic clipboard writes (OSC 52)", isOn: $s.clipboardWriteAllowed)
                    caption("When off, sequences that write to your clipboard are logged and blocked. Every attempt is audited either way.")
                }

                Section {
                    HStack {
                        Button("Reset to Defaults") { s = Settings(); save() }
                            .buttonStyle(.bordered)
                            .tint(Color(nsColor: theme.cursor))
                        Spacer()
                        Text(SettingsStore.shared.path)
                            .font(.caption2)
                            .foregroundStyle(Color(nsColor: theme.ansi[8]))   // dim
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)          // hide the default Form bg so ours shows through
            .padding(.top, 8)                          // breathing room below transparent titlebar
            .tint(Color(nsColor: theme.cursor))        // toggle knob + selection tint = theme accent
        }
        .frame(width: 500, height: 560)
        .preferredColorScheme(.dark)
        .onChange(of: s) { _ in save() }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Color(nsColor: theme.ansi[8]))
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
        for name in ["Hack Nerd Font Mono","JetBrains Mono","MesloLGS NF","SF Mono","Menlo","Monaco","Fira Code"]
            where NSFont(name: name, size: 12) != nil { set.insert(name) }
        return set.sorted()
    }
}

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PreferencesWindowController()
    private let themeObs = ThemeObservable()
    private var settingsObserver: NSObjectProtocol?

    private init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "Zupershell Preferences"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false                  // ARC footgun avoidance
        w.appearance = NSAppearance(named: .darkAqua)
        let initial = Themes.byName(SettingsStore.shared.current.themeName)
        w.backgroundColor = initial.background
        if #available(macOS 13, *) {
            w.contentViewController = NSHostingController(rootView: PreferencesView(themeObs: themeObs))
        }
        super.init(window: w)
        w.delegate = self
        w.center()

        // Re-tint window chrome when the user changes theme from this window.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .zushSettingsChanged, object: nil, queue: .main
        ) { [weak w] n in
            guard let w, let s = n.object as? Settings else { return }
            w.backgroundColor = Themes.byName(s.themeName).background
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let o = settingsObserver { NotificationCenter.default.removeObserver(o) } }

    @objc func showPreferences(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
