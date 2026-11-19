import Foundation
import CryptoKit

/// Tamper-evident audit trail: every entry embeds the SHA-256 of the previous entry, so editing or
/// deleting any line breaks the chain (`avm audit verify`). Lines are JSON so they ship straight
/// to a SIEM (Splunk, Datadog, Elastic) via any log forwarder.
public final class AuditLog: @unchecked Sendable {
    public struct Entry: Codable, Equatable {
        public var seq: Int
        public var ts: Date
        public var user: String
        public var host: String
        public var event: String
        public var vm: String?
        public var details: [String: String]
        public var prev: String
        public var hash: String
    }

    public static let shared = AuditLog(url: nil)
    private let explicitURL: URL?
    private let lock = NSLock()

    public init(url: URL?) { self.explicitURL = url }
    public var url: URL { explicitURL ?? Paths.audit }

    static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The digest covers the exact bytes written (with an empty hash field), so verification never
    /// depends on re-encoding — serializer changes can't produce false tamper alarms.
    static func digest(rawLine: Substring) -> (claimed: String, actual: String)? {
        guard let r = rawLine.range(of: #""hash":"[0-9a-f]{64}""#, options: .regularExpression) else { return nil }
        let claimed = String(rawLine[r].dropFirst(8).dropLast())
        var blank = rawLine
        blank.replaceSubrange(r, with: #""hash":"""#)
        return (claimed, sha(Data(blank.utf8)))
    }

    @discardableResult
    public func record(_ event: String, vm: String?, details: [String: String] = [:]) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        flock(fd, LOCK_EX) // cross-process
        defer { flock(fd, LOCK_UN) }
        let last = lastEntry()
        var e = Entry(seq: (last?.seq ?? 0) + 1,
                      ts: Date(),
                      user: NSUserName(),
                      host: ProcessInfo.processInfo.hostName,
                      event: event, vm: vm, details: details,
                      prev: last?.hash ?? String(repeating: "0", count: 64),
                      hash: "")
        guard let blank = try? JSON.compactEncoder.encode(e), let text = String(data: blank, encoding: .utf8) else { return nil }
        e.hash = Self.sha(blank)
        var line = Data(text.replacingOccurrences(of: #""hash":"""#, with: "\"hash\":\"\(e.hash)\"").utf8)
        line.append(0x0A)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        return e
    }

    private func lastEntry() -> Entry? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let back = min(size, 64 * 1024)
        try? fh.seek(toOffset: size - back)
        guard let data = try? fh.readToEnd(), let s = String(data: data, encoding: .utf8) else { return nil }
        guard let lastLine = s.split(separator: "\n").last else { return nil }
        return try? JSON.decoder.decode(Entry.self, from: Data(lastLine.utf8))
    }

    public func entries() -> [Entry] {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { try? JSON.decoder.decode(Entry.self, from: Data($0.utf8)) }
    }

    /// Returns nil if the chain is intact, else a description of the first break.
    public func verify() -> String? {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var prev = String(repeating: "0", count: 64)
        var seq = 0
        for (i, line) in s.split(separator: "\n").enumerated() {
            guard let e = try? JSON.decoder.decode(Entry.self, from: Data(line.utf8)) else {
                return "line \(i + 1): unparseable"
            }
            if e.prev != prev { return "line \(i + 1) (seq \(e.seq)): chain broken (prev hash mismatch)" }
            guard let d = Self.digest(rawLine: line), d.claimed == e.hash, d.actual == e.hash else {
                return "line \(i + 1) (seq \(e.seq)): entry modified (hash mismatch)"
            }
            if e.seq != seq + 1 { return "line \(i + 1): sequence gap (\(seq) → \(e.seq))" }
            prev = e.hash
            seq = e.seq
        }
        return nil
    }
}
