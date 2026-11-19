import Foundation

/// High-level operations shared by the CLI, REST API, web portal and GUI.
public enum Manager {
    public static func summary(_ b: VMBundle) -> [String: Any] {
        var d: [String: Any] = ["name": b.name]
        guard let spec = try? b.loadSpec() else { d["state"] = "broken"; return d }
        d["os"] = spec.os.rawValue
        d["cpus"] = spec.cpus
        d["memoryMiB"] = spec.memoryMiB
        d["profile"] = spec.profile.rawValue
        d["labels"] = spec.labels
        d["isolated"] = spec.security.isolated
        d["disposable"] = spec.security.disposable
        d["encrypted"] = spec.security.encrypted
        let usage = b.diskUsage()
        d["diskLogicalBytes"] = usage.logical
        d["diskPhysicalBytes"] = usage.physical
        d["snapshots"] = SnapshotManager(bundle: b).list().count
        d["suspended"] = b.hasSavedState
        if b.isRunning, let st = ControlClient.status(b.name) {
            d["state"] = st["state"] ?? "running"
            d["runtime"] = st
        } else {
            d["state"] = b.isRunning ? "running" : (b.hasSavedState ? "suspended" : "stopped")
        }
        return d
    }

    public static func listAll() -> [[String: Any]] {
        var out = VMLibrary.list().map(summary)
        for (rec, unlocked) in EncryptedStore.list() where !unlocked {
            out.append(["name": rec.name, "state": "locked", "encrypted": true])
        }
        return out.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
    }

    /// Starts the VM in its own background process (crash isolation: one VM can't take others down).
    public static func start(_ name: String, gui: Bool = false, helper: String? = nil, timeout: TimeInterval = 60, discardState: Bool = false) throws {
        let b = try VMLibrary.find(name)
        if b.isRunning { return }
        var args = ["run", name]
        if !gui { args.append("--headless") }
        if discardState { args.append("--discard-state") }
        try? FileManager.default.removeItem(at: b.runLogURL)
        let pid = try Spawner.detached(Spawner.avmPath(helper), args, log: b.runLogURL)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let st = ControlClient.status(name), st["state"] as? String == "running" { return }
            if kill(pid, 0) != 0 {
                let log = (try? String(contentsOf: b.runLogURL, encoding: .utf8)) ?? ""
                throw AltVMError.message("VM process exited: \(log.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").suffix(3).joined(separator: " | "))")
            }
            usleep(200_000)
        }
        throw AltVMError.io("timed out waiting for \(name) to start")
    }

    public static func control(_ name: String, _ op: String, extra: [String: Any] = [:], timeout: Int = 120) throws -> Any {
        var req = extra
        req["op"] = op
        return try ControlClient.call(vm: name, req, timeout: timeout)
    }

    /// Blocks until the VM process is gone.
    public static func waitForExit(_ name: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let b = try? VMLibrary.find(name), b.isRunning else { return true }
            usleep(200_000)
        }
        return false
    }

    public static func stop(_ name: String, force: Bool = false, wait: TimeInterval = 60) throws {
        _ = try control(name, "stop", extra: ["force": force])
        if !waitForExit(name, timeout: wait) {
            if let pid = try VMLibrary.find(name).runningPID { kill(pid, SIGKILL) }
        }
    }

    public static func snapshot(_ name: String, label: String, note: String = "") throws -> [String: Any] {
        let b = try VMLibrary.find(name)
        if b.isRunning {
            return try control(name, "snapshot", extra: ["name": label, "note": note]) as? [String: Any] ?? [:]
        }
        let s = try SnapshotManager(bundle: b).create(name: label, note: note)
        return ["id": s.id, "name": s.name, "live": false]
    }

    public static func agent(_ name: String, _ op: String, params: [String: Any] = [:], timeout: Int = 300) throws -> [String: Any] {
        try control(name, "agent", extra: ["agentOp": op, "params": params, "timeout": timeout], timeout: timeout + 10) as? [String: Any] ?? [:]
    }

    public static func exec(_ name: String, command: [String], stdin: String = "", timeout: Int = 300) throws -> (Int, String, String) {
        _ = try waitForAgent(name, timeout: 60, op: "ping")
        let r = try agent(name, "exec", params: ["args": command, "stdin": stdin, "timeout": timeout], timeout: timeout)
        return (r["exitCode"] as? Int ?? -1, r["stdout"] as? String ?? "", r["stderr"] as? String ?? "")
    }

    public static func waitForAgent(_ name: String, timeout: TimeInterval, op: String = "info") throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            do { return try agent(name, op, timeout: 5) } catch { lastError = error }
            guard (try? VMLibrary.find(name))?.isRunning == true else { throw AltVMError.notRunning(name) }
            sleep(2)
        }
        throw lastError ?? AltVMError.io("guest agent timeout")
    }

    public static func ipAddresses(_ name: String) -> [String] {
        guard let info = try? agent(name, "info", timeout: 5), let ips = info["ips"] as? [[String: Any]] else { return [] }
        return ips.compactMap { $0["family"] as? String == "inet" ? $0["addr"] as? String : nil }
    }
}

