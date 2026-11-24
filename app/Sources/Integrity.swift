import CryptoKit
import Foundation

/// Signs finished sessions in the log, so XP and levels can't be inflated by editing log.jsonl by hand. The key is a
/// random secret in the data folder (owner-only). lockin is open source, so this stops casual edits, not someone
/// rebuilding the app; that's the honest limit of any local scoreboard.
enum Integrity {
    private static let keyFile = Paths.dir.appendingPathComponent(".integrity")
    private static let fields = ["ts", "task", "planned_min", "focused_min", "active_min", "offline_min", "completed"]

    private static let key: SymmetricKey = {
        if let d = try? Data(contentsOf: keyFile), d.count == 32 { return SymmetricKey(data: d) }
        let k = SymmetricKey(size: .bits256)
        try? k.withUnsafeBytes { Data($0) }.write(to: keyFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        return k
    }()

    /// Values the same way whether they came from Swift (Bool, Int) or back out of JSON (NSNumber).
    private static func text(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    static func sign(_ entry: [String: Any]) -> String {
        let message = fields.map { text(entry[$0]) }.joined(separator: "|")
        return HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key).map { String(format: "%02x", $0) }.joined()
    }

    static func valid(_ entry: [String: Any]) -> Bool {
        guard let sig = entry["sig"] as? String else { return false }
        return sig == sign(entry)
    }
}
