import Foundation
import Combine

// ─────────────────────────────────────────────────────────────────────────────
// SessionSummary — the "at-a-glance" state of one terminal session.
//
// Each SessionWindow owns one of these, mutates it in the OSC 133/cwd/clipboard
// handlers, and hands it to the coordinator's SessionsRegistry so the overview
// window can subscribe via SwiftUI @Published.
//
// The signed JSONL log remains the source of truth for forensics; this class
// is the *live* view for humans watching multiple agents.
// ─────────────────────────────────────────────────────────────────────────────

struct RecentCommand: Identifiable, Equatable {
    let id = UUID()
    let cmd: String
    let exit: Int?      // nil while still running
    let startedAt: Date
    let endedAt: Date?  // nil while still running
}

final class SessionSummary: ObservableObject, Identifiable {
    let id: String                       // sessionID from AuditLog
    let startedAt: Date
    @Published var title: String = "zupershell"
    @Published var cwd: String = ""
    /// True while we're between OSC 133;C and OSC 133;D — i.e. a command is
    /// executing right now. The overview draws a spinner for these.
    @Published var isRunning: Bool = false
    @Published var currentCommand: String? = nil
    @Published var lastCommand: String? = nil
    @Published var lastExit: Int? = nil
    @Published var commandCount: Int = 0
    @Published var lastActivity: Date
    @Published var clipboardWriteAttempts: Int = 0
    @Published var clipboardWritesDenied: Int = 0
    /// Ring buffer of the most recent commands (newest first). Capped at 12.
    @Published var recent: [RecentCommand] = []

    init(id: String) {
        self.id = id
        self.startedAt = Date()
        self.lastActivity = self.startedAt
    }

    // MARK: - Mutators (all called on main thread from SessionWindow's handlers)

    func noteTitle(_ t: String)   { title = t.isEmpty ? "zupershell" : t; lastActivity = Date() }
    func noteCWD(_ dir: String)   { cwd = dir; lastActivity = Date() }

    func noteCommandStart(_ cmd: String) {
        currentCommand = cmd
        isRunning = true
        commandCount += 1
        lastActivity = Date()
        recent.insert(RecentCommand(cmd: cmd, exit: nil, startedAt: Date(), endedAt: nil), at: 0)
        if recent.count > 12 { recent.removeLast(recent.count - 12) }
    }

    func noteCommandEnd(exit: Int) {
        isRunning = false
        lastCommand = currentCommand
        currentCommand = nil
        lastExit = exit
        lastActivity = Date()
        if !recent.isEmpty {
            var head = recent[0]
            head = RecentCommand(cmd: head.cmd, exit: exit, startedAt: head.startedAt, endedAt: Date())
            recent[0] = head
        }
    }

    func noteClipboardWrite(denied: Bool) {
        clipboardWriteAttempts += 1
        if denied { clipboardWritesDenied += 1 }
        lastActivity = Date()
    }
}

/// App-wide registry — the coordinator publishes this, the overview subscribes.
/// Ordering: newest sessions first (i.e. most recently added at the top).
final class SessionsRegistry: ObservableObject {
    @Published var summaries: [SessionSummary] = []

    func register(_ s: SessionSummary) {
        summaries.insert(s, at: 0)
    }

    func unregister(id: String) {
        summaries.removeAll { $0.id == id }
    }
}
