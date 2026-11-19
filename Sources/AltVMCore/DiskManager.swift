import Foundation
import Darwin

/// Disk images are raw sparse files. On APFS that gives us, for free:
///  * thin provisioning (a 128 GB disk uses only what the guest wrote),
///  * instant copy-on-write snapshots and clones via clonefile(2),
///  * hole punching to reclaim space (`compact`).
public enum DiskManager {
    public static func createSparse(at url: URL, sizeGiB: UInt64) throws {
        let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw AltVMError.io("create \(url.path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        guard ftruncate(fd, off_t(sizeGiB * 1024 * 1024 * 1024)) == 0 else {
            throw AltVMError.io("truncate \(url.path): \(String(cString: strerror(errno)))")
        }
    }

    /// Grow a disk (guest must then extend its partition — the guest agent does this for Linux).
    public static func resize(at url: URL, toGiB: UInt64) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let current = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let target = toGiB * 1024 * 1024 * 1024
        guard target > current else { throw AltVMError.invalid("disks can only grow (current \(current / (1 << 30)) GiB)") }
        guard truncate(url.path, off_t(target)) == 0 else {
            throw AltVMError.io("resize: \(String(cString: strerror(errno)))")
        }
    }

    /// APFS clonefile for a single file; falls back to a real copy on non-APFS volumes.
    public static func cloneFile(from src: URL, to dst: URL) throws {
        if clonefile(src.path, dst.path, 0) == 0 { return }
        if errno == ENOTSUP || errno == EXDEV {
            try FileManager.default.copyItem(at: src, to: dst)
            return
        }
        throw AltVMError.io("clonefile \(src.lastPathComponent): \(String(cString: strerror(errno)))")
    }

    /// clonefile works on directories too (recursive CoW clone).
    public static func cloneTree(from src: URL, to dst: URL) throws {
        try cloneFile(from: src, to: dst)
    }

    /// Reclaim space: punch holes over every fully-zero 1 MiB region of the image.
    /// Combined with the guest's TRIM / `fstrim` (issued by the guest agent) this returns
    /// freed guest space to the Mac. Returns bytes reclaimed.
    @discardableResult
    public static func compact(at url: URL, progress: ((Double) -> Void)? = nil) throws -> UInt64 {
        let before = allocated(url)
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else { throw AltVMError.io("open \(url.path)") }
        defer { close(fd) }
        var st = stat()
        fstat(fd, &st)
        let size = UInt64(st.st_size)
        let chunk = 1 << 20
        var buf = [UInt8](repeating: 0, count: chunk)
        var offset: UInt64 = 0
        var lastReport = 0.0
        while offset < size {
            // Skip holes quickly.
            let data = lseek(fd, off_t(offset), SEEK_DATA)
            if data < 0 { break }
            offset = UInt64(data) & ~UInt64(chunk - 1)
            let n = pread(fd, &buf, chunk, off_t(offset))
            if n <= 0 { break }
            if buf.withUnsafeBytes({ raw in isZero(raw.baseAddress!, n) }) {
                var punch = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(offset), fp_length: off_t(n))
                _ = fcntl(fd, F_PUNCHHOLE, &punch)
            }
            offset += UInt64(n)
            let p = Double(offset) / Double(size)
            if p - lastReport > 0.01 { progress?(p); lastReport = p }
        }
        progress?(1)
        let after = allocated(url)
        return before > after ? before - after : 0
    }

    private static func isZero(_ p: UnsafeRawPointer, _ n: Int) -> Bool {
        let words = n / 8
        let w = p.assumingMemoryBound(to: UInt64.self)
        for i in 0..<words where w[i] != 0 { return false }
        let b = p.assumingMemoryBound(to: UInt8.self)
        for i in (words * 8)..<n where b[i] != 0 { return false }
        return true
    }

    public static func allocated(_ url: URL) -> UInt64 {
        let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return UInt64(v?.totalFileAllocatedSize ?? 0)
    }

    public static func logicalSize(_ url: URL) -> UInt64 {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(v?.fileSize ?? 0)
    }
}

public func formatBytes(_ b: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
}