// MARK: - Declarative fleet / Vmfile ("VMs as code", Terraform-style plan & apply)

public struct DesiredVM: Codable, Sendable {
    public var name: String
    /// "catalog:debian-13", "image:/path/x.avmimg", "https://host/x.avmimg", "iso:/path.iso", "blank"
    public var from: String
    public var os: GuestOS?
    public var profile: WorkloadProfile?
    public var cpus: Int?
    public var memoryMiB: UInt64?
    public var diskGiB: UInt64?
    public var switchName: String?
    public var isolated: Bool?
    public var disposable: Bool?
    public var labels: [String: String]?
    /// "running" | "stopped"
    public var state: String?
    /// Shell commands run once via the guest agent after first boot (idempotent: tracked by hash).
    public var provision: [String]?

    public init(name: String, from: String) { self.name = name; self.from = from }
}

public struct FleetFile: Codable, Sendable {
    public var organization: String?
    public var vms: [DesiredVM]
    public init(organization: String?, vms: [DesiredVM]) { self.organization = organization; self.vms = vms }
}

public enum Fleet {
    public struct Action: CustomStringConvertible, Sendable {
        public var vm: String
        public var kind: String
        public var detail: String
        public var description: String { "\(kind.padding(toLength: 10, withPad: " ", startingAt: 0)) \(vm)  \(detail)" }
    }

    public static func load(_ url: URL) throws -> FleetFile {
        let data = try Data(contentsOf: url)
        if let f = try? JSON.decoder.decode(FleetFile.self, from: data) { return f }
        return FleetFile(organization: nil, vms: [try JSON.decoder.decode(DesiredVM.self, from: data)])
    }

    public static func plan(_ fleet: FleetFile) -> [Action] {
        var actions: [Action] = []
        for d in fleet.vms {
            guard let b = try? VMLibrary.find(d.name), let spec = try? b.loadSpec() else {
                actions.append(Action(vm: d.name, kind: "create", detail: "from \(d.from)"))
                if d.provision?.isEmpty == false { actions.append(Action(vm: d.name, kind: "provision", detail: "\(d.provision!.count) step(s)")) }
                if d.state == "running" || d.provision?.isEmpty == false { actions.append(Action(vm: d.name, kind: "start", detail: "")) }
                if d.state == "stopped" && d.provision?.isEmpty == false { actions.append(Action(vm: d.name, kind: "stop", detail: "")) }
                continue
            }
            var changes: [String] = []
            if let c = d.cpus, c != spec.cpus { changes.append("cpus \(spec.cpus)→\(c)") }
            if let m = d.memoryMiB, m != spec.memoryMiB { changes.append("memory \(spec.memoryMiB)→\(m)") }
            if let p = d.profile, p != spec.profile { changes.append("profile \(spec.profile.rawValue)→\(p.rawValue)") }
            if let i = d.isolated, i != spec.security.isolated { changes.append("isolated→\(i)") }
            if let x = d.disposable, x != spec.security.disposable { changes.append("disposable→\(x)") }
            if let l = d.labels, l.contains(where: { spec.labels[$0.key] != $0.value }) { changes.append("labels") }
            if let g = d.diskGiB, let disk = spec.disks.first, g > disk.sizeGiB { changes.append("disk \(disk.sizeGiB)→\(g) GiB") }
            if !changes.isEmpty { actions.append(Action(vm: d.name, kind: "update", detail: changes.joined(separator: ", "))) }
            if let steps = d.provision, !steps.isEmpty, spec.labels["provisionHash"] != Signing.sha256(Data(steps.joined(separator: "\n").utf8)) {
                actions.append(Action(vm: d.name, kind: "provision", detail: "\(steps.count) step(s)"))
            }
            if d.state == "running" && !b.isRunning { actions.append(Action(vm: d.name, kind: "start", detail: "")) }
            if d.state == "stopped" && b.isRunning { actions.append(Action(vm: d.name, kind: "stop", detail: "")) }
        }
        return actions
    }

