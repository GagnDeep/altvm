import Foundation
import Virtualization
import ObjectiveC
import CommonCrypto
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Wraps Virtualization.framework's built-in VNC server (`_VZVNCServer`, private API — the same
/// one other VZ tools use). It is what makes any guest — macOS, Windows installers, Linux desktops —
/// visible and controllable headlessly, from another process, for AI computer-use agents and for
/// Screen Sharing.
///
/// Security: the framework binds the listener on all interfaces, so the server is started lazily
/// (only when a viewer or agent asks), always uses a fresh random password, can be disabled by
/// policy (`allowRemoteDisplay = false`) and dies with the VM process.
@MainActor
public final class VNCServerHost {
    public let port: UInt16
    public let password: String
    private let server: NSObject

    public init(vm: VZVirtualMachine) throws {
        guard let srvCls = objc_getClass("_VZVNCServer") as? NSObject.Type,
              let secCls = objc_getClass("_VZVNCAuthenticationSecurityConfiguration") as? NSObject.Type else {
            throw AltVMError.unsupported("this macOS build has no VZ remote display server")
        }
        // VNC passwords are at most 8 bytes; use the full alphabet for entropy.
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        password = String((0..<8).map { _ in alphabet.randomElement()! })
        let sec = (secCls.perform(NSSelectorFromString("alloc")).takeUnretainedValue() as! NSObject)
            .perform(NSSelectorFromString("initWithPassword:"), with: password).takeUnretainedValue()
        let allocated = srvCls.perform(NSSelectorFromString("alloc")).takeUnretainedValue()
        typealias InitFn = @convention(c) (AnyObject, Selector, UInt16, DispatchQueue, AnyObject) -> AnyObject?
        let sel = NSSelectorFromString("initWithPort:queue:securityConfiguration:")
        guard let imp = class_getMethodImplementation(srvCls, sel),
              let s = unsafeBitCast(imp, to: InitFn.self)(allocated, sel, 0, DispatchQueue(label: "altvm.vnc"), sec) as? NSObject else {
            throw AltVMError.unsupported("could not create VZ remote display server")
        }
        server = s
        server.perform(NSSelectorFromString("setVirtualMachine:"), with: vm)
        server.perform(NSSelectorFromString("start"))
        typealias PortFn = @convention(c) (AnyObject, Selector) -> UInt16
        let psel = NSSelectorFromString("port")
        let portFn = unsafeBitCast(class_getMethodImplementation(srvCls, psel)!, to: PortFn.self)
        var p: UInt16 = 0
        for _ in 0..<50 {
            p = portFn(server, psel)
            if p != 0 { break }
            usleep(20_000)
        }
        guard p != 0 else { throw AltVMError.io("VZ remote display server did not start") }
        port = p
    }

    public func stop() { server.perform(NSSelectorFromString("stop")) }

    public var url: String { "vnc://:\(password)@127.0.0.1:\(port)" }
}

/// Minimal RFB 3.8 client: VNC auth, raw encoding, desktop resize, pointer and key events.
public final class RFBClient: @unchecked Sendable {
    static let debug = ProcessInfo.processInfo.environment["ALTVM_RFB_DEBUG"] != nil
    static func trace(_ s: @autoclosure () -> String) { if debug { FileHandle.standardError.write(Data("[rfb] \(s())\n".utf8)) } }
    public private(set) var width = 0
    public private(set) var height = 0
    private var fb = [UInt8]()   // BGRX, 4 bytes per pixel
    private let fd: Int32
    private var buttons: UInt8 = 0

    public init(port: UInt16, password: String) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AltVMError.io("socket") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard r == 0 else { close(fd); throw AltVMError.io("connect to display server: \(String(cString: strerror(errno)))") }
        do { try handshake(password: password) } catch { close(fd); throw error }
        // The timeout only guards the handshake. Afterwards the reader blocks until the server
        // sends something — an idle screen can be silent for minutes (that is not an error).
        var none = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit { close(fd) }

    // MARK: wire helpers

