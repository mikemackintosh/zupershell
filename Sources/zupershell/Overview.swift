import AppKit
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// Sessions Overview — "what's happening in each of my terminals right now."
//
// Built for the "I'm running Claude Code in three windows and I lose track"
// case. One row per open session, live-updated via @Published. Highlights:
//   • Green/red exit-code badge so failing agents pop.
//   • Spinner while a command is running (between OSC 133 C → D).
//   • Idle time counter that ticks in real time.
//   • Clipboard-write counter with a denied-vs-allowed split.
//   • Expandable "recent commands" strip per session.
// ─────────────────────────────────────────────────────────────────────────────

@available(macOS 13, *)
struct OverviewView: View {
    @ObservedObject var registry: SessionsRegistry
    /// Ticks every second so relative-time labels update without waiting on a
    /// summary mutation. Cheap: just re-renders the small time labels.
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if registry.summaries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "terminal").font(.system(size: 42)).foregroundStyle(.tertiary)
                    Text("No sessions open").font(.headline).foregroundStyle(.secondary)
                    Text("Open a window with ⌘N to start.").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(registry.summaries) { s in
                    SessionRow(s: s, now: now)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .onReceive(ticker) { now = $0 }
    }
}

@available(macOS 13, *)
struct SessionRow: View {
    @ObservedObject var s: SessionSummary
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(s.isRunning ? .yellow : (s.lastExit == 0 ? .green : (s.lastExit == nil ? .gray : .red)))
                    .frame(width: 8, height: 8)
                Text(s.title).font(.headline).lineLimit(1)
                Spacer()
                Text(relativeTime(from: s.lastActivity, to: now))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }

            if !s.cwd.isEmpty {
                Text(shortCWD(s.cwd)).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }

            if s.isRunning, let cmd = s.currentCommand {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(cmd).font(.system(.body, design: .monospaced)).lineLimit(1)
                }
            } else if let last = s.lastCommand {
                HStack(spacing: 6) {
                    if let ec = s.lastExit {
                        Text("\(ec)")
                            .font(.system(.caption, design: .monospaced).bold())
                            .foregroundStyle(ec == 0 ? .green : .red)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill((ec == 0 ? Color.green : Color.red).opacity(0.15)))
                    }
                    Text(last).font(.system(.body, design: .monospaced)).lineLimit(1).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Label("\(s.commandCount)", systemImage: "arrow.triangle.2.circlepath")
                if s.clipboardWriteAttempts > 0 {
                    Label(
                        s.clipboardWritesDenied > 0
                            ? "\(s.clipboardWritesDenied) blocked / \(s.clipboardWriteAttempts) cb"
                            : "\(s.clipboardWriteAttempts) cb writes",
                        systemImage: s.clipboardWritesDenied > 0 ? "shield.fill" : "doc.on.clipboard"
                    )
                    .foregroundStyle(s.clipboardWritesDenied > 0 ? Color.orange : Color.secondary)
                }
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 4)
    }

    private func shortCWD(_ p: String) -> String {
        // OSC 7 sends file://host/abs/path; strip the file:// prefix + host
        var s = p
        if s.hasPrefix("file://"), let idx = s.dropFirst(7).firstIndex(of: "/") {
            s = String(s[idx...])
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if s.hasPrefix(home) { s = "~" + s.dropFirst(home.count) }
        return s
    }

    private func relativeTime(from d: Date, to now: Date) -> String {
        let dt = Int(now.timeIntervalSince(d))
        if dt < 2 { return "just now" }
        if dt < 60 { return "\(dt)s ago" }
        if dt < 3600 { return "\(dt / 60)m ago" }
        return "\(dt / 3600)h ago"
    }
}

final class OverviewWindowController: NSWindowController, NSWindowDelegate {
    static let shared = OverviewWindowController()
    private let registry = AppDelegateBridge.registry

    private init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = "Sessions Overview"
        w.isReleasedWhenClosed = false     // same footgun as before
        if #available(macOS 13, *) {
            w.contentViewController = NSHostingController(rootView: OverviewView(registry: registry))
        }
        super.init(window: w)
        w.delegate = self
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func showOverview(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Static bridge so the OverviewWindowController can grab the app-wide
/// SessionsRegistry without needing a reference to AppDelegate at import time.
/// AppDelegate.installMenus() assigns this at launch.
enum AppDelegateBridge {
    static var registry = SessionsRegistry()
}
