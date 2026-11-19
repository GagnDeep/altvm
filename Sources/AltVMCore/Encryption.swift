import Foundation
import CryptoKit
import Security

/// Encrypted VMs: the whole bundle (disks, RAM saves, snapshots) lives inside an AES-256
/// encrypted APFS sparse bundle. Locked = unmounted = unreadable. With an org escrow key in the
/// policy, IT can recover the passphrase (X25519 + ChaChaPoly sealed box) — so encrypted VMs are
/// "locked to the organisation" without IT ever needing the user's passphrase up front.
public enum EncryptedStore {
    public struct Record: Codable, Sendable {
        public var name: String
        public var created: Date
        public var escrowed: Bool
        public var sizeGiB: UInt64
    }

    static func image(_ name: String) -> URL { Paths.encrypted.appendingPathComponent("\(name).sparsebundle") }
    static func record(_ name: String) -> URL { Paths.encrypted.appendingPathComponent("\(name).json") }
    static func escrow(_ name: String) -> URL { Paths.encrypted.appendingPathComponent("\(name).escrow") }

    public static func list() -> [(Record, unlocked: Bool)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.encrypted, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { f in
            guard let r = try? JSON.decoder.decode(Record.self, from: Data(contentsOf: f)) else { return nil }
            return (r, isUnlocked(r.name))
        }
    }

    public static func isEncrypted(_ name: String) -> Bool { FileManager.default.fileExists(atPath: record(name).path) }

