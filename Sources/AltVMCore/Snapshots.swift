import Foundation

/// Snapshot tree. Each snapshot is a directory of APFS clones (copy-on-write, so taking one is
/// O(metadata) — milliseconds and ~0 bytes regardless of disk size). Live snapshots also contain
/// the full machine state so restoring resumes running apps exactly where they were.
public struct SnapshotInfo: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var parent: String?
    public var created: Date
    public var live: Bool
    public var note: String
    /// Physical bytes uniquely held by this snapshot (approximate).
    public var sizeBytes: UInt64?
}

public struct SnapshotManager {
    public let bundle: VMBundle

    public init(bundle: VMBundle) { self.bundle = bundle }

    var root: URL { bundle.snapshotsURL }
    var currentURL: URL { root.appendingPathComponent("current") }

    public var current: String? {
        (try? String(contentsOf: currentURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func dir(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    public func list() -> [SnapshotInfo] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { d -> SnapshotInfo? in
            guard let data = try? Data(contentsOf: d.appendingPathComponent("snapshot.json")) else { return nil }
            return try? JSON.decoder.decode(SnapshotInfo.self, from: data)
        }.sorted { $0.created < $1.created }
    }

    public func find(_ idOrName: String) throws -> SnapshotInfo {
        let all = list()
        if let s = all.first(where: { $0.id == idOrName }) ?? all.last(where: { $0.name == idOrName }) { return s }
        throw AltVMError.notFound("snapshot '\(idOrName)'")
    }

    /// Files that make up the VM's persistent state.
    func stateFiles(_ spec: VMSpec) -> [URL] {
        var files = spec.disks.filter { !$0.readOnly && !$0.file.hasPrefix("/") }.map { bundle.diskURL($0) }
        files += [bundle.efiVarsURL, bundle.auxStorageURL, bundle.machineIdentifierURL, bundle.hardwareModelURL]
        return files.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Offline (or paused) snapshot. `machineState` is a saved-state file to include (live snapshot).
    @discardableResult
    public func create(name: String, note: String = "", machineState: URL? = nil) throws -> SnapshotInfo {
        let spec = try bundle.loadSpec()
        let id = Self.newID()
        let d = dir(id)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        do {
            for f in stateFiles(spec) {
                try DiskManager.cloneFile(from: f, to: d.appendingPathComponent(f.lastPathComponent))
            }
            try DiskManager.cloneFile(from: bundle.specURL, to: d.appendingPathComponent("spec.json"))
            if let ms = machineState {
                try FileManager.default.moveItem(at: ms, to: d.appendingPathComponent("state.vzvmsave"))
            }
            let info = SnapshotInfo(id: id, name: name, parent: current, created: Date(), live: machineState != nil, note: note, sizeBytes: nil)
            try JSON.encoder.encode(info).write(to: d.appendingPathComponent("snapshot.json"))
            try id.write(to: currentURL, atomically: true, encoding: .utf8)
            try enforceRetention(spec: spec)
            AuditLog.shared.record("snapshot.create", vm: spec.name, details: ["id": id, "name": name, "live": "\(info.live)"])
            return info
        } catch {
            try? FileManager.default.removeItem(at: d)
            throw error
        }
    }

    /// Roll the VM back to a snapshot. VM must be stopped.
    public func restore(_ idOrName: String) throws {
        if bundle.isRunning { throw AltVMError.running(bundle.name) }
        let snap = try find(idOrName)
        let d = dir(snap.id)
        let files = (try FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil))
        try? FileManager.default.removeItem(at: bundle.savedStateURL)
        for f in files where f.lastPathComponent != "snapshot.json" {
            let target: URL = f.lastPathComponent == "state.vzvmsave" ? bundle.savedStateURL : bundle.url.appendingPathComponent(f.lastPathComponent)
            let tmp = target.appendingPathExtension("restoring")
            try? FileManager.default.removeItem(at: tmp)
            try DiskManager.cloneFile(from: f, to: tmp)
            _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
        }
        try snap.id.write(to: currentURL, atomically: true, encoding: .utf8)
        AuditLog.shared.record("snapshot.restore", vm: bundle.name, details: ["id": snap.id, "name": snap.name])
    }

    public func delete(_ idOrName: String) throws {
        let snap = try find(idOrName)
        // Re-parent children so the tree stays connected.
        for var child in list() where child.parent == snap.id {
            child.parent = snap.parent
            try JSON.encoder.encode(child).write(to: dir(child.id).appendingPathComponent("snapshot.json"))
        }
        try FileManager.default.removeItem(at: dir(snap.id))
        if current == snap.id {
            if let p = snap.parent { try p.write(to: currentURL, atomically: true, encoding: .utf8) }
            else { try? FileManager.default.removeItem(at: currentURL) }
        }
        AuditLog.shared.record("snapshot.delete", vm: bundle.name, details: ["id": snap.id])
    }

    /// Render the tree as text (like `git log --graph`, but for VMs).
    public func tree() -> String {
        let all = list()
        let cur = current
        var out = ""
        func walk(_ parent: String?, _ indent: String) {
            let kids = all.filter { $0.parent == parent }
            for (i, s) in kids.enumerated() {
                let last = i == kids.count - 1
                let marker = s.id == cur ? " ← current" : ""
                let live = s.live ? " [live]" : ""
                let df = ISO8601DateFormatter()
                out += "\(indent)\(last ? "└─" : "├─") \(s.name) (\(s.id))\(live) \(df.string(from: s.created))\(marker)\n"
                walk(s.id, indent + (last ? "   " : "│  "))
            }
        }
        let ids = Set(all.map(\.id))
        walk(nil, "")
        for orphan in all where orphan.parent != nil && !ids.contains(orphan.parent!) {
            out += "?─ \(orphan.name) (\(orphan.id)) [orphan]\n"
            walk(orphan.id, "   ")
        }
        return out.isEmpty ? "(no snapshots)\n" : out
    }

    func enforceRetention(spec: VMSpec) throws {
        guard let max = Policy.loadActive()?.maxSnapshotsPerVM, max > 0 else { return }
        var all = list()
        while all.count > max, let oldest = all.first(where: { $0.id != current }) {
            try delete(oldest.id)
            all = list()
        }
    }

    static func newID() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        df.timeZone = TimeZone(identifier: "UTC")
        return "\(df.string(from: Date()))-\(String(UInt32.random(in: 0...0xFFFF), radix: 16))"
    }
}
