import Foundation
import CryptoKit

// ─────────────────────────────────────────────────────────────────────────────
// AuditLog — "native EDR from inside the terminal."
//
// A tamper-evident, HMAC hash-chained JSONL feed. Every record carries:
//   • prev  — the previous record's hmac
//   • hmac  — HMAC-SHA256(key, canonical-JSON-of-this-record-without-hmac)
// so deleting or editing any line breaks the chain from that point forward.
// This mirrors the Cowork signed-audit.jsonl pattern (see cowatch notes).
//
// Because we ARE the terminal, this sensor sees 100% of the in-band traffic
// with no PTY tap — and, for OSC 52, it also owns the real clipboard effect
// (the seam a PTY-only sensor couldn't cover; cf. Part IV.5 of the doc).
//
// One instance per window/session. All instances share a single per-machine
// HMAC key on disk so any log can be verified independently.
// ─────────────────────────────────────────────────────────────────────────────

final class AuditLog {
    /// Per-machine HMAC key. Loaded once (thread-safe: `static let`), then
    /// reused by every AuditLog instance so a verifier only needs this one
    /// file to check any session log this machine has ever produced.
    /// Persisted at ~/.zush/audit.key (0600). A hardened build would move
    /// this to the Keychain.
    private static let key: SymmetricKey = {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".zush")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyURL = dir.appendingPathComponent("audit.key")
        if let d = try? Data(contentsOf: keyURL), d.count == 32 {
            return SymmetricKey(data: d)
        }
        let k = SymmetricKey(size: .bits256)
        let kd = k.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
        try? kd.write(to: keyURL, options: [.atomic])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return k
    }()

    private let handle: FileHandle?
    let sessionID: String
    let path: String

    private var seq = 0
    private var prevMac = "genesis"
    private let q = DispatchQueue(label: "zupershell.audit")
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Create a fresh audit log for a new session. Session ID = ISO8601
    /// timestamp + pid + 8-char UUID, so two windows opened in the same
    /// second still get distinct filenames.
    init() {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".zush")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        let shortUUID = String(UUID().uuidString.prefix(8))
        sessionID = "\(stamp)-\(ProcessInfo.processInfo.processIdentifier)-\(shortUUID)"

        let logURL = dir.appendingPathComponent("audit-\(sessionID).jsonl")
        path = logURL.path
        fm.createFile(atPath: logURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: logURL)
    }

    /// Block until all queued records are written and synced to disk.
    func flush() { q.sync { try? self.handle?.synchronize() } }

    /// Append one signed record. Safe to call from any thread (serialized).
    func log(_ type: String, _ fields: [String: Any] = [:]) {
        q.async { [weak self] in
            guard let self, let handle = self.handle else { return }
            self.seq += 1
            var rec: [String: Any] = [
                "seq": self.seq,
                "ts": self.iso.string(from: Date()),
                "session": self.sessionID,
                "type": type,
                "prev": self.prevMac,
            ]
            fields.forEach { rec[$0.key] = $0.value }

            // Canonical form (sorted keys) BEFORE adding hmac, so a verifier
            // can recompute it by stripping hmac and re-serializing sorted.
            let canon = (try? JSONSerialization.data(withJSONObject: rec, options: [.sortedKeys])) ?? Data()
            let macHex = HMAC<SHA256>.authenticationCode(for: canon, using: Self.key)
                .map { String(format: "%02x", $0) }.joined()
            rec["hmac"] = macHex
            self.prevMac = macHex

            if let line = try? JSONSerialization.data(withJSONObject: rec, options: [.sortedKeys]) {
                handle.write(line)
                handle.write(Data([0x0a]))
            }
        }
    }
}

func sha256hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
