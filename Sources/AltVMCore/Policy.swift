import Foundation

/// Enterprise policy. Distributed signed (Ed25519) by IT, verified against trusted keys that are
/// deployed via MDM (Jamf/Intune/Kandji) into /Library/Application Support/AltVM/trusted-keys.
/// A tampered or unverifiable policy fails *closed* (lockdown), never open.
public struct Policy: Codable, Equatable, Sendable {
    public var organization: String
    public var version: Int = 1
    public var issued: Date = Date()
    public var description: String = ""

    // Resource limits
    public var maxCPUs: Int?
    public var maxMemoryMiB: UInt64?
    public var maxDiskGiB: UInt64?
    public var maxVMs: Int?
    public var allowedOS: [GuestOS]?

    // Integration controls
    public var allowSharedFolders: Bool = true
    public var allowClipboard: Bool = true
    public var allowMicrophone: Bool = true
    public var allowUSBPassthrough: Bool = true
    public var allowBridgedNetworking: Bool = true
    public var allowNATNetworking: Bool = true
    public var allowedSharedFolderRoots: [String]?
    /// Remote display / AI computer-use (screen capture + input injection). Optional so older
    /// policy files decode; nil means allowed.
    public var allowRemoteDisplay: Bool?

    // Security requirements
    public var requireEncryption: Bool = false
    public var requireSecureBoot: Bool = false
    public var requireIsolation: Bool = false
    /// VMs created on this Mac are bound to `organization` and can't run elsewhere/after offboarding.
    public var bindToOrganization: Bool = false
    /// Only golden images signed by these keys may be deployed (empty = any trusted key).
    public var requireSignedImages: Bool = false
    public var allowedImageSigners: [String] = []
    /// Users cannot change VM settings; only IT (via `avm apply` with signed specs) can.
    public var lockSettings: Bool = false
    /// Maximum VM age in days (contractor / training VMs auto-expire).
    public var maxVMAgeDays: Int?
    /// Keep at most N snapshots per VM (storage hygiene).
    public var maxSnapshotsPerVM: Int?
    /// X25519 public key: passphrases of encrypted VMs are escrowed to it for IT recovery.
    public var escrowPublicKey: String?

    public init(organization: String) { self.organization = organization }

    public static func lockdown(reason: String) -> Policy {
        var p = Policy(organization: "LOCKDOWN")
        p.description = "Fail-closed: \(reason)"
        p.maxVMs = 0
        p.allowedOS = []
        p.allowSharedFolders = false
        p.allowClipboard = false
        p.allowMicrophone = false
        p.allowUSBPassthrough = false
        p.allowBridgedNetworking = false
        p.allowNATNetworking = false
        p.allowRemoteDisplay = false
        p.lockSettings = true
        return p
    }

    // MARK: enforcement

    public func violations(_ spec: VMSpec, existingVMCount: Int? = nil) -> [String] {
        var v: [String] = []
        if let m = maxCPUs, spec.cpus > m { v.append("cpus \(spec.cpus) > max \(m)") }
        if let m = maxMemoryMiB, spec.memoryMiB > m { v.append("memory \(spec.memoryMiB) MiB > max \(m) MiB") }
        if let m = maxDiskGiB {
            let total = spec.disks.reduce(0) { $0 + $1.sizeGiB }
            if total > m { v.append("disk total \(total) GiB > max \(m) GiB") }
        }
        if let m = maxVMs, let n = existingVMCount, n >= m { v.append("VM count limit \(m) reached") }
        if let os = allowedOS, !os.contains(spec.os) { v.append("guest OS \(spec.os.rawValue) not allowed") }
        let ig = spec.integration
        if !allowSharedFolders && !ig.sharedFolders.isEmpty && !spec.security.isolated { v.append("shared folders are disabled") }
        if let roots = allowedSharedFolderRoots {
            for f in ig.sharedFolders {
                let p = (f.hostPath as NSString).expandingTildeInPath
                if !roots.contains(where: { p.hasPrefix(($0 as NSString).expandingTildeInPath) }) {
                    v.append("shared folder \(p) outside allowed roots")
                }
            }
        }
        if !allowClipboard && ig.clipboard && !spec.security.isolated { v.append("clipboard sharing is disabled") }
        if !allowMicrophone && ig.microphone { v.append("microphone is disabled") }
        if !allowUSBPassthrough && !ig.usbPassthrough.isEmpty { v.append("USB passthrough is disabled") }
        for n in spec.network where !spec.security.isolated {
            if n.mode == .bridged && !allowBridgedNetworking { v.append("bridged networking is disabled") }
            if n.mode == .nat && !allowNATNetworking { v.append("NAT networking is disabled") }
        }
        if requireEncryption && !spec.security.encrypted { v.append("encryption is required") }
        if requireSecureBoot && spec.os != .macOS && spec.kernel == nil && !spec.security.secureBoot { v.append("secure boot is required") }
        if requireIsolation && !spec.security.isolated { v.append("isolated mode is required") }
        if bindToOrganization && spec.security.organization != organization {
            v.append("VM must be bound to organization '\(organization)'")
        }
        if let days = maxVMAgeDays, Date().timeIntervalSince(spec.created) > Double(days) * 86400 {
            v.append("VM is older than \(days) days")
        }
        if let exp = spec.security.expires, exp < Date() { v.append("VM expired on \(exp)") }
        return v
    }

