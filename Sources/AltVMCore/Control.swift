import Foundation

/// Client for a running VM's control socket.
public enum ControlClient {
    public static func call(vm name: String, _ request: [String: Any], timeout: Int = 120) throws -> Any {
        let bundle = try VMLibrary.find(name)
        guard bundle.isRunning else { throw AltVMError.notRunning(name) }
        let fd = try UnixSocket.connect(path: bundle.controlSocketURL.path)
        let ch = LineChannel(fd: fd)
        ch.setTimeout(seconds: timeout)
        try ch.sendJSON(request)
        guard let resp = try ch.readJSON() else { throw AltVMError.io("no response from VM process") }
        if resp["ok"] as? Bool == true { return resp["result"] ?? [:] }
        throw AltVMError.io(resp["error"] as? String ?? "unknown error")
    }

    public static func status(_ name: String) -> [String: Any]? {
        (try? call(vm: name, ["op": "status"], timeout: 5)) as? [String: Any]
    }
}

/// Launches long-running helpers (VM processes, switches) as detached background processes.
public enum Spawner {
    /// Absolute path to the `avm` executable (this binary, or the one bundled inside AltVM.app).
    public static func avmPath(_ hint: String? = nil) -> String {
        if let hint, FileManager.default.isExecutableFile(atPath: hint) { return hint }
        let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        if me.lastPathComponent == "avm" { return me.path }
        let sibling = me.deletingLastPathComponent().appendingPathComponent("avm").path
        if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        if let b = Bundle.main.url(forAuxiliaryExecutable: "avm") { return b.path }
        return "/usr/local/bin/avm"
    }

    @discardableResult
    public static func detached(_ exe: String, _ args: [String], log: URL) throws -> Int32 {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let out = try FileHandle(forWritingTo: log)
        out.seekToEndOfFile()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["ALTVM_HOME"] = Paths.home.path
        p.environment = env
        try p.run()
        return p.processIdentifier
    }
}

public enum SwitchDaemon {
    public static func isRunning(_ name: String) -> Bool {
        let path = Runtime.switchSocket(name).path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        // A stale socket file refuses connection.
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        defer { close(fd) }
        var addr = SockAddr.make(path)
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        return r == 0
    }

    public static func ensureRunning(_ name: String, helper: String?) throws {
        if isRunning(name) { return }
        if (try? SwitchConfig.load(name)) == nil {
            // Auto-create with a deterministic subnet.
            let n = name.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF } % 200 + 20
            try SwitchConfig(name: name, subnet: "10.77.\(n)").save()
        }
        try Spawner.detached(Spawner.avmPath(helper), ["switch", "run", name],
                             log: Paths.switches.appendingPathComponent("\(name).log"))
        for _ in 0..<50 {
            if isRunning(name) { return }
            usleep(100_000)
        }
        throw AltVMError.io("virtual switch '\(name)' failed to start (see \(Paths.switches.path)/\(name).log)")
    }
}