    private func readExact(_ n: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: n)
        var off = 0
        while off < n {
            let r = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + off, n - off) }
            if r <= 0 {
                if r < 0 && errno == EINTR { continue }
                Self.trace("read returned \(r) errno=\(errno) wanting \(n - off) more bytes")
                throw AltVMError.io("display connection closed")
            }
            off += r
        }
        return buf
    }

    private func readInto(_ buf: inout [UInt8], offset: Int, count: Int) throws {
        var off = 0
        while off < count {
            let r = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + offset + off, count - off) }
            if r <= 0 {
                if r < 0 && errno == EINTR { continue }
                throw AltVMError.io("display connection closed")
            }
            off += r
        }
    }

    private func send(_ bytes: [UInt8]) throws {
        var off = 0
        while off < bytes.count {
            let r = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + off, bytes.count - off) }
            if r <= 0 { throw AltVMError.io("display write failed") }
            off += r
        }
    }

    private func u16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) << 8 | Int(b[o + 1]) }
    private func u32(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) }
    private func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    private func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    // MARK: handshake

    private func handshake(password: String) throws {
        let version = try readExact(12)
        guard String(decoding: version, as: UTF8.self).hasPrefix("RFB ") else { throw AltVMError.io("not an RFB server") }
        try send(Array("RFB 003.008\n".utf8))
        let n = Int(try readExact(1)[0])
        if n == 0 {
            let len = u32(try readExact(4), 0)
            throw AltVMError.io("display server refused: \(String(decoding: try readExact(len), as: UTF8.self))")
        }
        let types = try readExact(n)
        if types.contains(2) {
            try send([2])
            let challenge = try readExact(16)
            try send(Self.vncAuthResponse(challenge: challenge, password: password))
        } else if types.contains(1) {
            try send([1])
        } else {
            throw AltVMError.unsupported("display security types \(types)")
        }
        guard u32(try readExact(4), 0) == 0 else { throw AltVMError.policy("display authentication failed") }
        try send([1]) // shared
        let si = try readExact(24)
        width = u16(si, 0)
        height = u16(si, 2)
        Self.trace("ServerInit \(width)x\(height) bpp=\(si[4]) depth=\(si[5])")
        _ = try readExact(u32(si, 20)) // name
        fb = [UInt8](repeating: 0, count: width * height * 4)
        // 32bpp little-endian true colour, B,G,R,X in memory.
        try send([0, 0, 0, 0, 32, 24, 0, 1] + be16(255) + be16(255) + be16(255) + [16, 8, 0, 0, 0, 0])
        let encodings: [Int32] = [0, -223] // Raw, DesktopSize
        try send([2, 0] + be16(encodings.count) + encodings.flatMap { be32(Int(UInt32(bitPattern: $0))) })
    }

    /// VNC auth: DES-ECB of the challenge with the (bit-reversed) password as key.
    static func vncAuthResponse(challenge: [UInt8], password: String) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 8)
        for (i, b) in Array(password.utf8.prefix(8)).enumerated() {
            var r: UInt8 = 0
            for bit in 0..<8 where b & (1 << bit) != 0 { r |= 1 << (7 - bit) }
            key[i] = r
        }
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
                key, kCCKeySizeDES, nil, challenge, 16, &out, 16, &moved)
        return out
    }

    // MARK: framebuffer (live, maintained by a background reader)

    private let cond = NSCondition()
    private var updates = 0          // completed FramebufferUpdate messages
    private var readerError: Error?
    private var started = false

    private func startReader() {
        if started { return }
        started = true
        Thread.detachNewThread { [weak self] in
            while let self {
                do { try self.readOneMessage() } catch {
                    self.cond.lock(); self.readerError = error; self.cond.broadcast(); self.cond.unlock()
                    return
                }
            }
        }
    }

    /// False once the connection has failed; the owner should reconnect.
    public var isAlive: Bool { cond.lock(); defer { cond.unlock() }; return readerError == nil }

    private func requestUpdate(incremental: Bool) throws {
        let (w, h): (Int, Int) = { cond.lock(); defer { cond.unlock() }; return (width, height) }()
        // A guest that hasn't set a video mode yet reports 0×0; requesting a 0×0 area makes the
        // server drop the connection. Ask for a 1×1 area instead — the server answers with a
        // DesktopSize update once a real mode exists.
        if w == 0 || h == 0 {
            try sendLocked([3, 0, 0, 0, 0, 0] + be16(1) + be16(1))
            return
        }
        try sendLocked([3, incremental ? 1 : 0, 0, 0, 0, 0] + be16(w) + be16(h))
    }

    private let writeLock = NSLock()
    private func sendLocked(_ bytes: [UInt8]) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        try send(bytes)
    }

    private func readOneMessage() throws {
        let type = try readExact(1)[0]
        Self.trace("message type \(type)")
        switch type {
        case 0:
            let hdr = try readExact(3)
            let rects = u16(hdr, 1)
            for _ in 0..<rects {
                let r = try readExact(12)
                let x = u16(r, 0), y = u16(r, 2), w = u16(r, 4), h = u16(r, 6)
                let enc = Int32(bitPattern: UInt32(u32(r, 8)))
                Self.trace("rect \(x),\(y) \(w)x\(h) enc=\(enc)")
                if enc == -223 {
                    cond.lock(); width = w; height = h; fb = [UInt8](repeating: 0, count: w * h * 4); cond.unlock()
                    continue
                }
                guard enc == 0 else { throw AltVMError.unsupported("display encoding \(enc)") }
                let data = try readExact(w * h * 4)
                cond.lock()
                for row in 0..<h where y + row < height && x < width {
                    let dst = ((y + row) * width + x) * 4
                    let n = min(w, width - x) * 4
                    fb.replaceSubrange(dst..<(dst + n), with: data[(row * w * 4)..<(row * w * 4 + n)])
                }
                cond.unlock()
            }
            cond.lock(); updates += 1; cond.broadcast(); cond.unlock()
            try requestUpdate(incremental: true)   // keep one request outstanding → live framebuffer
        case 1:
            let h = try readExact(5)
            _ = try readExact(u16(h, 3) * 6)
        case 2:
            break
        case 3:
            let h = try readExact(7)
            _ = try readExact(u32(h, 3))
        default:
            throw AltVMError.io("unexpected display message \(type)")
        }
    }

    /// Requests a full frame and waits until it (and anything queued before it) has arrived.
    public func refresh(timeout: TimeInterval = 3) throws {
        startReader()
        cond.lock()
        let target = updates + 1
        cond.unlock()
        try requestUpdate(incremental: false)
        cond.lock(); defer { cond.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while updates < target {
            if let e = readerError { throw e }
            if !cond.wait(until: deadline) { break }
        }
    }

    /// PNG of the current screen, optionally downscaled so the longest side ≤ maxDimension.
    private var hadFrame = false

    public func screenshotPNG(maxDimension: Int? = nil) throws -> (png: Data, width: Int, height: Int, scale: Double) {
        try refresh()
        // A fresh connection can answer before the server has received its first guest frame.
        var tries = 0
        while !hadFrame && tries < 8 {
            cond.lock(); let blank = !fb.contains(where: { $0 != 0 }); cond.unlock()
            if !blank { break }
            tries += 1
            usleep(150_000)
            try refresh()
        }
        hadFrame = true
        usleep(60_000) // let in-flight incremental updates land
        cond.lock()
        let frame = fb
        cond.unlock()
        guard width > 0, height > 0 else { throw AltVMError.io("display has no video mode yet (guest still booting?)") }
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(frame) as CFData),
              var image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: cs, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw AltVMError.io("could not build screenshot")
        }
        var scale = 1.0
        if let maxD = maxDimension, max(width, height) > maxD {
            scale = Double(maxD) / Double(max(width, height))
            let w = Int(Double(width) * scale), h = Int(Double(height) * scale)
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                if let scaled = ctx.makeImage() { image = scaled }
            }
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { throw AltVMError.io("png") }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return (out as Data, image.width, image.height, scale)
    }

    // MARK: input

    public func pointer(x: Int, y: Int, buttons mask: UInt8) throws {
        buttons = mask
        try sendLocked([5, mask] + be16(max(0, min(x, width - 1))) + be16(max(0, min(y, height - 1))))
    }

    public enum Button: String { case left, middle, right
        var mask: UInt8 { switch self { case .left: return 1; case .middle: return 2; case .right: return 4 } }
    }

    public func click(x: Int, y: Int, button: Button = .left, count: Int = 1) throws {
        try pointer(x: x, y: y, buttons: 0)
        for _ in 0..<max(1, count) {
            try pointer(x: x, y: y, buttons: button.mask)
            usleep(30_000)
            try pointer(x: x, y: y, buttons: 0)
            usleep(60_000)
        }
    }

    public func drag(from: (Int, Int), to: (Int, Int)) throws {
        try pointer(x: from.0, y: from.1, buttons: 0)
        try pointer(x: from.0, y: from.1, buttons: 1)
        let steps = 12
        for i in 1...steps {
            let x = from.0 + (to.0 - from.0) * i / steps, y = from.1 + (to.1 - from.1) * i / steps
            try pointer(x: x, y: y, buttons: 1)
            usleep(15_000)
        }
        try pointer(x: to.0, y: to.1, buttons: 0)
    }

    /// Positive dy scrolls down.
    public func scroll(x: Int, y: Int, dy: Int, dx: Int = 0) throws {
        let vMask: UInt8 = dy > 0 ? 16 : 8, hMask: UInt8 = dx > 0 ? 64 : 32
        for _ in 0..<abs(dy) { try pointer(x: x, y: y, buttons: vMask); try pointer(x: x, y: y, buttons: 0) }
        for _ in 0..<abs(dx) { try pointer(x: x, y: y, buttons: hMask); try pointer(x: x, y: y, buttons: 0) }
    }

    public func keyEvent(_ keysym: UInt32, down: Bool) throws {
        try sendLocked([4, down ? 1 : 0, 0, 0] + be32(Int(keysym)))
    }

    /// Presses a chord such as "cmd+space", "ctrl+alt+delete", "Return", "shift+Tab".
    public func press(_ chord: String) throws {
        let parts = chord.split(separator: "+").map { String($0) }
        let syms = try parts.map { p -> UInt32 in
            guard let s = Keysym.named(p) else { throw AltVMError.invalid("unknown key '\(p)'") }
            return s
        }
        for s in syms { try keyEvent(s, down: true); usleep(10_000) }
        for s in syms.reversed() { try keyEvent(s, down: false); usleep(10_000) }
    }

    /// Types text using a US layout (shift is applied for shifted characters).
    public func type(_ text: String, delayMicros: UInt32 = 8_000) throws {
        for ch in text {
            let (sym, shift) = Keysym.forCharacter(ch)
            if shift { try keyEvent(Keysym.shift, down: true) }
            try keyEvent(sym, down: true)
            try keyEvent(sym, down: false)
            if shift { try keyEvent(Keysym.shift, down: false) }
            usleep(delayMicros)
        }
    }
}