    public func enforce(_ spec: VMSpec) throws {
        let v = violations(spec, existingVMCount: nil)
        if !v.isEmpty { throw AltVMError.policy(v.joined(separator: "; ")) }
    }

    /// Mutates a spec so it complies where that's possible (used when users import VMs).
    public func remediate(_ spec: inout VMSpec) {
        if let m = maxCPUs { spec.cpus = min(spec.cpus, m) }
        if let m = maxMemoryMiB { spec.memoryMiB = min(spec.memoryMiB, m) }
        if !allowSharedFolders { spec.integration.sharedFolders = [] }
        if !allowClipboard { spec.integration.clipboard = false }
        if !allowMicrophone { spec.integration.microphone = false }
        if !allowUSBPassthrough { spec.integration.usbPassthrough = [] }
        if !allowBridgedNetworking {
            spec.network = spec.network.map { var n = $0; if n.mode == .bridged { n.mode = .nat }; return n }
        }
        if requireIsolation { spec.security.isolated = true }
        if requireSecureBoot && spec.os != .macOS { spec.security.secureBoot = true }
        if bindToOrganization { spec.security.organization = organization }
    }

    // MARK: signed distribution

    public struct Signed: Codable {
        public var payload: String     // base64(JSON(policy))
        public var signature: String   // base64(Ed25519(payload bytes))
        public var publicKey: String
    }

    public func sign(with keyURL: URL) throws -> Signed {
        let key = try Signing.loadPrivateKey(keyURL)
        let data = try JSON.compactEncoder.encode(self)
        return Signed(payload: data.base64EncodedString(),
                      signature: try Signing.sign(data, with: key),
                      publicKey: key.publicKey.rawRepresentation.base64EncodedString())
    }

    public static func verify(_ signed: Signed, trusted: [String] = Signing.trustedKeys()) throws -> Policy {
        guard trusted.contains(signed.publicKey) else { throw AltVMError.policy("policy signer is not a trusted key") }
        guard let data = Data(base64Encoded: signed.payload) else { throw AltVMError.invalid("policy payload") }
        guard Signing.verify(data, signature: signed.signature, publicKey: signed.publicKey) else {
            throw AltVMError.policy("policy signature is invalid (tampered?)")
        }
        return try JSON.decoder.decode(Policy.self, from: data)
    }

    /// System (MDM) policy wins over user policy.
    public static var searchPaths: [URL] {
        [URL(fileURLWithPath: "/Library/Application Support/AltVM/policy.json"), Paths.policy]
    }

    /// Returns the active verified policy, nil if none installed, or a lockdown policy if a
    /// policy file exists but fails verification.
    public static func loadActive() -> Policy? {
        for url in searchPaths where FileManager.default.fileExists(atPath: url.path) {
            do {
                let signed = try JSON.decoder.decode(Signed.self, from: Data(contentsOf: url))
                return try verify(signed)
            } catch {
                return .lockdown(reason: "\(url.path): \(error.localizedDescription)")
            }
        }
        return nil
    }

    public static func install(_ signed: Signed) throws {
        _ = try verify(signed)
        try Paths.ensure()
        try JSON.encoder.encode(signed).write(to: Paths.policy, options: .atomic)
        AuditLog.shared.record("policy.install", vm: nil, details: ["signer": String(signed.publicKey.prefix(16))])
    }
}
