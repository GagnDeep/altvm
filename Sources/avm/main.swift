import Foundation
import AppKit
import AltVMCore
import Virtualization

// MARK: - argument parsing

struct Args {
    var positionals: [String] = []
    var flags: [String: [String]] = [:]
    var passthrough: [String] = []   // after `--`

    init(_ argv: [String], boolFlags: Set<String>) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a == "--" { passthrough = Array(argv[(i + 1)...]); break }
            if a.hasPrefix("--") {
                var key = String(a.dropFirst(2))
                if let eq = key.firstIndex(of: "=") {
                    flags[String(key[..<eq]), default: []].append(String(key[key.index(after: eq)...]))
                } else if boolFlags.contains(key) || (key.hasPrefix("no-") && boolFlags.contains(String(key.dropFirst(3))))
                            || i + 1 >= argv.count || argv[i + 1].hasPrefix("--") {
                    if key.hasPrefix("no-") { key = String(key.dropFirst(3)); flags[key, default: []].append("false") }
                    else { flags[key, default: []].append("true") }
                } else {
                    flags[key, default: []].append(argv[i + 1]); i += 1
                }
            } else if a.hasPrefix("-") && a.count == 2 && a != "-" {
                flags[String(a.dropFirst()), default: []].append("true")
            } else {
                positionals.append(a)
            }
            i += 1
        }
    }
    func str(_ k: String) -> String? { flags[k]?.last }
    func bool(_ k: String) -> Bool { flags[k]?.last.map { $0 != "false" } ?? false }
    func int(_ k: String) -> Int? { str(k).flatMap(Int.init) }
    func list(_ k: String) -> [String] { flags[k] ?? [] }
    func pos(_ i: Int, _ what: String) throws -> String {
        guard i < positionals.count else { throw AltVMError.invalid("missing <\(what)>") }
        return positionals[i]
    }
}

let boolFlags: Set<String> = ["json", "gui", "headless", "console", "recovery", "force", "yes", "isolated", "disposable",
                              "secure-boot", "start", "no-share", "share", "keychain", "trust", "dry-run", "macos", "blank",
                              "linked", "read-write", "escrow", "wait", "help", "live", "stdin", "i", "scaled", "print", "discard-state", "lifecycle", "snapshot", "fallback"]

func parseMemory(_ s: String) throws -> UInt64 {
    let u = s.uppercased()
    if u.hasSuffix("G") || u.hasSuffix("GB") || u.hasSuffix("GIB") {
        guard let v = Double(u.trimmingCharacters(in: CharacterSet.letters)) else { throw AltVMError.invalid("memory \(s)") }
        return UInt64(v * 1024)
    }
    if u.hasSuffix("M") || u.hasSuffix("MB") || u.hasSuffix("MIB") {
        guard let v = UInt64(u.trimmingCharacters(in: CharacterSet.letters)) else { throw AltVMError.invalid("memory \(s)") }
        return v
    }
    guard let v = UInt64(u) else { throw AltVMError.invalid("memory \(s) (use e.g. 8G or 4096M)") }
    return v < 512 ? v * 1024 : v
}

func printJSON(_ obj: Any) {
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) {
        print(String(decoding: d, as: UTF8.self))
    }
}

func printEncodable<T: Encodable>(_ v: T) {
    if let d = try? JSON.encoder.encode(v) { print(String(decoding: d, as: UTF8.self)) }
}

final class ProgressBar: @unchecked Sendable {
    private var last = -1
    private let label: String
    private let tty = isatty(STDERR_FILENO) == 1
    init(_ label: String) { self.label = label }
    func update(_ p: Double, _ extra: String = "") {
        let pct = Int(max(0, min(1, p)) * 100)
        guard pct != last else { return }
        last = pct
        if tty {
            let w = 30, fill = pct * w / 100
            FileHandle.standardError.write(Data("\r\(label) [\(String(repeating: "█", count: fill))\(String(repeating: "·", count: w - fill))] \(pct)% \(extra)   ".utf8))
            if pct == 100 { FileHandle.standardError.write(Data("\n".utf8)) }
        } else if pct % 10 == 0 {
            FileHandle.standardError.write(Data("\(label) \(pct)%\n".utf8))
        }
    }
}

func readPassphrase(_ prompt: String) -> String {
    if let env = ProcessInfo.processInfo.environment["ALTVM_PASSPHRASE"] { return env }
    if isatty(STDIN_FILENO) == 0 { return readLine(strippingNewline: true) ?? "" }
    return String(cString: getpass(prompt))
}

