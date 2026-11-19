import Foundation

public enum AltVMError: LocalizedError, CustomStringConvertible {
    case notFound(String)
    case alreadyExists(String)
    case invalid(String)
    case policy(String)
    case running(String)
    case notRunning(String)
    case unsupported(String)
    case io(String)
    case message(String)

    public var description: String {
        switch self {
        case .notFound(let s): return "not found: \(s)"
        case .alreadyExists(let s): return "already exists: \(s)"
        case .invalid(let s): return "invalid: \(s)"
        case .policy(let s): return "blocked by policy: \(s)"
        case .running(let s): return "VM is running: \(s)"
        case .notRunning(let s): return "VM is not running: \(s)"
        case .unsupported(let s): return "unsupported: \(s)"
        case .io(let s): return "I/O error: \(s)"
        case .message(let s): return s
        }
    }
    public var errorDescription: String? { description }
}

/// Filesystem layout. Overridable with $ALTVM_HOME for tests, CI runners and MDM-managed layouts.
public enum Paths {
    public static var home: URL {
        if let env = ProcessInfo.processInfo.environment["ALTVM_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AltVM", isDirectory: true)
    }
    public static var vms: URL { home.appendingPathComponent("VMs", isDirectory: true) }
    public static var cache: URL { home.appendingPathComponent("Cache", isDirectory: true) }
    public static var images: URL { home.appendingPathComponent("Images", isDirectory: true) }
    public static var policy: URL { home.appendingPathComponent("policy.json") }
    public static var trustedKeys: URL { home.appendingPathComponent("trusted-keys", isDirectory: true) }
    public static var audit: URL { home.appendingPathComponent("audit.jsonl") }
    public static var switches: URL { home.appendingPathComponent("switches", isDirectory: true) }
    public static var apiToken: URL { home.appendingPathComponent("api-token") }
    public static var encrypted: URL { home.appendingPathComponent("Encrypted", isDirectory: true) }

    public static func ensure() throws {
        for d in [home, vms, cache, images, trustedKeys, switches, encrypted] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }
}

/// A VM on disk: `<name>.altvm/` containing spec.json, disks, platform identity, EFI store,
/// saved state and snapshots.
public struct VMBundle: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public var specURL: URL { url.appendingPathComponent("spec.json") }
    public var auxStorageURL: URL { url.appendingPathComponent("aux.img") }
    public var hardwareModelURL: URL { url.appendingPathComponent("hardware-model.bin") }
    public var machineIdentifierURL: URL { url.appendingPathComponent("machine-id.bin") }
    public var efiVarsURL: URL { url.appendingPathComponent("efi-vars.fd") }
    public var savedStateURL: URL { url.appendingPathComponent("state.vzvmsave") }
    public var snapshotsURL: URL { url.appendingPathComponent("snapshots", isDirectory: true) }
    public var controlSocketURL: URL { Runtime.controlSocket(name) }
    public var pidURL: URL { url.appendingPathComponent("run.pid") }
    public var consoleLogURL: URL { url.appendingPathComponent("console.log") }
    public var runLogURL: URL { url.appendingPathComponent("run.log") }

    public func diskURL(_ disk: DiskSpec) -> URL {
        disk.file.hasPrefix("/") ? URL(fileURLWithPath: disk.file) : url.appendingPathComponent(disk.file)
    }

    public var name: String { url.deletingPathExtension().lastPathComponent }

    public func loadSpec() throws -> VMSpec {
        let data = try Data(contentsOf: specURL)
        return try JSON.decoder.decode(VMSpec.self, from: data)
    }

    public func saveSpec(_ spec: VMSpec) throws {
        let data = try JSON.encoder.encode(spec)
        try data.write(to: specURL, options: .atomic)
    }

    /// PID of the process currently running this VM, if alive.
    public var runningPID: pid_t? {
        guard let s = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return kill(pid, 0) == 0 ? pid : nil
    }

    /// Running = some process holds the exclusive run lock (authoritative), or a live pid file.
    public var isRunning: Bool {
        let fd = open(url.appendingPathComponent("run.lock").path, O_RDONLY)
        if fd >= 0 {
            defer { close(fd) }
            if flock(fd, LOCK_EX | LOCK_NB) != 0 { return true }
            flock(fd, LOCK_UN)
        }
        return runningPID != nil
    }
    public var hasSavedState: Bool { FileManager.default.fileExists(atPath: savedStateURL.path) }

    /// Logical and physical (allocated) bytes across all bundle files.
    public func diskUsage() -> (logical: UInt64, physical: UInt64) {
        var logical: UInt64 = 0, physical: UInt64 = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        if let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) {
            for case let f as URL in en {
                guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                logical += UInt64(v.fileSize ?? 0)
                physical += UInt64(v.totalFileAllocatedSize ?? 0)
            }
        }
        return (logical, physical)
    }
}

public enum JSON {
    /// ISO-8601 with milliseconds (ordering of events within one second matters: snapshots, audit).
    static func formatDate(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
    static let dateEncoding = JSONEncoder.DateEncodingStrategy.custom { date, enc in
        var c = enc.singleValueContainer()
        try c.encode(formatDate(date))
    }
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = dateEncoding
        return e
    }
    public static var compactEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = dateEncoding
        return e
    }
    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = parseDate(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid date \(s)")
            }
            return date
        }
        return d
    }
}

