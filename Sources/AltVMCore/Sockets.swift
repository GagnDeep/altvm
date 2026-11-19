import Foundation
import Darwin
import CryptoKit

/// Short per-user runtime directory for UNIX sockets (sun_path is limited to 104 bytes, and VM
/// bundle paths are long). Scoped by ALTVM_HOME so parallel test homes never collide.
public enum Runtime {
    public static var dir: URL {
        let h = SHA256.hash(data: Data(Paths.home.path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let url = URL(fileURLWithPath: "/tmp/altvm-\(getuid())-\(h)", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        return url
    }
    public static func controlSocket(_ vm: String) -> URL { dir.appendingPathComponent("\(vm).ctl") }
    public static func switchSocket(_ name: String) -> URL { dir.appendingPathComponent("sw-\(name).sock") }
    public static func switchClientSocket(vm: String, nic: Int) -> URL { dir.appendingPathComponent("\(vm).nic\(nic)") }
}

enum SockAddr {
    static func make(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(103))
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    static func path(_ addr: sockaddr_un) -> String {
        var a = addr
        return withUnsafeBytes(of: &a.sun_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

public enum UnixSocket {
    public static func listen(path: String, type: Int32 = SOCK_STREAM) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, type, 0)
        guard fd >= 0 else { throw AltVMError.io("socket: \(String(cString: strerror(errno)))") }
        var addr = SockAddr.make(path)
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard r == 0 else { close(fd); throw AltVMError.io("bind \(path): \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)
        if type == SOCK_STREAM { Darwin.listen(fd, 16) }
        return fd
    }

    public static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AltVMError.io("socket") }
        var addr = SockAddr.make(path)
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard r == 0 else { close(fd); throw AltVMError.io("connect \(path): \(String(cString: strerror(errno)))") }
        return fd
    }

    /// Datagram socket bound to `local` and connected to `remote` (for VZFileHandleNetworkDeviceAttachment).
    public static func datagramPair(local: String, remote: String) throws -> Int32 {
        let fd = try listen(path: local, type: SOCK_DGRAM)
        var addr = SockAddr.make(remote)
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard r == 0 else { close(fd); throw AltVMError.io("connect \(remote): \(String(cString: strerror(errno)))") }
        // Ethernet frames up to 64 KiB (TSO); generous buffers avoid drops under load.
        var size: Int32 = 4 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }
}

/// Line-oriented JSON over a stream fd (used by the control socket and guest agent).
public final class LineChannel {
    public let fd: Int32
    private var buffer = Data()
    private let ownsFD: Bool

    public init(fd: Int32, ownsFD: Bool = true) {
        self.fd = fd
        self.ownsFD = ownsFD
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }
    deinit { if ownsFD { close(fd) } }

    public func setTimeout(seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    public func send(_ data: Data) throws {
        var d = data
        d.append(0x0A)
        try d.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { throw AltVMError.io("write: \(String(cString: strerror(errno)))") }
                off += n
            }
        }
    }

    public func sendJSON(_ obj: [String: Any]) throws {
        try send(JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]))
    }

    /// Returns nil on EOF. Linear in the line length (only newly read bytes are scanned).
    public func readLine() throws -> Data? {
        var scanFrom = buffer.startIndex
        var chunk = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            if let i = buffer[scanFrom...].firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<i])
                buffer = Data(buffer[buffer.index(after: i)...])
                return line
            }
            scanFrom = buffer.endIndex
            let n = read(fd, &chunk, chunk.count)
            if n == 0 {
                if buffer.isEmpty { return nil }
                defer { buffer = Data() }
                return buffer
            }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { throw AltVMError.io("timed out") }
                throw AltVMError.io("read: \(String(cString: strerror(errno)))")
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    public func readJSON() throws -> [String: Any]? {
        guard let line = try readLine() else { return nil }
        return try JSONSerialization.jsonObject(with: line) as? [String: Any]
    }
}