    public static func apply(_ fleet: FleetFile, helper: String? = nil, log: @escaping (String) -> Void) async throws {
        for d in fleet.vms {
            let exists = (try? VMLibrary.find(d.name)) != nil
            if !exists {
                log("creating \(d.name) from \(d.from)")
                try await create(d, log: log)
            }
            let b = try VMLibrary.find(d.name)
            var spec = try b.loadSpec()
            let before = spec
            if let c = d.cpus { spec.cpus = c }
            if let m = d.memoryMiB { spec.memoryMiB = m }
            if let p = d.profile { spec.profile = p }
            if let i = d.isolated { spec.security.isolated = i }
            if let x = d.disposable { spec.security.disposable = x }
            if let l = d.labels { spec.labels.merge(l) { _, n in n } }
            if let g = d.diskGiB, let disk = spec.disks.first, g > disk.sizeGiB, !b.isRunning {
                try DiskManager.resize(at: b.diskURL(disk), toGiB: g)
                spec.disks[0].sizeGiB = g
            }
            if spec != before {
                if let p = Policy.loadActive() { try p.enforce(spec) }
                try b.saveSpec(spec)
                log("updated \(d.name)\(b.isRunning ? " (takes effect on next boot)" : "")")
            }
            let steps = d.provision ?? []
            let hash = Signing.sha256(Data(steps.joined(separator: "\n").utf8))
            if !steps.isEmpty && spec.labels["provisionHash"] != hash {
                if !b.isRunning { log("starting \(d.name) for provisioning"); try Manager.start(d.name, helper: helper, timeout: 120) }
                log("waiting for guest agent in \(d.name)")
                _ = try Manager.waitForAgent(d.name, timeout: 300)
                _ = try? Manager.exec(d.name, command: ["cloud-init", "status", "--wait"], timeout: 900)
                for (i, step) in steps.enumerated() {
                    log("provision \(d.name) [\(i + 1)/\(steps.count)]: \(step)")
                    let (code, out, err) = try Manager.exec(d.name, command: ["/bin/sh", "-c", step], timeout: 1800)
                    if !out.isEmpty { log(out.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    guard code == 0 else { throw AltVMError.io("provision step \(i + 1) failed (exit \(code)): \(err)") }
                }
                spec = try b.loadSpec()
                spec.labels["provisionHash"] = hash
                try b.saveSpec(spec)
            }
            if d.state == "running" && !b.isRunning { log("starting \(d.name)"); try Manager.start(d.name, helper: helper) }
            if d.state == "stopped" && b.isRunning { log("stopping \(d.name)"); try Manager.stop(d.name) }
        }
        AuditLog.shared.record("fleet.apply", vm: nil, details: ["vms": fleet.vms.map(\.name).joined(separator: ",")])
    }

    static func create(_ d: DesiredVM, log: @escaping (String) -> Void) async throws {
        var o = CreateOptions(name: d.name)
        if let p = d.profile { o.profile = p }
        o.cpus = d.cpus
        o.memoryMiB = d.memoryMiB
        o.diskGiB = d.diskGiB
        o.switchName = d.switchName
        o.isolated = d.isolated ?? false
        o.disposable = d.disposable ?? false
        o.labels = d.labels ?? [:]
        if let os = d.os { o.os = os }
        let from = d.from
        if from.hasPrefix("catalog:") {
            let e = try Catalog.find(String(from.dropFirst(8)))
            o.os = e.os
            let file = try await Catalog.fetch(e) { p, _ in if Int(p * 100) % 10 == 0 { log("  download \(Int(p * 100))%") } }
            switch e.kind {
            case .cloudImage: try Provisioner.createFromCloudImage(o, image: file, progress: log)
            case .iso: try Provisioner.createFromISO(o, iso: file)
            default: throw AltVMError.unsupported("catalog kind \(e.kind.rawValue) in fleet files")
            }
        } else if from.hasPrefix("image:") {
            try GoldenImage.deploy(URL(fileURLWithPath: String(from.dropFirst(6))), as: d.name)
        } else if from.hasPrefix("https://") || from.hasPrefix("http://") {
            let url = URL(string: from)!
            let dest = Paths.images.appendingPathComponent(url.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try Paths.ensure()
                try await Downloader.download(url, to: dest) { _, _ in }
            }
            try GoldenImage.deploy(dest, as: d.name)
        } else if from.hasPrefix("iso:") {
            try Provisioner.createFromISO(o, iso: URL(fileURLWithPath: String(from.dropFirst(4))))
        } else if from == "blank" {
            try Provisioner.createBlank(o)
        } else {
            throw AltVMError.invalid("unknown source '\(from)'")
        }
    }
}