/// The VM library: create, find, list, clone, delete.
public enum VMLibrary {
    public static func bundleURL(named name: String) -> URL {
        Paths.vms.appendingPathComponent("\(name).altvm", isDirectory: true)
    }

    public static func validateName(_ name: String) throws {
        let ok = name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil
        if !ok { throw AltVMError.invalid("VM name '\(name)' (use letters, digits, . _ -; max 64)") }
    }

    public static func find(_ name: String) throws -> VMBundle {
        let url = bundleURL(named: name)
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("spec.json").path) else {
            throw AltVMError.notFound("VM '\(name)'")
        }
        return VMBundle(url: url)
    }

    public static func list() -> [VMBundle] {
        try? Paths.ensure()
        let items = (try? FileManager.default.contentsOfDirectory(at: Paths.vms, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "altvm" }
            .map { VMBundle(url: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.specURL.path) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Creates the bundle directory, sparse disks and spec. OS-specific platform files
    /// (macOS aux storage, EFI variable store) are produced by `PlatformFactory`.
    @discardableResult
    public static func create(spec: VMSpec, policy: Policy? = Policy.loadActive(), createDisks: Bool = true) throws -> VMBundle {
        try validateName(spec.name)
        try Paths.ensure()
        if let policy {
            let v = policy.violations(spec, existingVMCount: list().count)
            if !v.isEmpty { throw AltVMError.policy(v.joined(separator: "; ")) }
        }
        let url = bundleURL(named: spec.name)
        if FileManager.default.fileExists(atPath: url.path) { throw AltVMError.alreadyExists("VM '\(spec.name)'") }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bundle = VMBundle(url: url)
        do {
            for disk in spec.disks where createDisks && !disk.file.hasPrefix("/") && !disk.readOnly {
                try DiskManager.createSparse(at: bundle.diskURL(disk), sizeGiB: disk.sizeGiB)
            }
            try FileManager.default.createDirectory(at: bundle.snapshotsURL, withIntermediateDirectories: true)
            try bundle.saveSpec(spec)
            if spec.os != .macOS { try PlatformFactory.createEFIStore(bundle: bundle, secureBoot: spec.security.secureBoot) }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        AuditLog.shared.record("vm.create", vm: spec.name, details: ["os": spec.os.rawValue, "cpus": "\(spec.cpus)", "memoryMiB": "\(spec.memoryMiB)"])
        return bundle
    }

    /// Instant copy-on-write clone using APFS clonefile(2): a 100 GB VM clones in milliseconds
    /// and consumes zero extra space until blocks diverge. Identity (MAC, machine id) is regenerated.
    @discardableResult
    public static func clone(_ source: String, to dest: String, linked: Bool = true) throws -> VMBundle {
        try validateName(dest)
        let src = try find(source)
        if src.isRunning { throw AltVMError.running(source) }
        let dstURL = bundleURL(named: dest)
        if FileManager.default.fileExists(atPath: dstURL.path) { throw AltVMError.alreadyExists("VM '\(dest)'") }
        try DiskManager.cloneTree(from: src.url, to: dstURL)
        let bundle = VMBundle(url: dstURL)
        // Clones don't inherit runtime artifacts or snapshots.
        for f in [bundle.savedStateURL, bundle.pidURL, bundle.controlSocketURL, bundle.consoleLogURL, bundle.runLogURL, bundle.machineIdentifierURL] {
            try? FileManager.default.removeItem(at: f)
        }
        try? FileManager.default.removeItem(at: bundle.snapshotsURL)
        try FileManager.default.createDirectory(at: bundle.snapshotsURL, withIntermediateDirectories: true)
        var spec = try bundle.loadSpec()
        spec.name = dest
        spec.created = Date()
        spec.network = spec.network.map { var n = $0; n.macAddress = MACAddress.random(); return n }
        spec.labels["clonedFrom"] = source
        try bundle.saveSpec(spec)
        // New cloud-init identity: hostname, instance-id (→ fresh SSH host keys, machine-id).
        if spec.disks.contains(where: { $0.file == "seed.iso" }) {
            try? CloudInit.writeSeed(to: bundle.url.appendingPathComponent("seed.iso"), spec: spec, options: CreateOptions(name: dest))
        }
        AuditLog.shared.record("vm.clone", vm: dest, details: ["source": source])
        return bundle
    }

    public static func delete(_ name: String) throws {
        let b = try find(name)
        if b.isRunning { throw AltVMError.running(name) }
        try FileManager.default.removeItem(at: b.url)
        AuditLog.shared.record("vm.delete", vm: name)
    }

    public static func rename(_ name: String, to newName: String) throws {
        try validateName(newName)
        let b = try find(name)
        if b.isRunning { throw AltVMError.running(name) }
        let dst = bundleURL(named: newName)
        if FileManager.default.fileExists(atPath: dst.path) { throw AltVMError.alreadyExists(newName) }
        try FileManager.default.moveItem(at: b.url, to: dst)
        let nb = VMBundle(url: dst)
        var spec = try nb.loadSpec()
        spec.name = newName
        try nb.saveSpec(spec)
        AuditLog.shared.record("vm.rename", vm: newName, details: ["from": name])
    }
}
