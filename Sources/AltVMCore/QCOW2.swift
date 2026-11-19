import Foundation
import Compression

/// Native qcow2 → raw (sparse) converter, so standard cloud images (Ubuntu, Fedora, Rocky,
/// Alma, openSUSE…) work without installing qemu-img. Supports v2/v3, zlib-compressed clusters,
/// zero clusters. Backing files and encryption are rejected.
public enum QCOW2 {
    public static func isQCOW2(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url), let d = try? fh.read(upToCount: 4) else { return false }
        try? fh.close()
        return d == Data([0x51, 0x46, 0x49, 0xFB])
    }

    public static func convert(_ src: URL, to dst: URL, progress: ((Double) -> Void)? = nil) throws {
        let fh = try FileHandle(forReadingFrom: src)
        defer { try? fh.close() }
        func readAt(_ off: UInt64, _ n: Int) throws -> Data {
            try fh.seek(toOffset: off)
            return try fh.read(upToCount: n) ?? Data()
        }
        func be64(_ d: Data, _ o: Int) -> UInt64 { d[d.startIndex + o..<d.startIndex + o + 8].reduce(0) { $0 << 8 | UInt64($1) } }
        func be32(_ d: Data, _ o: Int) -> UInt32 { d[d.startIndex + o..<d.startIndex + o + 4].reduce(0) { $0 << 8 | UInt32($1) } }

        let h = try readAt(0, 112)
        guard h.count >= 72, be32(h, 0) == 0x514649FB else { throw AltVMError.invalid("not a qcow2 image") }
        let version = be32(h, 4)
        guard be64(h, 8) == 0 else { throw AltVMError.unsupported("qcow2 backing files") }
        let clusterBits = Int(be32(h, 20))
        let size = be64(h, 24)
        guard be32(h, 32) == 0 else { throw AltVMError.unsupported("encrypted qcow2") }
        let l1Size = Int(be32(h, 36))
        let l1Offset = be64(h, 40)
        if version >= 3 {
            let incompat = be64(h, 72)
            if incompat & 0b100 != 0 { throw AltVMError.unsupported("qcow2 external data file") }
            if incompat & 0b1000 != 0, h.count > 104, h[104] != 0 { throw AltVMError.unsupported("qcow2 zstd compression") }
            if incompat & 0b10000 != 0 { throw AltVMError.unsupported("qcow2 extended L2 entries") }
        }
        let clusterSize = 1 << clusterBits
        let l2Entries = clusterSize / 8

        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let out = open(dst.path, O_RDWR | O_TRUNC)
        guard out >= 0 else { throw AltVMError.io("open \(dst.path)") }
        defer { close(out) }
        ftruncate(out, off_t(size))

        let l1 = try readAt(l1Offset, l1Size * 8)
        let offMask: UInt64 = 0x00FF_FFFF_FFFF_FE00
        let x = 62 - (clusterBits - 8)
        let compOffMask: UInt64 = (1 << UInt64(x)) - 1
        let compSecMask: UInt64 = (1 << UInt64(clusterBits - 8)) - 1
        var outBuf = [UInt8](repeating: 0, count: clusterSize)
        for i in 0..<l1Size {
            progress?(Double(i) / Double(max(1, l1Size)))
            let l2Off = be64(l1, i * 8) & offMask
            if l2Off == 0 { continue }
            let l2 = try readAt(l2Off, clusterSize)
            for j in 0..<l2Entries {
                let guestOff = (UInt64(i) * UInt64(l2Entries) + UInt64(j)) * UInt64(clusterSize)
                if guestOff >= size { break }
                let e = be64(l2, j * 8)
                if e == 0 { continue }
                let n = Int(min(UInt64(clusterSize), size - guestOff))
                if e & (1 << 62) != 0 {
                    let hostOff = e & compOffMask
                    let sectors = ((e >> UInt64(x)) & compSecMask) + 1
                    let csize = Int(sectors * 512 - (hostOff & 511))
                    let comp = try readAt(hostOff, csize)
                    let written = comp.withUnsafeBytes { src in
                        compression_decode_buffer(&outBuf, clusterSize, src.bindMemory(to: UInt8.self).baseAddress!, comp.count, nil, COMPRESSION_ZLIB)
                    }
                    guard written > 0 else { throw AltVMError.io("qcow2: failed to inflate cluster at \(hostOff)") }
                    if written < clusterSize { for k in written..<clusterSize { outBuf[k] = 0 } }
                    if outBuf.allSatisfy({ $0 == 0 }) { continue }
                    pwrite(out, outBuf, n, off_t(guestOff))
                } else {
                    if e & 1 != 0 { continue } // zero cluster
                    let hostOff = e & offMask
                    if hostOff == 0 { continue }
                    let data = try readAt(hostOff, n)
                    if data.allSatisfy({ $0 == 0 }) { continue }
                    _ = data.withUnsafeBytes { pwrite(out, $0.baseAddress, data.count, off_t(guestOff)) }
                }
            }
        }
        progress?(1)
    }
}
