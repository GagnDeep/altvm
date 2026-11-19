import Foundation

/// Model Context Protocol server (stdio, JSON-RPC 2.0). Lets AI agents (Claude Code, Claude
/// Desktop, any MCP client) operate VMs: lifecycle, snapshots/rollback, shell + files through the
/// guest agent, and full computer use (screenshots as images, mouse, keyboard) on any guest OS.
///
/// Scope controls for safe delegation: `allowedVMs` limits which machines are visible/usable,
/// `allowLifecycle == false` removes create/delete/clone tools.
public final class MCPServer {
    public var allowedVMs: Set<String>?
    public var allowLifecycle = true
    public var helper: String?
    private let out = FileHandle.standardOutput

    public init() {}

    struct Tool {
        let name: String
        let description: String
        let properties: [String: Any]
        let required: [String]
        let lifecycle: Bool
    }

    static func p(_ type: String, _ desc: String) -> [String: Any] { ["type": type, "description": desc] }

    let tools: [Tool] = [
        Tool(name: "list_vms", description: "List virtual machines with state, OS and resources.", properties: [:], required: [], lifecycle: false),
        Tool(name: "vm_info", description: "Details of one VM including IP addresses when running.", properties: ["name": p("string", "VM name")], required: ["name"], lifecycle: false),
        Tool(name: "create_vm", description: "Create a VM. source: 'catalog:debian-13' (ready in ~10 s, provisioned), 'catalog:ubuntu-24.04', 'image:/path.avmimg', or 'blank'. Starts it.",
             properties: ["name": p("string", "new VM name"), "source": p("string", "source"), "cpus": p("integer", "vCPUs"), "memory_mib": p("integer", "RAM in MiB"),
                          "disk_gib": p("integer", "disk size"), "disposable": p("boolean", "discard all changes at shutdown"), "isolated": p("boolean", "no network/sharing")],
             required: ["name"], lifecycle: true),
        Tool(name: "clone_vm", description: "Instant copy-on-write clone of a stopped VM (great for throwaway agent sandboxes).",
             properties: ["source": p("string", "VM to clone"), "name": p("string", "clone name")], required: ["source", "name"], lifecycle: true),
        Tool(name: "delete_vm", description: "Permanently delete a stopped VM.", properties: ["name": p("string", "VM name")], required: ["name"], lifecycle: true),
        Tool(name: "start_vm", description: "Start (or resume) a VM and wait until it runs.", properties: ["name": p("string", "VM name")], required: ["name"], lifecycle: false),
        Tool(name: "stop_vm", description: "Shut a VM down (graceful unless force).", properties: ["name": p("string", "VM name"), "force": p("boolean", "power off immediately")], required: ["name"], lifecycle: false),
        Tool(name: "suspend_vm", description: "Save the VM's full RAM state to disk and stop; start_vm resumes it in under a second.", properties: ["name": p("string", "VM name")], required: ["name"], lifecycle: false),
        Tool(name: "snapshot", description: "Take a snapshot (live, including RAM, when running). Use before risky actions.", properties: ["name": p("string", "VM name"), "label": p("string", "snapshot name")], required: ["name", "label"], lifecycle: false),
        Tool(name: "list_snapshots", description: "List a VM's snapshots.", properties: ["name": p("string", "VM name")], required: ["name"], lifecycle: false),
        Tool(name: "restore_snapshot", description: "Roll a VM back to a snapshot (stops it first). Live snapshots resume exactly where they were.", properties: ["name": p("string", "VM name"), "snapshot": p("string", "snapshot name or id")], required: ["name", "snapshot"], lifecycle: false),
        Tool(name: "exec", description: "Run a shell command inside a Linux VM via the guest agent (no network or SSH needed). Returns exit code, stdout, stderr.",
             properties: ["name": p("string", "VM name"), "command": p("string", "shell command (/bin/sh -c)"), "timeout": p("integer", "seconds (default 300)")], required: ["name", "command"], lifecycle: false),
        Tool(name: "read_file", description: "Read a file from a Linux VM.", properties: ["name": p("string", "VM name"), "path": p("string", "absolute path")], required: ["name", "path"], lifecycle: false),
        Tool(name: "write_file", description: "Write a text file in a Linux VM.", properties: ["name": p("string", "VM name"), "path": p("string", "absolute path"), "content": p("string", "file content")], required: ["name", "path", "content"], lifecycle: false),
        Tool(name: "screenshot", description: "Capture the VM screen (any OS). Coordinates for click/drag/scroll refer to this image.",
             properties: ["name": p("string", "VM name"), "max_dimension": p("integer", "longest side in pixels (default 1280)")], required: ["name"], lifecycle: false),
        Tool(name: "click", description: "Click at screenshot coordinates.", properties: ["name": p("string", "VM name"), "x": p("integer", "x"), "y": p("integer", "y"),
             "button": p("string", "left|right|middle"), "double": p("boolean", "double click")], required: ["name", "x", "y"], lifecycle: false),
        Tool(name: "move_mouse", description: "Move the pointer to screenshot coordinates.", properties: ["name": p("string", "VM name"), "x": p("integer", "x"), "y": p("integer", "y")], required: ["name", "x", "y"], lifecycle: false),
        Tool(name: "drag", description: "Drag from (x,y) to (x2,y2) in screenshot coordinates.", properties: ["name": p("string", "VM name"), "x": p("integer", "x"), "y": p("integer", "y"), "x2": p("integer", "x2"), "y2": p("integer", "y2")], required: ["name", "x", "y", "x2", "y2"], lifecycle: false),
        Tool(name: "scroll", description: "Scroll at a position. Positive dy scrolls down.", properties: ["name": p("string", "VM name"), "x": p("integer", "x"), "y": p("integer", "y"), "dy": p("integer", "notches")], required: ["name", "x", "y", "dy"], lifecycle: false),
        Tool(name: "type_text", description: "Type text with the virtual keyboard (US layout).", properties: ["name": p("string", "VM name"), "text": p("string", "text")], required: ["name", "text"], lifecycle: false),
        Tool(name: "press_keys", description: "Press a key or chord, e.g. 'Return', 'cmd+space', 'ctrl+alt+delete', 'shift+Tab'.", properties: ["name": p("string", "VM name"), "keys": p("string", "chord")], required: ["name", "keys"], lifecycle: false),
    ]

