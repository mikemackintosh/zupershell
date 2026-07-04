#!/usr/bin/env swift
import Foundation
import CryptoKit

// Verify a zupershell audit log: recompute each record's HMAC and check the
// prev→hmac hash chain. Uses the same JSONSerialization(.sortedKeys)
// canonicalization as the writer, so the bytes match exactly.
//
//   swift verify-audit.swift ~/.zupershell/audit-<session>.jsonl

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: swift verify-audit.swift <audit-*.jsonl>\n".utf8))
    exit(2)
}

let keyURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zush/audit.key")
guard let keyData = try? Data(contentsOf: keyURL), keyData.count == 32 else {
    print("✗ cannot read key at \(keyURL.path)"); exit(1)
}
let key = SymmetricKey(data: keyData)

guard let text = try? String(contentsOfFile: args[1], encoding: .utf8) else {
    print("✗ cannot read log \(args[1])"); exit(1)
}

var prev = "genesis"
var n = 0
for (i, rawLine) in text.split(separator: "\n").enumerated() {
    guard let data = rawLine.data(using: .utf8),
          var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let storedMac = obj["hmac"] as? String,
          let recPrev = obj["prev"] as? String
    else { print("✗ line \(i + 1): unparseable"); exit(1) }

    if recPrev != prev {
        print("✗ line \(i + 1): CHAIN BREAK — prev=\(recPrev), expected \(prev)"); exit(1)
    }
    obj["hmac"] = nil
    let canon = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    let mac = HMAC<SHA256>.authenticationCode(for: canon, using: key)
        .map { String(format: "%02x", $0) }.joined()
    if mac != storedMac {
        print("✗ line \(i + 1): HMAC MISMATCH — record was tampered"); exit(1)
    }
    prev = storedMac
    n += 1
}
print("✓ verified \(n) records — chain intact, no tampering")