public enum Keysym {
    static let shift: UInt32 = 0xFFE1

    static let names: [String: UInt32] = [
        "return": 0xFF0D, "enter": 0xFF0D, "tab": 0xFF09, "escape": 0xFF1B, "esc": 0xFF1B,
        "backspace": 0xFF08, "delete": 0xFFFF, "del": 0xFFFF, "insert": 0xFF63, "home": 0xFF50, "end": 0xFF57,
        "pageup": 0xFF55, "page_up": 0xFF55, "pagedown": 0xFF56, "page_down": 0xFF56,
        "left": 0xFF51, "up": 0xFF52, "right": 0xFF53, "down": 0xFF54, "space": 0x20,
        // Measured against Virtualization.framework's server (keysym → HID usage):
        //   Alt_L (FFE9) → Left GUI (⌘ / Win / Super)   Meta_L (FFE7) → Left Alt (⌥ / Alt)
        //   Super_L/R are ignored by the server, so never send them.
        "shift": 0xFFE1, "ctrl": 0xFFE3, "control": 0xFFE3,
        "alt": 0xFFE7, "option": 0xFFE7, "opt": 0xFFE7, "meta": 0xFFE7,
        "cmd": 0xFFE9, "command": 0xFFE9, "super": 0xFFE9, "win": 0xFFE9, "windows": 0xFFE9, "gui": 0xFFE9,
        "rshift": 0xFFE2, "rctrl": 0xFFE4, "ralt": 0xFFE8, "rcmd": 0xFFEA,
        "capslock": 0xFFE5, "printscreen": 0xFF61, "menu": 0xFF67, "kp_enter": 0xFF8D,
        "minus": 0x2D, "plus": 0x2B, "equal": 0x3D, "comma": 0x2C, "period": 0x2E, "slash": 0x2F,
        "backslash": 0x5C, "semicolon": 0x3B, "apostrophe": 0x27, "grave": 0x60, "bracketleft": 0x5B, "bracketright": 0x5D,
    ]

    public static func named(_ raw: String) -> UInt32? {
        let k = raw.lowercased()
        if let s = names[k] { return s }
        if k.hasPrefix("f"), let n = Int(k.dropFirst()), (1...24).contains(n) { return 0xFFBE + UInt32(n - 1) }
        if raw.count == 1, let c = raw.first { return forCharacter(Character(c.lowercased())).0 }
        if k.hasPrefix("0x"), let v = UInt32(k.dropFirst(2), radix: 16) { return v }
        return nil
    }

    static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    /// (keysym, needsShift) for a US layout.
    public static func forCharacter(_ ch: Character) -> (UInt32, Bool) {
        switch ch {
        case "\n", "\r": return (0xFF0D, false)
        case "\t": return (0xFF09, false)
        default: break
        }
        guard let scalar = ch.unicodeScalars.first else { return (0x20, false) }
        let v = scalar.value
        if ch.isUppercase && v < 0x80 { return (v, true) }
        if shifted[ch] != nil { return (v, true) }
        if v < 0x100 { return (v, false) }
        return (0x0100_0000 + v, false)
    }
}
