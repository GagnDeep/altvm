import Foundation
import Darwin

/// Network conditioning parameters (Parallels Pro's "network conditioner", but per-switch,
/// scriptable, and changeable live while VMs run).
public struct LinkConditions: Codable, Equatable, Sendable {
    public var latencyMs: Double = 0
    public var jitterMs: Double = 0
    /// Packet loss, 0...100 percent.
    public var lossPercent: Double = 0
    /// Bandwidth cap in kilobits/s (0 = unlimited).
    public var bandwidthKbps: Double = 0
    /// Duplicate packets, percent.
    public var duplicatePercent: Double = 0

    public init() {}

    public static let presets: [String: LinkConditions] = {
        func mk(_ l: Double, _ j: Double, _ loss: Double, _ bw: Double) -> LinkConditions {
            var c = LinkConditions(); c.latencyMs = l; c.jitterMs = j; c.lossPercent = loss; c.bandwidthKbps = bw; return c
        }
        return [
            "perfect": LinkConditions(),
            "lan": mk(1, 0.2, 0, 1_000_000),
            "wifi": mk(4, 2, 0.1, 100_000),
            "dsl": mk(30, 5, 0.2, 8_000),
            "4g": mk(60, 15, 0.5, 20_000),
            "3g": mk(150, 40, 1, 1_600),
            "edge": mk(400, 100, 2, 240),
            "satellite": mk(600, 50, 1.5, 5_000),
            "lossy": mk(20, 10, 10, 0),
            "very-bad": mk(500, 250, 15, 128),
        ]
    }()
}

public struct SwitchConfig: Codable, Equatable, Sendable {
    public var name: String
    /// Subnet prefix /24, e.g. "10.77.1" → gateway/DHCP 10.77.1.1, leases .10–.250.
    public var subnet: String
    public var dhcp: Bool = true
    public var conditions: LinkConditions = LinkConditions()

    public init(name: String, subnet: String) { self.name = name; self.subnet = subnet }

    public static func url(_ name: String) -> URL { Paths.switches.appendingPathComponent("\(name).json") }

    public static func load(_ name: String) throws -> SwitchConfig {
        try JSON.decoder.decode(SwitchConfig.self, from: Data(contentsOf: url(name)))
    }
    public func save() throws {
        try Paths.ensure()
        try JSON.encoder.encode(self).write(to: Self.url(name), options: .atomic)
    }
    public static func list() -> [SwitchConfig] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.switches, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { try? JSON.decoder.decode(SwitchConfig.self, from: Data(contentsOf: $0)) }
    }
}

/// A userspace learning L2 switch. VMs connect via UNIX datagram sockets (one Ethernet frame per
/// datagram, exactly what VZFileHandleNetworkDeviceAttachment speaks). Provides:
///  * custom isolated networks between any number of VMs,
///  * a built-in DHCP server, so guests just work,
///  * link conditioning (latency, jitter, loss, bandwidth, duplication) — reloadable live.
public final class VirtualSwitch: @unchecked Sendable {
    public private(set) var config: SwitchConfig
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "altvm.switch")
    private let delayQueue = DispatchQueue(label: "altvm.switch.delay")
    private var macTable: [Data: String] = [:]          // MAC → client socket path
    private var clients: Set<String> = []
    private var leases: [Data: UInt8] = [:]             // MAC → host octet
    private var nextBusyUntil: DispatchTime = .now()    // bandwidth shaper
    public private(set) var stats = Stats()
    private var source: DispatchSourceRead?

    public struct Stats: Codable, Sendable {
        public var framesIn = 0, framesOut = 0, dropped = 0, bytes = 0, dhcpLeases = 0
    }

    public init(config: SwitchConfig) { self.config = config }

    public var socketPath: String { Runtime.switchSocket(config.name).path }

    public func start() throws {
        fd = try UnixSocket.listen(path: socketPath, type: SOCK_DGRAM)
        var size: Int32 = 8 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.drain() }
        src.resume()
        source = src
    }

    public func stop() {
        source?.cancel()
        if fd >= 0 { close(fd) }
        unlink(socketPath)
    }

    public func reload() {
        if let c = try? SwitchConfig.load(config.name) { queue.async { self.config = c } }
    }

    private func drain() {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            var from = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, MSG_DONTWAIT, $0, &len) }
            }
            if n <= 0 { return }
            let frame = Data(buf[0..<n])
            let src = SockAddr.path(from)
            guard n >= 14, !src.isEmpty else { continue }
            stats.framesIn += 1
            clients.insert(src)
            handle(frame, from: src)
        }
    }

    private func handle(_ frame: Data, from src: String) {
        let dst = frame.subdata(in: 0..<6)
        let srcMAC = frame.subdata(in: 6..<12)
        macTable[srcMAC] = src
        if config.dhcp, let reply = DHCPServer.reply(to: frame, subnet: config.subnet, leases: &leases) {
            stats.dhcpLeases = leases.count
            send(reply, to: src, conditioned: false)
            return
        }
        if dst[0] & 1 == 1 { // broadcast / multicast → flood
            for c in clients where c != src { send(frame, to: c, conditioned: true) }
        } else if let target = macTable[dst] {
            send(frame, to: target, conditioned: true)
        } else {
            for c in clients where c != src { send(frame, to: c, conditioned: true) }
        }
    }

    private func send(_ frame: Data, to path: String, conditioned: Bool) {
        let c = config.conditions
        if conditioned {
            if c.lossPercent > 0, Double.random(in: 0..<100) < c.lossPercent { stats.dropped += 1; return }
            var delay = c.latencyMs
            if c.jitterMs > 0 { delay += Double.random(in: -c.jitterMs...c.jitterMs) }
            delay = max(0, delay)
            var when = DispatchTime.now() + .microseconds(Int(delay * 1000))
            if c.bandwidthKbps > 0 {
                let txTime = Double(frame.count * 8) / (c.bandwidthKbps * 1000)
                let start = max(nextBusyUntil, .now())
                nextBusyUntil = start + .microseconds(Int(txTime * 1_000_000))
                // Bounded queue (~1s backlog) emulates a router buffer: excess is tail-dropped.
                if nextBusyUntil.uptimeNanoseconds > DispatchTime.now().uptimeNanoseconds + 1_000_000_000 {
                    nextBusyUntil = start
                    stats.dropped += 1
                    return
                }
                when = max(when, nextBusyUntil)
            }
            let dup = c.duplicatePercent > 0 && Double.random(in: 0..<100) < c.duplicatePercent
            if when > .now() + .microseconds(200) {
                delayQueue.asyncAfter(deadline: when) { [weak self] in
                    self?.queue.async { self?.rawSend(frame, to: path); if dup { self?.rawSend(frame, to: path) } }
                }
                return
            }
            if dup { rawSend(frame, to: path) }
        }
        rawSend(frame, to: path)
    }

    private func rawSend(_ frame: Data, to path: String) {
        var addr = SockAddr.make(path)
        let r = frame.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        if r < 0 {
            if errno == ECONNREFUSED || errno == ENOENT { clients.remove(path); macTable = macTable.filter { $0.value != path } }
            stats.dropped += 1
        } else {
            stats.framesOut += 1
            stats.bytes += frame.count
        }
    }
}

