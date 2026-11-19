import Foundation
import Darwin

/// Minimal dependency-free HTTP/1.1 server exposing the full management REST API, a Prometheus
/// `/metrics` endpoint and the web admin portal. Bearer-token auth; binds to localhost by default.
public final class APIServer: @unchecked Sendable {
    public struct Request {
        public var method: String
        public var path: String
        public var query: [String: String]
        public var headers: [String: String]
        public var body: Data
        public func json() -> [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    }
    public struct Response {
        public var status: Int
        public var contentType: String
        public var body: Data
        public static func json(_ obj: Any, status: Int = 200) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])) ?? Data("{}".utf8)
            return Response(status: status, contentType: "application/json", body: data)
        }
        public static func error(_ msg: String, status: Int) -> Response { .json(["error": msg], status: status) }
        public static func text(_ s: String, type: String = "text/plain; charset=utf-8") -> Response { Response(status: 200, contentType: type, body: Data(s.utf8)) }
    }

    public let host: String
    public let port: UInt16
    public let token: String
    public let helper: String?
    private var fd: Int32 = -1

    public init(host: String = "127.0.0.1", port: UInt16 = 8484, token: String, helper: String? = nil) {
        self.host = host
        self.port = port
        self.token = token
        self.helper = helper
    }

    public static func loadOrCreateToken() throws -> String {
        try Paths.ensure()
        if let t = try? String(contentsOf: Paths.apiToken, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 32 { return t }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let t = bytes.map { String(format: "%02x", $0) }.joined()
        try t.write(to: Paths.apiToken, atomically: true, encoding: .utf8)
        chmod(Paths.apiToken.path, 0o600)
        return t
    }

    public func start() throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AltVMError.io("socket") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard r == 0 else { throw AltVMError.io("bind \(host):\(port): \(String(cString: strerror(errno)))") }
        listen(fd, 64)
        let lfd = fd
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(lfd, nil, nil)
                if c < 0 { if errno == EINTR { continue }; return }
                Thread.detachNewThread { self.serve(c) }
            }
        }
    }

    public func stop() { if fd >= 0 { close(fd); fd = -1 } }

    // MARK: HTTP

    private func serve(_ c: Int32) {
        defer { close(c) }
        var one: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let n = read(c, &chunk, chunk.count)
            if n <= 0 { return }
            buf.append(contentsOf: chunk[0..<n])
            headerEnd = buf.range(of: Data("\r\n\r\n".utf8))
            if buf.count > 1 << 20 { return }
        }
        let head = String(decoding: buf[..<headerEnd!.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let reqLine = lines.removeFirst().split(separator: " ")
        guard reqLine.count >= 2 else { return }
        var headers: [String: String] = [:]
        for l in lines {
            if let i = l.firstIndex(of: ":") {
                headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        var body = Data(buf[headerEnd!.upperBound...])
        let clen = Int(headers["content-length"] ?? "0") ?? 0
        guard clen <= 64 << 20 else { return }
        while body.count < clen {
            let n = read(c, &chunk, chunk.count)
            if n <= 0 { break }
            body.append(contentsOf: chunk[0..<n])
        }
        let target = String(reqLine[1])
        let comps = URLComponents(string: target)
        var query: [String: String] = [:]
        for q in comps?.queryItems ?? [] { query[q.name] = q.value ?? "" }
        let req = Request(method: String(reqLine[0]), path: comps?.path ?? target, query: query, headers: headers, body: body)
        let resp = handle(req)
        var out = "HTTP/1.1 \(resp.status) \(Self.reason(resp.status))\r\n"
        out += "Content-Type: \(resp.contentType)\r\nContent-Length: \(resp.body.count)\r\nConnection: close\r\n"
        out += "X-Content-Type-Options: nosniff\r\nCache-Control: no-store\r\n"
        out += "Content-Security-Policy: default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'\r\n\r\n"
        var data = Data(out.utf8)
        data.append(resp.body)
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(c, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }

    static func reason(_ s: Int) -> String {
        [200: "OK", 201: "Created", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
         404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 500: "Internal Server Error"][s] ?? "OK"
    }

    func authorized(_ r: Request) -> Bool {
        let given = (r.headers["authorization"] ?? "").replacingOccurrences(of: "Bearer ", with: "")
        let candidate = given.isEmpty ? (r.query["token"] ?? "") : given
        // constant-time compare
        let a = Array(candidate.utf8), b = Array(token.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: routing

    public func handle(_ r: Request) -> Response {
        if r.method == "GET" && (r.path == "/" || r.path == "/index.html") { return .text(WebPortal.html, type: "text/html; charset=utf-8") }
        if r.path == "/healthz" { return .json(["ok": true]) }
        guard authorized(r) else { return .error("unauthorized — pass Authorization: Bearer <token> (see `avm serve`)", status: 401) }
        if r.path == "/metrics" { return .text(Metrics.prometheus()) }
        let parts = r.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "api", parts[1] == "v1" else { return .error("not found", status: 404) }
        let p = Array(parts.dropFirst(2))
        do {
            return try route(r, p)
        } catch let e as AltVMError {
            switch e {
            case .notFound: return .error(e.description, status: 404)
            case .policy: return .error(e.description, status: 403)
            case .alreadyExists, .running, .notRunning: return .error(e.description, status: 409)
            case .invalid: return .error(e.description, status: 400)
            default: return .error(e.description, status: 500)
            }
        } catch {
            return .error(error.localizedDescription, status: 500)
        }
    }

    private func route(_ r: Request, _ p: [String]) throws -> Response {
        let body = r.json()
        switch (r.method, p.count, p.first ?? "") {
        case ("GET", 1, "host"):
            return .json(try JSONSerialization.jsonObject(with: JSON.encoder.encode(HostInfo.current())))
        case ("GET", 1, "vms"):
            return .json(Manager.listAll())
        case ("POST", 1, "vms"):
            let data = try JSONSerialization.data(withJSONObject: body)
            let desired = try JSON.decoder.decode(DesiredVM.self, from: data)
            try runAsync { try await Fleet.apply(FleetFile(organization: nil, vms: [desired]), helper: self.helper, log: { _ in }) }
            return .json(Manager.summary(try VMLibrary.find(desired.name)), status: 201)
        case ("GET", 2, "vms"):
            var s = Manager.summary(try VMLibrary.find(p[1]))
            s["spec"] = try JSONSerialization.jsonObject(with: JSON.encoder.encode(try VMLibrary.find(p[1]).loadSpec()))
            return .json(s)
        case ("DELETE", 2, "vms"):
            try VMLibrary.delete(p[1])
            return .json(["deleted": p[1]])
        case ("POST", 3, "vms"):
            return try vmAction(p[1], p[2], body)
        case ("GET", 3, "vms") where p[2] == "screenshot":
            var req: [String: Any] = ["action": "screenshot"]
            if let m = r.query["max"].flatMap(Int.init) { req["maxDimension"] = m }
            let res = try Manager.control(p[1], "computer", extra: req) as? [String: Any] ?? [:]
            guard let png = (res["png"] as? String).flatMap({ Data(base64Encoded: $0) }) else { throw AltVMError.io("no frame") }
            return Response(status: 200, contentType: "image/png", body: png)
        case ("GET", 3, "vms") where p[2] == "snapshots":
            let sm = SnapshotManager(bundle: try VMLibrary.find(p[1]))
            return .json(try JSONSerialization.jsonObject(with: JSON.encoder.encode(sm.list())))
        case ("POST", 5, "vms") where p[2] == "snapshots" && p[4] == "restore":
            try SnapshotManager(bundle: try VMLibrary.find(p[1])).restore(p[3])
            return .json(["restored": p[3]])
        case ("DELETE", 4, "vms") where p[2] == "snapshots":
            try SnapshotManager(bundle: try VMLibrary.find(p[1])).delete(p[3])
            return .json(["deleted": p[3]])
        case ("GET", 1, "catalog"):
            return .json(try JSONSerialization.jsonObject(with: JSON.encoder.encode(Catalog.entries)))
        case ("GET", 1, "switches"):
            return .json(try JSONSerialization.jsonObject(with: JSON.encoder.encode(SwitchConfig.list())))
        case ("PUT", 3, "switches") where p[2] == "conditions":
            var cfg = try SwitchConfig.load(p[1])
            if let preset = body["preset"] as? String, let c = LinkConditions.presets[preset] { cfg.conditions = c }
            else { cfg.conditions = try JSON.decoder.decode(LinkConditions.self, from: JSONSerialization.data(withJSONObject: body)) }
            try cfg.save()
            AuditLog.shared.record("switch.conditions", vm: nil, details: ["switch": p[1]])
            return .json(try JSONSerialization.jsonObject(with: JSON.encoder.encode(cfg)))
        case ("GET", 1, "audit"):
            let limit = Int(r.query["limit"] ?? "200") ?? 200
            let entries = AuditLog.shared.entries().suffix(limit)
            return .json(try JSONSerialization.jsonObject(with: JSON.encoder.encode(Array(entries))))
        case ("GET", 2, "audit") where p[1] == "verify":
            let v = AuditLog.shared.verify()
            return .json(["intact": v == nil, "problem": (v as Any?) ?? NSNull()])
        case ("GET", 1, "policy"):
            guard let pol = Policy.loadActive() else { return .json(["installed": false]) }
            return .json(["installed": true, "policy": try JSONSerialization.jsonObject(with: JSON.encoder.encode(pol))])
        case ("POST", 2, "fleet"):
            let fleet = try JSON.decoder.decode(FleetFile.self, from: JSONSerialization.data(withJSONObject: body))
            if p[1] == "plan" { return .json(Fleet.plan(fleet).map { ["vm": $0.vm, "action": $0.kind, "detail": $0.detail] }) }
            if p[1] == "apply" {
                let log = LogCollector()
                try runAsync { try await Fleet.apply(fleet, helper: self.helper) { log.append($0) } }
                return .json(["log": log.lines])
            }
            return .error("unknown fleet op", status: 404)
        default:
            return .error("no route for \(r.method) \(r.path)", status: 404)
        }
    }

    private func vmAction(_ name: String, _ action: String, _ body: [String: Any]) throws -> Response {
        switch action {
        case "start": try Manager.start(name, helper: helper); return .json(Manager.summary(try VMLibrary.find(name)))
        case "stop": try Manager.stop(name, force: body["force"] as? Bool ?? false); return .json(["stopped": name])
        case "suspend": _ = try Manager.control(name, "suspend"); _ = Manager.waitForExit(name, timeout: 120); return .json(["suspended": name])
        case "pause", "resume": return .json(try Manager.control(name, action))
        case "snapshot": return .json(try Manager.snapshot(name, label: body["name"] as? String ?? "api", note: body["note"] as? String ?? ""), status: 201)
        case "clone":
            guard let dest = body["name"] as? String else { throw AltVMError.invalid("body.name required") }
            return .json(Manager.summary(try VMLibrary.clone(name, to: dest)), status: 201)
        case "exec":
            let cmd: [String]
            if let s = body["command"] as? String { cmd = ["/bin/sh", "-c", s] } else { cmd = body["command"] as? [String] ?? [] }
            let (code, out, err) = try Manager.exec(name, command: cmd, stdin: body["stdin"] as? String ?? "", timeout: body["timeout"] as? Int ?? 300)
            return .json(["exitCode": code, "stdout": out, "stderr": err])
        case "info": return .json(try Manager.agent(name, "info", timeout: 10))
        case "computer":
            var req = body
            if req["action"] == nil { throw AltVMError.invalid("body.action required (screenshot, click, type, key, scroll, drag, move)") }
            req["scaled"] = req["scaled"] ?? false
            return .json(try Manager.control(name, "computer", extra: req))
        case "memory":
            return .json(try Manager.control(name, "memory", extra: ["mib": body["mib"] as? Int ?? 0]))
        default: throw AltVMError.invalid("unknown action \(action)")
        }
    }

    private func runAsync(_ work: @escaping @Sendable () async throws -> Void) throws {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var err: Error?
        Task.detached { do { try await work() } catch { err = error }; sem.signal() }
        sem.wait()
        if let err { throw err }
    }
}

public enum Metrics {
    public static func prometheus() -> String {
        var s = "# HELP altvm_vm_up VM process running (1) or not (0)\n# TYPE altvm_vm_up gauge\n"
        var extra = ""
        let host = HostInfo.current()
        for b in VMLibrary.list() {
            guard let spec = try? b.loadSpec() else { continue }
            let l = "vm=\"\(spec.name)\",os=\"\(spec.os.rawValue)\""
            s += "altvm_vm_up{\(l)} \(b.isRunning ? 1 : 0)\n"
            let u = b.diskUsage()
            extra += "altvm_vm_vcpus{\(l)} \(spec.cpus)\n"
            extra += "altvm_vm_memory_bytes{\(l)} \(spec.memoryMiB << 20)\n"
            extra += "altvm_vm_disk_logical_bytes{\(l)} \(u.logical)\n"
            extra += "altvm_vm_disk_physical_bytes{\(l)} \(u.physical)\n"
            extra += "altvm_vm_snapshots{\(l)} \(SnapshotManager(bundle: b).list().count)\n"
        }
        s += extra
        s += "altvm_host_cpus \(host.cpuCount)\naltvm_host_memory_bytes \(host.memoryMiB << 20)\n"
        s += "altvm_host_on_battery \(host.onBattery ? 1 : 0)\n"
        s += "altvm_audit_chain_intact \(AuditLog.shared.verify() == nil ? 1 : 0)\n"
        return s
    }
}

final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    func append(_ s: String) { lock.lock(); _lines.append(s); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
}