    public static func isUnlocked(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: VMLibrary.bundleURL(named: name).appendingPathComponent("spec.json").path)
    }

    /// Convert an existing VM to an encrypted one.
    public static func encrypt(_ name: String, passphrase: String, storeInKeychain: Bool) throws {
        let bundle = try VMLibrary.find(name)
        if bundle.isRunning { throw AltVMError.running(name) }
        if isEncrypted(name) { throw AltVMError.alreadyExists("encrypted store for \(name)") }
        try Paths.ensure()
        let usage = bundle.diskUsage().logical
        let sizeGiB = max(32, usage / (1 << 30) * 2 + 16)
        try hdiutil(["create", "-quiet", "-size", "\(sizeGiB)g", "-type", "SPARSEBUNDLE", "-fs", "APFS",
                     "-encryption", "AES-256", "-stdinpass", "-volname", "AltVM-\(name)", image(name).path], stdin: passphrase)
        let mnt = FileManager.default.temporaryDirectory.appendingPathComponent("altvm-enc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
        do {
            try attach(name, passphrase: passphrase, at: mnt)
            // Sparse-preserving copy of the bundle's contents into the encrypted volume root.
            for item in try FileManager.default.contentsOfDirectory(at: bundle.url, includingPropertiesForKeys: nil) {
                let r = copyfile(item.path, mnt.appendingPathComponent(item.lastPathComponent).path, nil,
                                 copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_DATA_SPARSE))
                guard r == 0 else { throw AltVMError.io("copy \(item.lastPathComponent) into encrypted volume failed: \(String(cString: strerror(errno)))") }
            }
            // Verify before the plaintext is ever removed: every file present with identical size.
            for item in try FileManager.default.contentsOfDirectory(at: bundle.url, includingPropertiesForKeys: nil) where !item.hasDirectoryPath {
                let copy = mnt.appendingPathComponent(item.lastPathComponent)
                guard DiskManager.logicalSize(copy) == DiskManager.logicalSize(item) else {
                    throw AltVMError.io("encrypted copy verification failed for \(item.lastPathComponent); plaintext left untouched")
                }
            }
            try hdiutil(["detach", "-quiet", mnt.path])
        } catch {
            _ = try? hdiutil(["detach", "-quiet", "-force", mnt.path])
            try? FileManager.default.removeItem(at: image(name))
            throw error
        }
        try? FileManager.default.removeItem(at: mnt)
        var spec = try bundle.loadSpec()
        spec.security.encrypted = true
        // Wipe plaintext.
        try FileManager.default.removeItem(at: bundle.url)
        var escrowed = false
        if let pk = Policy.loadActive()?.escrowPublicKey {
            try sealEscrow(passphrase, to: pk).write(to: escrow(name))
            escrowed = true
        }
        try JSON.encoder.encode(Record(name: name, created: Date(), escrowed: escrowed, sizeGiB: sizeGiB)).write(to: record(name))
        if storeInKeychain { try Keychain.set(passphrase, account: name) }
        // Mark spec encrypted inside the volume.
        try unlock(name, passphrase: passphrase)
        try VMLibrary.find(name).saveSpec(spec)
        try lock(name)
        AuditLog.shared.record("vm.encrypt", vm: name, details: ["escrowed": "\(escrowed)"])
    }

    public static func unlock(_ name: String, passphrase: String? = nil) throws {
        guard isEncrypted(name) else { throw AltVMError.notFound("encrypted VM '\(name)'") }
        if isUnlocked(name) { return }
        guard let pw = passphrase ?? Keychain.get(account: name) else {
            throw AltVMError.invalid("passphrase required (none in Keychain)")
        }
        let mp = VMLibrary.bundleURL(named: name)
        try FileManager.default.createDirectory(at: mp, withIntermediateDirectories: true)
        do { try attach(name, passphrase: pw, at: mp) } catch {
            try? FileManager.default.removeItem(at: mp)
            AuditLog.shared.record("vm.unlock-failed", vm: name)
            throw AltVMError.policy("wrong passphrase or damaged encrypted store")
        }
        AuditLog.shared.record("vm.unlock", vm: name)
    }

    public static func lock(_ name: String) throws {
        let mp = VMLibrary.bundleURL(named: name)
        if VMBundle(url: mp).isRunning { throw AltVMError.running(name) }
        try hdiutil(["detach", "-quiet", mp.path])
        try? FileManager.default.removeItem(at: mp)
        AuditLog.shared.record("vm.lock", vm: name)
    }

    static func attach(_ name: String, passphrase: String, at mountpoint: URL) throws {
        try hdiutil(["attach", "-quiet", "-nobrowse", "-owners", "on", "-stdinpass", "-mountpoint", mountpoint.path, image(name).path], stdin: passphrase)
    }

    @discardableResult
    static func hdiutil(_ args: [String], stdin: String? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = args
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = inp
        try p.run()
        if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? inp.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else { throw AltVMError.io("hdiutil \(args.first ?? ""): \(s.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return s
    }

    // MARK: escrow

    public static func generateEscrowKey() -> (privateKey: String, publicKey: String) {
        let k = Curve25519.KeyAgreement.PrivateKey()
        return (k.rawRepresentation.base64EncodedString(), k.publicKey.rawRepresentation.base64EncodedString())
    }

    static func sealEscrow(_ secret: String, to publicKey: String) throws -> Data {
        guard let pkData = Data(base64Encoded: publicKey) else { throw AltVMError.invalid("escrow public key") }
        let pk = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pkData)
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let shared = try eph.sharedSecretFromKeyAgreement(with: pk)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("altvm-escrow".utf8), sharedInfo: Data(), outputByteCount: 32)
        let box = try ChaChaPoly.seal(Data(secret.utf8), using: key)
        return eph.publicKey.rawRepresentation + box.combined
    }

    public static func recover(_ name: String, escrowPrivateKey: String) throws -> String {
        let blob = try Data(contentsOf: escrow(name))
        guard blob.count > 32, let skData = Data(base64Encoded: escrowPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw AltVMError.invalid("escrow data/key")
        }
        let sk = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: skData)
        let eph = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: blob.prefix(32))
        let shared = try sk.sharedSecretFromKeyAgreement(with: eph)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("altvm-escrow".utf8), sharedInfo: Data(), outputByteCount: 32)
        let plain = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: blob.dropFirst(32)), using: key)
        AuditLog.shared.record("vm.escrow-recover", vm: name)
        return String(decoding: plain, as: UTF8.self)
    }
}

public enum Keychain {
    static let service = "AltVM VM passphrase"

    public static func set(_ secret: String, account: String) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let s = SecItemAdd(add as CFDictionary, nil)
        guard s == errSecSuccess else { throw AltVMError.io("Keychain error \(s)") }
    }

    public static func get(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
}