/// Minimal DHCP server (DISCOVER→OFFER, REQUEST→ACK) over raw Ethernet frames.
public enum DHCPServer {
    public static func reply(to frame: Data, subnet: String, leases: inout [Data: UInt8]) -> Data? {
        let f = [UInt8](frame)
        // Ethernet(14) IPv4 UDP 68→67
        guard f.count >= 14 + 20 + 8 + 240, f[12] == 0x08, f[13] == 0x00 else { return nil }
        let ihl = Int(f[14] & 0x0F) * 4
        guard f[14 + 9] == 17 else { return nil }
        let udp = 14 + ihl
        guard f.count >= udp + 8 + 240 else { return nil }
        let sport = Int(f[udp]) << 8 | Int(f[udp + 1]), dport = Int(f[udp + 2]) << 8 | Int(f[udp + 3])
        guard sport == 68, dport == 67 else { return nil }
        let bootp = udp + 8
        guard f[bootp] == 1 else { return nil } // BOOTREQUEST
        // magic cookie
        guard f[bootp + 236] == 99, f[bootp + 237] == 130, f[bootp + 238] == 83, f[bootp + 239] == 99 else { return nil }
        var msgType: UInt8 = 0
        var i = bootp + 240
        while i < f.count, f[i] != 255 {
            if f[i] == 0 { i += 1; continue }
            guard i + 1 < f.count else { break }
            let len = Int(f[i + 1])
            if f[i] == 53, len >= 1, i + 2 < f.count { msgType = f[i + 2] }
            i += 2 + len
        }
        guard msgType == 1 || msgType == 3 else { return nil } // DISCOVER / REQUEST
        let chaddr = Data(f[(bootp + 28)..<(bootp + 34)])
        let host: UInt8
        if let h = leases[chaddr] { host = h } else {
            let used = Set(leases.values)
            guard let free = (10...250).map({ UInt8($0) }).first(where: { !used.contains($0) }) else { return nil }
            host = free
            leases[chaddr] = host
        }
        let parts = subnet.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 3 else { return nil }
        let server: [UInt8] = parts + [1]
        let client: [UInt8] = parts + [host]
        let serverMAC: [UInt8] = [0x02, 0xA1, 0x7F, 0x00, 0x00, 0x01]

        var b = [UInt8](repeating: 0, count: 240)
        b[0] = 2; b[1] = 1; b[2] = 6
        for k in 4..<8 { b[k] = f[bootp + k] }       // xid
        b[10] = f[bootp + 10]; b[11] = f[bootp + 11] // flags
        for k in 0..<4 { b[16 + k] = client[k]; b[20 + k] = server[k] }
        for k in 0..<16 { b[28 + k] = f[bootp + 28 + k] }
        b[236] = 99; b[237] = 130; b[238] = 83; b[239] = 99
        b += [53, 1, msgType == 1 ? 2 : 5]          // OFFER / ACK
        b += [54, 4] + server                          // server id
        b += [51, 4, 0, 1, 0x51, 0x80]                 // lease 86400s
        b += [1, 4, 255, 255, 255, 0]                  // netmask
        b += [3, 4] + server                           // router (lab gateway, no upstream)
        b += [6, 4] + server                           // DNS
        b += [255]
        while b.count < 300 { b.append(0) }

        var udpH: [UInt8] = [0, 67, 0, 68]
        let udpLen = 8 + b.count
        udpH += [UInt8(udpLen >> 8), UInt8(udpLen & 0xFF), 0, 0]
        let totalLen = 20 + udpLen
        var ip: [UInt8] = [0x45, 0, UInt8(totalLen >> 8), UInt8(totalLen & 0xFF), 0, 0, 0, 0, 64, 17, 0, 0]
        ip += server + [255, 255, 255, 255]
        let cs = checksum(ip)
        ip[10] = UInt8(cs >> 8); ip[11] = UInt8(cs & 0xFF)
        let eth: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] + serverMAC + [0x08, 0x00]
        return Data(eth + ip + udpH + b)
    }

    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count { sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1]); i += 2 }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }
}