func table(_ rows: [[String]]) {
    guard let first = rows.first else { return }
    var widths = first.map(\.count)
    for r in rows { for (i, c) in r.enumerated() where i < widths.count { widths[i] = max(widths[i], c.count) } }
    for (n, r) in rows.enumerated() {
        let line = r.enumerated().map { $1.padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined(separator: "  ")
        print(n == 0 ? "\u{1B}[1m\(line)\u{1B}[0m" : line)
    }
}

let usage = """
AltVM — virtual machines for Apple silicon. Every feature, every edition, no limits.

LIFECYCLE
  avm list [--json]                       List machines
  avm create <name> [source] [options]    Create a machine
      sources: --catalog <id> | --iso <file> | --image <file.avmimg|url> | --macos [--ipsw f] | --blank
      options: --profile productivity|gaming|design|development|server|travel
               --cpus N --memory 8G --disk 64 --user U --password P --no-share
               --isolated --disposable --secure-boot --switch <net> --package <pkg>... --start
  avm start <vm> [--gui] [--discard-state] Start in background (or with a window)
  avm run <vm> [--headless|--console]     Run in the foreground
  avm stop <vm> [--force]                 Graceful shutdown (agent → ACPI → force)
  avm suspend|pause|resume|restart <vm>
  avm info <vm> [--json]                  Details, live status
  avm set <vm> key=value...               cpus memory profile adaptive isolated disposable clipboard
                                          rosetta audio mic agent boot=efi|fast notes label.K=V share+=name:path share-=name
  avm clone <vm> <new>                    Instant copy-on-write clone
  avm rename <vm> <new> | delete <vm> --yes
  avm disk resize <vm> <GiB> | compact <vm>
  avm memory <vm> <size>                  Live memory target via the balloon (e.g. 2G)
  avm repair <vm>                         Force a file-system check on next boot
  avm eject <vm>                          Detach installer media after an ISO install

GUEST
  avm exec <vm> [-i] -- <cmd...>          Run a command in the guest (vsock agent, no network needed); -i forwards stdin
  avm ip <vm> | ssh <vm> [args]
  avm usb attach <vm> <image> [--read-write] | detach <vm> <id>

COMPUTER USE (any guest OS, headless — for AI agents and automation)
  avm screenshot <vm> [out.png] [--max 1280]   avm click|double-click|right-click <vm> X Y
  avm move <vm> X Y   avm type <vm> <text...>   avm key <vm> cmd+space   avm scroll <vm> X Y --dy 3   avm drag <vm> X Y X2 Y2
  avm vnc <vm> [--print]                  Open the VM display in Screen Sharing
  avm mcp                                 MCP server (stdio) so AI agents can drive VMs
  avm agent <vm> "<task>"                 Built-in Claude computer-use agent

SNAPSHOTS
  avm snapshot create <vm> <name> [--note]   Live (with RAM) if running, instant CoW either way
  avm snapshot list|tree <vm> | restore <vm> <snap> | delete <vm> <snap>

NETWORKS
  avm switch create <name> [--subnet 10.77.5] | list | run <name>
  avm switch set <name> --preset 3g | --latency MS --jitter MS --loss PCT --bandwidth KBPS

ENTERPRISE
  avm image pack <vm> <out.avmimg> [--sign key] [--version V] [--description D]
  avm image inspect <file> | deploy <file|url> <name>
  avm apply <fleet.json> [--dry-run]       Declarative VMs-as-code (plan / apply)
  avm keys generate <name> [--trust] [--escrow] | trust <file.pub>
  avm policy init <org> | sign <policy.json> --key <k> | install <signed.json> | show | check <vm>
  avm encrypt <vm> [--keychain] | unlock <vm> | lock <vm> | recover <vm> --escrow-key <file>
  avm audit show [--n 50] | verify | export
  avm serve [--port 8484] [--listen 127.0.0.1]   REST API + web console + /metrics

HOST
  avm host | catalog | metrics | macos-latest | rosetta install | version
"""

// MARK: - command implementations

@MainActor
enum CLI {
    static func main(_ argv: [String]) async throws {
        guard let cmd = argv.first else { print(usage); return }
        let a = Args(Array(argv.dropFirst()), boolFlags: boolFlags)
        if a.bool("help") { print(usage); return }
        switch cmd {
        case "help", "-h", "--help": print(usage)
        case "version", "--version": print("avm 1.0.0 (AltVM) — Virtualization.framework, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        case "list", "ls": list(a)
        case "host": printEncodable(HostInfo.current())
        case "catalog": catalog()
        case "create": try await create(a)
        case "start":
            let name = try a.pos(0, "vm")
            if EncryptedStore.isEncrypted(name) && !EncryptedStore.isUnlocked(name) { try EncryptedStore.unlock(name, passphrase: nil) }
            try Manager.start(name, gui: a.bool("gui"), discardState: a.bool("discard-state"))
            print("\(name) started")
        case "stop":
            let name = try a.pos(0, "vm")
            try Manager.stop(name, force: a.bool("force"))
            print("\(name) stopped")
        case "suspend":
            let name = try a.pos(0, "vm")
            _ = try Manager.control(name, "suspend")
            _ = Manager.waitForExit(name, timeout: 300)
            print("\(name) suspended (resumes instantly on next start)")
        case "pause", "resume":
            printJSON(try Manager.control(try a.pos(0, "vm"), cmd))
        case "restart":
            let name = try a.pos(0, "vm")
            try Manager.stop(name, force: a.bool("force"))
            try Manager.start(name)
            print("\(name) restarted")
        case "info": try info(a)
        case "set": try set(a)
        case "clone":
            let b = try VMLibrary.clone(try a.pos(0, "vm"), to: try a.pos(1, "new name"))
            print("cloned → \(b.name) (copy-on-write: \(formatBytes(b.diskUsage().physical)) physically allocated)")
        case "rename":
            try VMLibrary.rename(try a.pos(0, "vm"), to: try a.pos(1, "new name"))
        case "delete", "rm":
            let name = try a.pos(0, "vm")
            guard a.bool("yes") else { throw AltVMError.invalid("refusing to delete without --yes") }
            try VMLibrary.delete(name)
            print("deleted \(name)")
        case "disk": try disk(a)
        case "exec": try exec(a)
        case "ip":
            let ips = Manager.ipAddresses(try a.pos(0, "vm"))
            if ips.isEmpty { throw AltVMError.io("no IP reported by guest agent") }
            ips.forEach { print($0) }
        case "ssh": try ssh(a)
        case "usb": try usb(a)
        case "snapshot", "snap": try snapshot(a)
        case "switch": try switchCmd(a)
        case "image": try await image(a)
        case "apply": try await apply(a)
        case "keys": try keys(a)
        case "policy": try policy(a)
        case "encrypt":
            if a.positionals.first == "recover" { try recover(a); return }
            let name = try a.pos(0, "vm")
            let p1 = readPassphrase("New passphrase: ")
            if isatty(STDIN_FILENO) == 1 && ProcessInfo.processInfo.environment["ALTVM_PASSPHRASE"] == nil {
                guard readPassphrase("Repeat: ") == p1 else { throw AltVMError.invalid("passphrases differ") }
            }
            guard p1.count >= 8 else { throw AltVMError.invalid("passphrase must be at least 8 characters") }
            try EncryptedStore.encrypt(name, passphrase: p1, storeInKeychain: a.bool("keychain"))
            print("\(name) is now encrypted (AES-256) and locked. Unlock with: avm unlock \(name)")
        case "recover": try recover(a)
        case "unlock":
            let name = try a.pos(0, "vm")
            let pw = Keychain.get(account: name) ?? readPassphrase("Passphrase for \(name): ")
            try EncryptedStore.unlock(name, passphrase: pw)
            print("\(name) unlocked")
        case "lock":
            try EncryptedStore.lock(try a.pos(0, "vm"))
            print("locked")
        case "audit": try audit(a)
        case "serve": try serve(a)
        case "metrics": print(Metrics.prometheus(), terminator: "")
        case "rosetta":
            #if arch(arm64)
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                VZLinuxRosettaDirectoryShare.installRosetta { e in if let e { c.resume(throwing: e) } else { c.resume() } }
            }
            print("Rosetta installed")
            #endif
        case "screenshot", "click", "double-click", "right-click", "move", "drag", "scroll", "key", "type":
            try computer(cmd, a)
        case "vnc", "view":
            let name = try a.pos(0, "vm")
            let r = try Manager.control(name, "vnc") as? [String: Any] ?? [:]
            let url = r["url"] as? String ?? ""
            print(url)
            if !a.bool("print") {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = [url]
                try? p.run()
            }
        case "agent":
            let name = try a.pos(0, "vm")
            let task = a.positionals.dropFirst().joined(separator: " ")
            guard !task.isEmpty else { throw AltVMError.invalid("usage: avm agent <vm> \"<task>\"") }
            var c = AgentRunner.Config(vm: name, task: task)
            if let m = a.str("model") { c.model = m }
            if let e = a.str("effort") { c.effort = e }
            if let n = a.int("max-steps") { c.maxSteps = n }
            if a.flags["snapshot"]?.last == "false" { c.snapshotFirst = false }
            if a.flags["fallback"]?.last == "false" { c.fallbacks = false }
            let runner = AgentRunner(config: c) { print($0) }
            let outcome = try runner.run()
            print("tokens: \(runner.inputTokens) in / \(runner.outputTokens) out")
            switch outcome {
            case .done(let summary): print("✓ done\(summary.isEmpty ? "" : ": \(summary)")")
            case .refused(let why): print("✗ Claude declined: \(why)"); exit(4)
            case .stepLimit: print("✗ step limit reached (\(c.maxSteps)); raise --max-steps or refine the task"); exit(5)
            case .error(let e): print("✗ \(e)"); exit(1)
            }
        case "mcp":
            let server = MCPServer()
            if let vms = a.str("vms") { server.allowedVMs = Set(vms.split(separator: ",").map(String.init)) }
            if a.flags["lifecycle"]?.last == "false" { server.allowLifecycle = false }
            server.helper = Spawner.avmPath()
            server.run()
        case "memory":
            let name = try a.pos(0, "vm")
            let mib = try parseMemory(try a.pos(1, "size (e.g. 1.5G)"))
            let r = try Manager.control(name, "memory", extra: ["mib": Int(mib)]) as? [String: Any] ?? [:]
            print("\(name): guest memory target \(r["targetMiB"] ?? mib) MiB (live, via balloon)")
        case "repair":
            let name = try a.pos(0, "vm")
            let b = try VMLibrary.find(name)
            var spec = try b.loadSpec()
            guard spec.kernel != nil else { throw AltVMError.unsupported("repair boot needs FastBoot (kernel boot); boot the guest's rescue mode instead") }
            if b.isRunning { try Manager.stop(name) }
            spec.labels["repairOnNextBoot"] = "true"
            try b.saveSpec(spec)
            try Manager.start(name)
            print("\(name) booting with a forced, repairing filesystem check")
        case "macos-latest":
            #if arch(arm64)
            let img = try await VZMacOSRestoreImage.latestSupported
            let v = img.operatingSystemVersion
            print("macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion) (\(img.buildVersion))")
            print("supported on this Mac: \(img.mostFeaturefulSupportedConfiguration?.hardwareModel.isSupported == true)")
            print(img.url.absoluteString)
            #endif
        case "eject":
            let name = try a.pos(0, "vm")
            try Provisioner.ejectInstallMedia(name)
            print("install media detached")
        default:
            throw AltVMError.invalid("unknown command '\(cmd)' — run `avm help`")
        }
    }

    /// Computer-use from the shell: everything an AI agent (or a script) needs to drive a GUI.
    static func computer(_ cmd: String, _ a: Args) throws {
        let name = try a.pos(0, "vm")
        func int(_ i: Int, _ what: String) throws -> Int {
            guard let v = Int(try a.pos(i, what)) else { throw AltVMError.invalid("\(what) must be a number") }
            return v
        }
        var req: [String: Any] = ["scaled": a.bool("scaled")]
        switch cmd {
        case "screenshot":
            req["action"] = "screenshot"
            if let m = a.int("max") { req["maxDimension"] = m }
            let r = try Manager.control(name, "computer", extra: req) as? [String: Any] ?? [:]
            guard let b64 = r["png"] as? String, let png = Data(base64Encoded: b64) else { throw AltVMError.io("no screenshot") }
            let out = a.positionals.count > 1 ? a.positionals[1] : "\(name)-screenshot.png"
            try png.write(to: URL(fileURLWithPath: (out as NSString).expandingTildeInPath))
            print("\(out) \(r["width"] ?? 0)x\(r["height"] ?? 0) (display \(r["displayWidth"] ?? 0)x\(r["displayHeight"] ?? 0))")
            return
        case "click", "double-click", "right-click":
            req["action"] = cmd.replacingOccurrences(of: "-", with: "_")
            req["x"] = try int(1, "x"); req["y"] = try int(2, "y")
            if let b = a.str("button") { req["button"] = b }
        case "move":
            req["action"] = "move"; req["x"] = try int(1, "x"); req["y"] = try int(2, "y")
        case "drag":
            req["action"] = "drag"; req["x"] = try int(1, "x"); req["y"] = try int(2, "y"); req["x2"] = try int(3, "x2"); req["y2"] = try int(4, "y2")
        case "scroll":
            req["action"] = "scroll"; req["x"] = try int(1, "x"); req["y"] = try int(2, "y"); req["dy"] = a.int("dy") ?? 3; req["dx"] = a.int("dx") ?? 0
        case "key":
            req["action"] = "key"; req["keys"] = try a.pos(1, "keys (e.g. cmd+space)")
        case "type":
            req["action"] = "type"; req["text"] = a.positionals.dropFirst().joined(separator: " ")
        default: break
        }
        _ = try Manager.control(name, "computer", extra: req)
    }

    static func list(_ a: Args) {
        let all = Manager.listAll()
        if a.bool("json") { printJSON(all); return }
        var rows = [["NAME", "STATE", "OS", "CPU", "RAM", "DISK USED", "SNAPS", "FLAGS"]]
        for v in all {
            let flags = [v["isolated"] as? Bool == true ? "isolated" : nil, v["disposable"] as? Bool == true ? "disposable" : nil,
                         v["encrypted"] as? Bool == true ? "encrypted" : nil].compactMap { $0 }.joined(separator: ",")
            rows.append([v["name"] as? String ?? "", v["state"] as? String ?? "", v["os"] as? String ?? "",
                         (v["cpus"] as? Int).map(String.init) ?? "", (v["memoryMiB"] as? UInt64).map { $0 % 1024 == 0 ? "\($0 / 1024)G" : String(format: "%.1fG", Double($0) / 1024) } ?? "",
                         (v["diskPhysicalBytes"] as? UInt64).map(formatBytes) ?? "", (v["snapshots"] as? Int).map(String.init) ?? "", flags])
        }
        if all.isEmpty { print("No machines. Try: avm create dev --catalog debian-13 --start"); return }
        table(rows)
    }

    static func catalog() {
        var rows = [["ID", "TYPE", "TITLE"]]
        for e in Catalog.entries { rows.append([e.id, e.kind.rawValue, e.title]) }
        table(rows)
    }

    static func create(_ a: Args) async throws {
        let name = try a.pos(0, "name")
        var o = CreateOptions(name: name)
        if let p = a.str("profile") {
            guard let prof = WorkloadProfile(rawValue: p) else { throw AltVMError.invalid("profile \(p)") }
            o.profile = prof
        }
        if let os = a.str("os") {
            guard let g = GuestOS(rawValue: os) else { throw AltVMError.invalid("os \(os)") }
            o.os = g
        }
        o.cpus = a.int("cpus")
        if let m = a.str("memory") { o.memoryMiB = try parseMemory(m) }
        if let d = a.int("disk") { o.diskGiB = UInt64(d) }
        if let u = a.str("user") { o.username = u }
        o.password = a.str("password")
        if a.flags["share"]?.last == "false" || a.bool("no-share") { o.shareHome = false }
        o.isolated = a.bool("isolated")
        o.disposable = a.bool("disposable")
        o.secureBoot = a.bool("secure-boot")
        o.switchName = a.str("switch")
        o.packages = a.list("package")
        for l in a.list("label") {
            let kv = l.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { o.labels[kv[0]] = kv[1] }
        }
        let bundle: VMBundle
        if let id = a.str("catalog") ?? a.str("from").map({ $0.replacingOccurrences(of: "catalog:", with: "") }) {
            let e = try Catalog.find(id)
            if e.kind == .macOS { return try await createMac(o, a) }
            if e.kind == .manual { throw AltVMError.unsupported("\(e.title): \(e.notes)") }
            o.os = e.os
            let bar = ProgressBar("download \(e.id)")
            let file = try await Catalog.fetch(e) { p, _ in bar.update(p) }
            bundle = e.kind == .cloudImage
                ? try Provisioner.createFromCloudImage(o, image: file) { FileHandle.standardError.write(Data("  \($0)\n".utf8)) }
                : try Provisioner.createFromISO(o, iso: file)
        } else if let iso = a.str("iso") {
            bundle = try Provisioner.createFromISO(o, iso: URL(fileURLWithPath: (iso as NSString).expandingTildeInPath))
        } else if let img = a.str("image") {
            let bar = ProgressBar("deploy")
            if img.hasPrefix("http") {
                try await Fleet.apply(FleetFile(organization: nil, vms: [DesiredVM(name: name, from: img)]), log: { print($0) })
                bundle = try VMLibrary.find(name)
            } else {
                bundle = try GoldenImage.deploy(URL(fileURLWithPath: img), as: name) { bar.update($0) }
            }
        } else if a.bool("macos") || o.os == .macOS {
            return try await createMac(o, a)
        } else {
            bundle = try Provisioner.createBlank(o)
        }
        let spec = try bundle.loadSpec()
        print("created \(spec.name): \(spec.os.displayName), \(spec.cpus) vCPU, \(spec.memoryMiB / 1024) GB RAM, profile \(spec.profile.rawValue)")
        if a.bool("start") {
            try Manager.start(name, gui: a.bool("gui"))
            print("\(name) started")
            if a.bool("wait") || spec.disks.contains(where: { $0.file == "seed.iso" }) {
                FileHandle.standardError.write(Data("waiting for guest agent…\n".utf8))
                if let info = try? Manager.waitForAgent(name, timeout: 240) {
                    let ips = (info["ips"] as? [[String: Any]] ?? []).compactMap { $0["addr"] as? String }
                    print("\(name) ready — \(info["os"] as? String ?? "") — IP \(ips.joined(separator: ", "))")
                }
            }
        }
    }

    static func createMac(_ o: CreateOptions, _ a: Args) async throws {
        #if arch(arm64)
        let bar = ProgressBar("macOS")
        var stage = ""
        let b = try await MacOSInstall.run(o, ipsw: a.str("ipsw").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }) { s, p in
            DispatchQueue.main.async {
                if s != stage { stage = s; FileHandle.standardError.write(Data("\n\(s)\n".utf8)) }
                bar.update(p)
            }
        }
        print("created \(b.name) (macOS). Start with: avm start \(b.name) --gui")
        #else
        throw AltVMError.unsupported("macOS guests need Apple silicon")
        #endif
    }

    static func info(_ a: Args) throws {
        let b = try VMLibrary.find(try a.pos(0, "vm"))
        var s = Manager.summary(b)
        let spec = try b.loadSpec()
        if a.bool("json") {
            s["spec"] = try JSONSerialization.jsonObject(with: JSON.encoder.encode(spec))
            printJSON(s)
            return
        }
        print("\u{1B}[1m\(spec.name)\u{1B}[0m — \(spec.os.displayName) — \(s["state"] ?? "")")
        print("  resources   \(spec.cpus) vCPU, \(spec.memoryMiB) MiB RAM, profile \(spec.profile.rawValue)\(spec.adaptiveResources ? " (adaptive)" : "")")
        for d in spec.disks { print("  disk        \(d.file) \(d.readOnly ? "(ro)" : "\(d.sizeGiB) GiB") — \(formatBytes(DiskManager.allocated(b.diskURL(d)))) used") }
        for n in spec.network { print("  network     \(n.mode.rawValue)\(n.switchName.map { " (\($0))" } ?? "") mac \(n.macAddress ?? "auto")") }
        for f in spec.integration.sharedFolders { print("  share       \(f.name) → \(f.hostPath)\(f.readOnly ? " (ro)" : "")") }
        print("  integration clipboard=\(spec.integration.clipboard) audio=\(spec.integration.audioOutput) mic=\(spec.integration.microphone) rosetta=\(spec.integration.rosetta) agent=\(spec.integration.guestAgent)")
        print("  security    isolated=\(spec.security.isolated) disposable=\(spec.security.disposable) encrypted=\(spec.security.encrypted) secureBoot=\(spec.security.secureBoot)\(spec.security.organization.map { " org=\($0)" } ?? "")")
        if !spec.labels.isEmpty { print("  labels      \(spec.labels.map { "\($0)=\($1)" }.sorted().joined(separator: " "))") }
        print("  snapshots   \(s["snapshots"] ?? 0)   bundle \(b.url.path)")
        if let rt = s["runtime"] as? [String: Any] {
            print("  runtime     pid \(rt["pid"] ?? "") uptime \(rt["uptimeSeconds"] ?? 0)s")
            if let w = rt["warnings"] as? [String] { w.forEach { print("  warning     \($0)") } }
            let ips = Manager.ipAddresses(spec.name)
            if !ips.isEmpty { print("  ip          \(ips.joined(separator: ", "))") }
        }
    }

    static func set(_ a: Args) throws {
        let b = try VMLibrary.find(try a.pos(0, "vm"))
        if let p = Policy.loadActive(), p.lockSettings { throw AltVMError.policy("settings are locked by your organization") }
        var spec = try b.loadSpec()
        for kv in a.positionals.dropFirst() {
            let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw AltVMError.invalid("expected key=value, got '\(kv)'") }
            var (k, v) = (parts[0], parts[1])
            let truthy = ["1", "true", "yes", "on"].contains(v.lowercased())
            if k.hasSuffix("+") || k.hasSuffix("-") {
                let op = k.removeLast()
                guard k == "share" else { throw AltVMError.invalid("only share supports +=/-=") }
                if op == "+" {
                    let nv = v.split(separator: ":", maxSplits: 1).map(String.init)
                    guard nv.count == 2 else { throw AltVMError.invalid("share+=name:/path") }
                    spec.integration.sharedFolders.append(SharedFolderSpec(name: nv[0], hostPath: (nv[1] as NSString).expandingTildeInPath))
                } else {
                    spec.integration.sharedFolders.removeAll { $0.name == v }
                }
                continue
            }
            switch k {
            case "cpus": guard let n = Int(v) else { throw AltVMError.invalid(v) }; spec.cpus = n
            case "memory": spec.memoryMiB = try parseMemory(v)
            case "profile":
                guard let p = WorkloadProfile(rawValue: v) else { throw AltVMError.invalid("profile \(v)") }
                spec.profile = p
                let r = ProfileEngine.resources(for: p, os: spec.os, host: .current())
                spec.cpus = r.cpus; spec.memoryMiB = r.memoryMiB
            case "adaptive": spec.adaptiveResources = truthy
            case "isolated": spec.security.isolated = truthy
            case "disposable": spec.security.disposable = truthy
            case "clipboard": spec.integration.clipboard = truthy
            case "rosetta": spec.integration.rosetta = truthy
            case "audio": spec.integration.audioOutput = truthy
            case "mic", "microphone": spec.integration.microphone = truthy
            case "agent": spec.integration.guestAgent = truthy
            case "notes": spec.notes = v
            case "display":
                let wh = v.split(separator: "x").compactMap { Int($0) }
                guard wh.count == 2 else { throw AltVMError.invalid("display=WIDTHxHEIGHT") }
                spec.display.width = wh[0]; spec.display.height = wh[1]
            case "displays": spec.display.extraDisplays = max(0, (Int(v) ?? 1) - 1)
            case "expires":
                guard let d = ISO8601DateFormatter().date(from: v.count == 10 ? v + "T00:00:00Z" : v) else { throw AltVMError.invalid("expires=YYYY-MM-DD") }
                spec.security.expires = d
            case "disk.sync":
                guard ["fast", "full"].contains(v) else { throw AltVMError.invalid("disk.sync=full|fast") }
                spec.labels["disk.sync"] = v == "fast" ? "fast" : nil
            case "boot":
                switch v {
                case "efi": spec.fastBoot = false; spec.kernel = nil; spec.initrd = nil; spec.kernelCommandLine = nil
                case "fast", "fastboot", "kernel": spec.fastBoot = true
                default: throw AltVMError.invalid("boot=efi|fast")
                }
            case "network":
                spec.network = [NetworkSpec(mode: NetworkMode(rawValue: v) ?? .nat, macAddress: spec.network.first?.macAddress ?? MACAddress.random())]
            case "switch":
                spec.network = [NetworkSpec(mode: .switch, macAddress: spec.network.first?.macAddress ?? MACAddress.random(), switchName: v)]
            default:
                if k.hasPrefix("label.") { spec.labels[String(k.dropFirst(6))] = v.isEmpty ? nil : v; continue }
                throw AltVMError.invalid("unknown setting '\(k)'")
            }
        }
        if let p = Policy.loadActive() { try p.enforce(spec) }
        try b.saveSpec(spec)
        AuditLog.shared.record("vm.configure", vm: spec.name, details: ["changes": a.positionals.dropFirst().joined(separator: " ")])
        print("updated \(spec.name)\(b.isRunning ? " (applies on next boot)" : "")")
    }

    static func disk(_ a: Args) throws {
        let sub = try a.pos(0, "resize|compact")
        let b = try VMLibrary.find(try a.pos(1, "vm"))
        var spec = try b.loadSpec()
        guard let disk = spec.disks.first(where: { !$0.readOnly }) else { throw AltVMError.notFound("writable disk") }
        switch sub {
        case "resize":
            if b.isRunning { throw AltVMError.running(b.name) }
            guard let g = UInt64(try a.pos(2, "GiB")) else { throw AltVMError.invalid("size") }
            try DiskManager.resize(at: b.diskURL(disk), toGiB: g)
            if let i = spec.disks.firstIndex(of: disk) { spec.disks[i].sizeGiB = g }
            try b.saveSpec(spec)
            print("disk grown to \(g) GiB (cloud-init guests grow the filesystem on next boot)")
        case "compact":
            if b.isRunning {
                _ = try? Manager.agent(b.name, "fstrim", timeout: 600)
                print("guest TRIM issued — freed blocks returned to the Mac")
                return
            }
            let bar = ProgressBar("compact")
            let freed = try DiskManager.compact(at: b.diskURL(disk)) { bar.update($0) }
            print("reclaimed \(formatBytes(freed))")
        default: throw AltVMError.invalid("disk \(sub)")
        }
    }

    static func exec(_ a: Args) throws {
        let name = try a.pos(0, "vm")
        var cmd = a.passthrough
        if cmd.isEmpty { cmd = Array(a.positionals.dropFirst()) }
        guard !cmd.isEmpty else { throw AltVMError.invalid("usage: avm exec <vm> -- <command>") }
        var stdin = ""
        // Forward stdin only on request (-i/--stdin, like `docker exec -i`): reading it implicitly
        // blocks forever when the caller's stdin is an open pipe (scripts, CI, loops).
        if a.bool("i") || a.bool("stdin") { stdin = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }
        let (code, out, err) = try Manager.exec(name, command: cmd, stdin: stdin, timeout: a.int("timeout") ?? 600)
        FileHandle.standardOutput.write(Data(out.utf8))
        FileHandle.standardError.write(Data(err.utf8))
        exit(Int32(truncatingIfNeeded: code))
    }

    static func ssh(_ a: Args) throws {
        let name = try a.pos(0, "vm")
        guard let ip = Manager.ipAddresses(name).first else { throw AltVMError.io("no IP for \(name) (is the guest agent running?)") }
        let user = a.str("user") ?? NSUserName()
        let args = ["ssh", "-o", "StrictHostKeyChecking=accept-new", "\(user)@\(ip)"] + a.passthrough
        let cargs = args.map { strdup($0) } + [nil]
        execvp("/usr/bin/ssh", cargs)
        throw AltVMError.io("exec ssh failed")
    }

    static func usb(_ a: Args) throws {
        let sub = try a.pos(0, "attach|detach")
        let name = try a.pos(1, "vm")
        switch sub {
        case "attach":
            let path = (try a.pos(2, "image") as NSString).expandingTildeInPath
            printJSON(try Manager.control(name, "usb-attach", extra: ["path": path, "readOnly": !a.bool("read-write")]))
        case "detach":
            printJSON(try Manager.control(name, "usb-detach", extra: ["id": try a.pos(2, "id")]))
        default: throw AltVMError.invalid("usb \(sub)")
        }
    }

    static func snapshot(_ a: Args) throws {
        let sub = try a.pos(0, "create|list|tree|restore|delete")
        let b = try VMLibrary.find(try a.pos(1, "vm"))
        let sm = SnapshotManager(bundle: b)
        switch sub {
        case "create", "take":
            let label = a.positionals.count > 2 ? a.positionals[2] : "snapshot-\(sm.list().count + 1)"
            let t0 = Date()
            let r = try Manager.snapshot(b.name, label: label, note: a.str("note") ?? "")
            print("snapshot \(r["name"] ?? label) (\(r["id"] ?? "")) \(r["live"] as? Bool == true ? "live " : "")taken in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
        case "list", "ls":
            if a.bool("json") { printEncodable(sm.list()); return }
            var rows = [["ID", "NAME", "CREATED", "LIVE", "PARENT"]]
            let df = ISO8601DateFormatter()
            for s in sm.list() { rows.append([s.id + (s.id == sm.current ? " *" : ""), s.name, df.string(from: s.created), s.live ? "yes" : "", s.parent ?? ""]) }
            table(rows)
        case "tree": print(sm.tree(), terminator: "")
        case "restore", "revert":
            if b.isRunning { try Manager.stop(b.name, force: true) }
            try sm.restore(try a.pos(2, "snapshot"))
            print("restored \(a.positionals[2])\(b.hasSavedState ? " — next start resumes the live state" : "")")
        case "delete", "rm":
            try sm.delete(try a.pos(2, "snapshot"))
            print("deleted")
        default: throw AltVMError.invalid("snapshot \(sub)")
        }
    }

    static func switchCmd(_ a: Args) throws {
        let sub = try a.pos(0, "create|list|run|set|delete")
        switch sub {
        case "create":
            let name = try a.pos(1, "name")
            let subnet = a.str("subnet") ?? "10.77.\(SwitchConfig.list().count + 10)"
            try SwitchConfig(name: name, subnet: subnet).save()
            AuditLog.shared.record("switch.create", vm: nil, details: ["switch": name, "subnet": subnet])
            print("switch \(name) (\(subnet).0/24, DHCP on). Attach VMs: avm set <vm> switch=\(name)")
        case "list", "ls":
            var rows = [["NAME", "SUBNET", "RUNNING", "LATENCY", "LOSS", "BANDWIDTH"]]
            for s in SwitchConfig.list() {
                rows.append([s.name, s.subnet + ".0/24", SwitchDaemon.isRunning(s.name) ? "yes" : "no", "\(s.conditions.latencyMs)ms±\(s.conditions.jitterMs)",
                             "\(s.conditions.lossPercent)%", s.conditions.bandwidthKbps > 0 ? "\(Int(s.conditions.bandwidthKbps))kbps" : "∞"])
            }
            table(rows)
        case "set":
            let name = try a.pos(1, "name")
            var cfg = try SwitchConfig.load(name)
            if let p = a.str("preset") {
                guard let c = LinkConditions.presets[p] else { throw AltVMError.invalid("preset (\(LinkConditions.presets.keys.sorted().joined(separator: ", ")))") }
                cfg.conditions = c
            }
            if let v = a.str("latency").flatMap(Double.init) { cfg.conditions.latencyMs = v }
            if let v = a.str("jitter").flatMap(Double.init) { cfg.conditions.jitterMs = v }
            if let v = a.str("loss").flatMap(Double.init) { cfg.conditions.lossPercent = v }
            if let v = a.str("bandwidth").flatMap(Double.init) { cfg.conditions.bandwidthKbps = v }
            if let v = a.str("duplicate").flatMap(Double.init) { cfg.conditions.duplicatePercent = v }
            try cfg.save()
            AuditLog.shared.record("switch.conditions", vm: nil, details: ["switch": name])
            print("\(name): latency \(cfg.conditions.latencyMs)ms jitter \(cfg.conditions.jitterMs)ms loss \(cfg.conditions.lossPercent)% bw \(cfg.conditions.bandwidthKbps)kbps (live)")
        case "delete":
            let name = try a.pos(1, "name")
            try FileManager.default.removeItem(at: SwitchConfig.url(name))
        case "run":
            let name = try a.pos(1, "name")
            let cfg = (try? SwitchConfig.load(name)) ?? SwitchConfig(name: name, subnet: "10.77.\(SwitchConfig.list().count + 10)")
            try? cfg.save()
            let sw = VirtualSwitch(config: cfg)
            try sw.start()
            print("switch \(name) listening on \(sw.socketPath)")
            // Hot-reload conditions every second; exit when idle for 10 minutes with no clients.
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in sw.reload() }
            signal(SIGTERM) { _ in exit(0) }
            RunLoop.main.run()
        default: throw AltVMError.invalid("switch \(sub)")
        }
    }

    static func image(_ a: Args) async throws {
        let sub = try a.pos(0, "pack|inspect|deploy")
        switch sub {
        case "pack":
            let vm = try a.pos(1, "vm")
            let out = URL(fileURLWithPath: (try a.pos(2, "out.avmimg") as NSString).expandingTildeInPath)
            let bar = ProgressBar("pack")
            let m = try GoldenImage.pack(vm: vm, to: out, version: a.str("version") ?? "1.0", description: a.str("description") ?? "",
                                         signingKey: a.str("sign").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }) { bar.update($0) }
            print("packed \(m.name)@\(m.version): \(formatBytes(DiskManager.logicalSize(out))) (from \(formatBytes(m.files.reduce(0) { $0 + $1.size })) logical) sha256 \(m.payloadSHA256.prefix(16))… \(a.str("sign") != nil ? "signed" : "UNSIGNED")")
        case "inspect":
            let ins = try GoldenImage.inspect(URL(fileURLWithPath: try a.pos(1, "file")))
            print("image      \(ins.manifest.name)@\(ins.manifest.version) — \(ins.manifest.os.displayName)")
            print("publisher  \(ins.manifest.publisher)  created \(ins.manifest.created)")
            print("signature  \(ins.signed ? (ins.trusted ? "valid, TRUSTED signer" : "valid, signer NOT trusted on this Mac") : "unsigned")")
            print("payload    \(formatBytes(ins.manifest.payloadBytes)) sha256 \(ins.manifest.payloadSHA256)")
            for f in ins.manifest.files { print("  \(f.path)  \(formatBytes(f.size))") }
        case "deploy":
            let src = try a.pos(1, "file|url")
            let name = try a.pos(2, "name")
            if src.hasPrefix("http") {
                try await Fleet.apply(FleetFile(organization: nil, vms: [DesiredVM(name: name, from: src)]), log: { print($0) })
            } else {
                let bar = ProgressBar("deploy")
                try GoldenImage.deploy(URL(fileURLWithPath: (src as NSString).expandingTildeInPath), as: name) { bar.update($0) }
            }
            print("deployed \(name)")
        default: throw AltVMError.invalid("image \(sub)")
        }
    }

    static func apply(_ a: Args) async throws {
        let fleet = try Fleet.load(URL(fileURLWithPath: try a.pos(0, "file")))
        let plan = Fleet.plan(fleet)
        if plan.isEmpty { print("No changes. Infrastructure matches the configuration."); return }
        print("Plan:")
        plan.forEach { print("  \($0)") }
        if a.bool("dry-run") { return }
        try await Fleet.apply(fleet) { print("  → \($0)") }
        print("Apply complete.")
    }

    static func keys(_ a: Args) throws {
        let sub = try a.pos(0, "generate|trust")
        switch sub {
        case "generate":
            let name = try a.pos(1, "name")
            let dir = URL(fileURLWithPath: (a.str("dir") ?? FileManager.default.currentDirectoryPath as String))
            if a.bool("escrow") {
                let k = EncryptedStore.generateEscrowKey()
                let priv = dir.appendingPathComponent("\(name).escrow.key")
                try k.privateKey.write(to: priv, atomically: true, encoding: .utf8)
                chmod(priv.path, 0o600)
                print("escrow private key → \(priv.path) (keep offline!)\nescrowPublicKey for policy.json:\n\(k.publicKey)")
                return
            }
            let (priv, pub) = try Signing.writeKeyPair(Signing.generate(), to: dir, name: name)
            print("private key → \(priv.path)\npublic key  → \(pub.path)")
            if a.bool("trust") {
                try Paths.ensure()
                try FileManager.default.copyItem(at: pub, to: Paths.trustedKeys.appendingPathComponent(pub.lastPathComponent))
                print("trusted on this Mac")
            }
        case "trust":
            let pub = URL(fileURLWithPath: try a.pos(1, "file.pub"))
            _ = try Signing.loadPublicKey(try String(contentsOf: pub, encoding: .utf8))
            try Paths.ensure()
            let dst = Paths.trustedKeys.appendingPathComponent(pub.lastPathComponent)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: pub, to: dst)
            AuditLog.shared.record("keys.trust", vm: nil, details: ["key": pub.lastPathComponent])
            print("trusted \(pub.lastPathComponent)")
        default: throw AltVMError.invalid("keys \(sub)")
        }
    }

    static func policy(_ a: Args) throws {
        let sub = try a.pos(0, "init|sign|install|show|check")
        switch sub {
        case "init":
            var p = Policy(organization: try a.pos(1, "organization"))
            p.maxCPUs = 8; p.maxMemoryMiB = 16384; p.maxDiskGiB = 256
            p.allowedSharedFolderRoots = ["~/Documents", "~/Downloads", "~/Desktop", "~/src"]
            p.requireSignedImages = true
            p.maxSnapshotsPerVM = 20
            printEncodable(p)
        case "sign":
            let file = URL(fileURLWithPath: try a.pos(1, "policy.json"))
            guard let key = a.str("key") else { throw AltVMError.invalid("--key <private key> required") }
            let p = try JSON.decoder.decode(Policy.self, from: Data(contentsOf: file))
            printEncodable(try p.sign(with: URL(fileURLWithPath: key)))
        case "install":
            let signed = try JSON.decoder.decode(Policy.Signed.self, from: Data(contentsOf: URL(fileURLWithPath: try a.pos(1, "signed.json"))))
            try Policy.install(signed)
            print("policy installed and verified")
        case "show":
            guard let p = Policy.loadActive() else { print("no policy installed"); return }
            printEncodable(p)
        case "check":
            let name = try a.pos(1, "vm")
            guard let p = Policy.loadActive() else { print("no policy installed — \(name) is compliant"); return }
            let v = p.violations(try VMLibrary.find(name).loadSpec())
            if v.isEmpty { print("\(name): compliant with \(p.organization) policy") } else {
                print("\(name): \(v.count) violation(s)"); v.forEach { print("  ✗ \($0)") }; exit(2)
            }
        default: throw AltVMError.invalid("policy \(sub)")
        }
    }

    static func recover(_ a: Args) throws {
        let name = a.positionals.first == "recover" ? try a.pos(1, "vm") : try a.pos(0, "vm")
        guard let keyFile = a.str("escrow-key") else { throw AltVMError.invalid("--escrow-key <file> required") }
        print(try EncryptedStore.recover(name, escrowPrivateKey: try String(contentsOfFile: keyFile, encoding: .utf8)))
    }

    static func audit(_ a: Args) throws {
        let sub = a.positionals.first ?? "show"
        switch sub {
        case "show":
            let n = a.int("n") ?? 50
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            for e in AuditLog.shared.entries().suffix(n) {
                print("#\(e.seq) \(df.string(from: e.ts)) \(e.user) \(e.event)\(e.vm.map { " [\($0)]" } ?? "") \(e.details.map { "\($0)=\($1)" }.sorted().joined(separator: " "))")
            }
        case "verify":
            if let problem = AuditLog.shared.verify() { print("✗ audit log TAMPERED: \(problem)"); exit(3) }
            print("✓ audit chain intact (\(AuditLog.shared.entries().count) entries)")
        case "export":
            print((try? String(contentsOf: AuditLog.shared.url, encoding: .utf8)) ?? "", terminator: "")
        default: throw AltVMError.invalid("audit \(sub)")
        }
    }

    static func serve(_ a: Args) throws {
        let token = try APIServer.loadOrCreateToken()
        let host = a.str("listen") ?? "127.0.0.1"
        let port = UInt16(a.int("port") ?? 8484)
        let server = APIServer(host: host, port: port, token: token)
        try server.start()
        print("AltVM API + console on http://\(host):\(port)")
        print("  console : http://\(host == "0.0.0.0" ? "localhost" : host):\(port)/#token=\(token)")
        print("  API     : curl -H 'Authorization: Bearer \(token)' http://\(host):\(port)/api/v1/vms")
        print("  metrics : /metrics (Prometheus)")
        AuditLog.shared.record("api.serve", vm: nil, details: ["listen": "\(host):\(port)"])
        signal(SIGTERM) { _ in exit(0) }
        RunLoop.main.run()
    }
}