    // MARK: loop

    public func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let id = msg["id"]
            let method = msg["method"] as? String ?? ""
            let params = msg["params"] as? [String: Any] ?? [:]
            guard id != nil else { continue } // notifications (initialized, cancelled) need no reply
            switch method {
            case "initialize":
                reply(id, ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                           "capabilities": ["tools": ["listChanged": false]],
                           "serverInfo": ["name": "altvm", "version": "1.1.0"],
                           "instructions": "AltVM controls virtual machines on this Mac. Prefer snapshot before risky actions; use exec for shell work in Linux guests and screenshot/click/type for GUI work in any guest."])
            case "ping":
                reply(id, [:])
            case "tools/list":
                reply(id, ["tools": tools.filter { allowLifecycle || !$0.lifecycle }.map { t in
                    ["name": t.name, "description": t.description,
                     "inputSchema": ["type": "object", "properties": t.properties, "required": t.required]]
                }])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                do {
                    reply(id, ["content": try call(name, args), "isError": false])
                } catch {
                    reply(id, ["content": [["type": "text", "text": "Error: \(error.localizedDescription)"]], "isError": true])
                }
            default:
                send(["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "method not found: \(method)"]])
            }
        }
    }

    private func reply(_ id: Any?, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func send(_ obj: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        d.append(0x0A)
        out.write(d)
    }

    // MARK: tools

    func text(_ s: String) -> [[String: Any]] { [["type": "text", "text": s]] }
    func json(_ o: Any) -> [[String: Any]] {
        let d = (try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])) ?? Data()
        return text(String(decoding: d, as: UTF8.self))
    }

    func vm(_ args: [String: Any], _ key: String = "name") throws -> String {
        guard let n = args[key] as? String, !n.isEmpty else { throw AltVMError.invalid("missing '\(key)'") }
        if let allowed = allowedVMs, !allowed.contains(n) { throw AltVMError.policy("this MCP session may not access VM '\(n)'") }
        return n
    }

    func computer(_ name: String, _ req: [String: Any]) throws -> [String: Any] {
        var r = req
        r["scaled"] = true
        return try Manager.control(name, "computer", extra: r) as? [String: Any] ?? [:]
    }

    func call(_ tool: String, _ args: [String: Any]) throws -> [[String: Any]] {
        if !allowLifecycle, tools.first(where: { $0.name == tool })?.lifecycle == true { throw AltVMError.policy("lifecycle tools are disabled for this session") }
        AuditLog.shared.record("mcp.\(tool)", vm: args["name"] as? String, details: [:])
        switch tool {
        case "list_vms":
            let all = Manager.listAll().filter { allowedVMs == nil || allowedVMs!.contains($0["name"] as? String ?? "") }
            return json(all.map { v in v.filter { ["name", "state", "os", "cpus", "memoryMiB", "snapshots", "labels"].contains($0.key) } })
        case "vm_info":
            let n = try vm(args)
            var s = Manager.summary(try VMLibrary.find(n))
            if s["state"] as? String == "running" { s["ips"] = Manager.ipAddresses(n) }
            return json(s)
        case "create_vm":
            let n = try vm(args)
            var d = DesiredVM(name: n, from: args["source"] as? String ?? "catalog:debian-13")
            d.cpus = args["cpus"] as? Int
            d.memoryMiB = (args["memory_mib"] as? Int).map(UInt64.init)
            d.diskGiB = (args["disk_gib"] as? Int).map(UInt64.init)
            d.disposable = args["disposable"] as? Bool
            d.isolated = args["isolated"] as? Bool
            d.state = "running"
            let fleet = FleetFile(organization: nil, vms: [d])
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var err: Error?
            let helper = helper
            Task.detached { do { try await Fleet.apply(fleet, helper: helper) { _ in } } catch { err = error }; sem.signal() }
            sem.wait()
            if let err { throw err }
            if (try? VMLibrary.find(n).loadSpec())?.disks.contains(where: { $0.file == "seed.iso" }) == true {
                _ = try? Manager.waitForAgent(n, timeout: 180)
            }
            return text("created and started \(n)")
        case "clone_vm":
            let src = try vm(args, "source"), n = try vm(args)
            try VMLibrary.clone(src, to: n)
            return text("cloned \(src) → \(n)")
        case "delete_vm":
            let n = try vm(args)
            try VMLibrary.delete(n)
            return text("deleted \(n)")
        case "start_vm":
            let n = try vm(args)
            try Manager.start(n, helper: helper)
            return text("\(n) running")
        case "stop_vm":
            let n = try vm(args)
            try Manager.stop(n, force: args["force"] as? Bool ?? false)
            return text("\(n) stopped")
        case "suspend_vm":
            let n = try vm(args)
            _ = try Manager.control(n, "suspend")
            _ = Manager.waitForExit(n, timeout: 300)
            return text("\(n) suspended")
        case "snapshot":
            let n = try vm(args)
            return json(try Manager.snapshot(n, label: args["label"] as? String ?? "agent"))
        case "list_snapshots":
            let n = try vm(args)
            return json(SnapshotManager(bundle: try VMLibrary.find(n)).list().map { ["id": $0.id, "name": $0.name, "live": $0.live, "created": JSON.formatDate($0.created)] })
        case "restore_snapshot":
            let n = try vm(args)
            let b = try VMLibrary.find(n)
            if b.isRunning { try Manager.stop(n, force: true) }
            try SnapshotManager(bundle: b).restore(args["snapshot"] as? String ?? "")
            return text("\(n) restored to \(args["snapshot"] ?? "")")
        case "exec":
            let n = try vm(args)
            let (code, out, err) = try Manager.exec(n, command: ["/bin/sh", "-c", args["command"] as? String ?? ""], timeout: args["timeout"] as? Int ?? 300)
            return text("exit code: \(code)\n--- stdout ---\n\(out)\(err.isEmpty ? "" : "\n--- stderr ---\n\(err)")")
        case "read_file":
            let n = try vm(args)
            let r = try Manager.agent(n, "read_file", params: ["path": args["path"] as? String ?? ""])
            guard let b64 = r["content"] as? String, let d = Data(base64Encoded: b64) else { throw AltVMError.io("read failed") }
            return text(String(decoding: d, as: UTF8.self))
        case "write_file":
            let n = try vm(args)
            let content = Data((args["content"] as? String ?? "").utf8).base64EncodedString()
            _ = try Manager.agent(n, "write_file", params: ["path": args["path"] as? String ?? "", "content": content])
            return text("wrote \(args["path"] ?? "")")
        case "screenshot":
            let n = try vm(args)
            let r = try computer(n, ["action": "screenshot", "maxDimension": args["max_dimension"] as? Int ?? 1280])
            return [["type": "image", "data": r["png"] as? String ?? "", "mimeType": "image/png"],
                    ["type": "text", "text": "screenshot \(r["width"] ?? 0)x\(r["height"] ?? 0) (display \(r["displayWidth"] ?? 0)x\(r["displayHeight"] ?? 0))"]]
        case "click":
            let n = try vm(args)
            let button = args["button"] as? String ?? "left"
            let action = args["double"] as? Bool == true ? "double_click" : button == "right" ? "right_click" : button == "middle" ? "middle_click" : "click"
            _ = try computer(n, ["action": action, "x": args["x"] ?? 0, "y": args["y"] ?? 0])
            return text("clicked")
        case "move_mouse":
            let n = try vm(args)
            _ = try computer(n, ["action": "move", "x": args["x"] ?? 0, "y": args["y"] ?? 0])
            return text("moved")
        case "drag":
            let n = try vm(args)
            _ = try computer(n, ["action": "drag", "x": args["x"] ?? 0, "y": args["y"] ?? 0, "x2": args["x2"] ?? 0, "y2": args["y2"] ?? 0])
            return text("dragged")
        case "scroll":
            let n = try vm(args)
            _ = try computer(n, ["action": "scroll", "x": args["x"] ?? 0, "y": args["y"] ?? 0, "dy": args["dy"] ?? 3])
            return text("scrolled")
        case "type_text":
            let n = try vm(args)
            _ = try computer(n, ["action": "type", "text": args["text"] as? String ?? ""])
            return text("typed")
        case "press_keys":
            let n = try vm(args)
            _ = try computer(n, ["action": "key", "keys": args["keys"] as? String ?? ""])
            return text("pressed \(args["keys"] ?? "")")
        default:
            throw AltVMError.invalid("unknown tool \(tool)")
        }
    }
}
