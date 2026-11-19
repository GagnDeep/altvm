import Foundation
import CryptoKit

/// Ed25519 signing used for policies, golden images and fleet manifests.
public enum Signing {
    public struct KeyPair {
        public let privateKey: Curve25519.Signing.PrivateKey
        public var publicKeyBase64: String { privateKey.publicKey.rawRepresentation.base64EncodedString() }
    }

    public static func generate() -> KeyPair { KeyPair(privateKey: .init()) }

    /// Writes `<name>.key` (0600) and `<name>.pub`.
    public static func writeKeyPair(_ kp: KeyPair, to dir: URL, name: String) throws -> (URL, URL) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let priv = dir.appendingPathComponent("\(name).key")
        let pub = dir.appendingPathComponent("\(name).pub")
        if FileManager.default.fileExists(atPath: priv.path) { throw AltVMError.alreadyExists(priv.path) }
        try Data(kp.privateKey.rawRepresentation.base64EncodedString().utf8).write(to: priv)
        chmod(priv.path, 0o600)
        try Data((kp.publicKeyBase64 + "\n").utf8).write(to: pub)
        return (priv, pub)
    }

    public static func loadPrivateKey(_ url: URL) throws -> Curve25519.Signing.PrivateKey {
        let s = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let d = Data(base64Encoded: s) else { throw AltVMError.invalid("private key \(url.path)") }
        return try .init(rawRepresentation: d)
    }

    public static func loadPublicKey(_ base64: String) throws -> Curve25519.Signing.PublicKey {
        guard let d = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw AltVMError.invalid("public key")
        }
        return try .init(rawRepresentation: d)
    }

    public static func sign(_ data: Data, with key: Curve25519.Signing.PrivateKey) throws -> String {
        try key.signature(for: data).base64EncodedString()
    }

    public static func verify(_ data: Data, signature: String, publicKey: String) -> Bool {
        guard let sig = Data(base64Encoded: signature), let pk = try? loadPublicKey(publicKey) else { return false }
        return pk.isValidSignature(sig, for: data)
    }

    /// Public keys trusted on this Mac (user dir + MDM-managed system dir).
    public static func trustedKeys() -> [String] {
        var keys: [String] = []
        let dirs = [Paths.trustedKeys, URL(fileURLWithPath: "/Library/Application Support/AltVM/trusted-keys")]
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.pathExtension == "pub" {
                if let s = try? String(contentsOf: f, encoding: .utf8) {
                    keys.append(s.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
        return keys
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Streaming SHA-256 of a (possibly huge, sparse) file.
    public static func sha256(file url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var h = SHA256()
        while true {
            let chunk = try fh.read(upToCount: 8 << 20) ?? Data()
            if chunk.isEmpty { break }
            h.update(data: chunk)
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