// MARK: - foreground VM process

@MainActor
final class RunHost: NSObject, NSApplicationDelegate {
    let name: String
    let args: Args
    var runner: VMRunner?
    var window: VMWindowController?

    init(name: String, args: Args) { self.name = name; self.args = args }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                let bundle = try VMLibrary.find(name)
                var o = VMRunner.Options()
                o.gui = !args.bool("headless") && !args.bool("console")
                o.consoleToStdio = args.bool("console")
                o.recovery = args.bool("recovery")
                o.helperExecutable = Spawner.avmPath()
                let r = try VMRunner(bundle: bundle, options: o)
                r.discardSavedStateOnFailure = args.bool("discard-state")
                r.onExit = { code in
                    print("\(self.name) exited")
                    exit(code)
                }
                runner = r
                try await r.start()
                r.warnings.forEach { FileHandle.standardError.write(Data("warning: \($0)\n".utf8)) }
                print("\(name) running (pid \(getpid()))")
                if o.gui {
                    NSApp.setActivationPolicy(.regular)
                    let w = VMWindowController(runner: r)
                    w.showWindow(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    window = w
                }
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let r = runner, r.state == .running else { return .terminateNow }
        Task { try? await r.suspend() }
        return .terminateCancel
    }
}

// MARK: - entry

let argv = Array(CommandLine.arguments.dropFirst())
setvbuf(stdout, nil, _IOLBF, 0)

nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []

if argv.first == "run" {
    let a = Args(Array(argv.dropFirst()), boolFlags: boolFlags)
    guard let name = a.positionals.first else { print("usage: avm run <vm> [--headless|--console]"); exit(2) }
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let host = RunHost(name: name, args: a)
        app.delegate = host
        // Graceful handling of SIGTERM/SIGINT: suspend-safe stop.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                MainActor.assumeIsolated {
                    if let r = host.runner { Task { try? await r.stop(force: false, timeout: 20) } } else { exit(0) }
                }
            }
            src.resume()
            signalSources.append(src)
        }
        app.run()
    }
} else {
    Task { @MainActor in
        do {
            try await CLI.main(argv)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
}
