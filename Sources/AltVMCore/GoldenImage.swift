import Foundation
import CryptoKit
import Compression

/// Golden images: a VM packaged as a single signed, compressed, sparse-aware `.avmimg` file.
///
/// Layout: "AVMIMG01" | payload | header JSON | u64 headerLength | "AVMIMGND"
/// payload = for each file: records of [u64 offset][u32 compLen][u32 rawLen][LZFSE bytes],
///           terminated by offset = UInt64.max. All-zero 1 MiB chunks are skipped, so a 64 GB disk
///           with 3 GB used produces ~1 GB and re-expands *sparse*.
/// The Ed25519 signature covers the manifest, which pins the payload SHA-256.
public enum GoldenImage {
    public struct FileEntry: Codable, Equatable, Sendable { public var path: String; public var size: UInt64 }
    public struct Manifest: Codable, Equatable, Sendable {
        public var format = 1
        public var name: String
        public var version: String
        public var description: String
        public var publisher: String
        public var created: Date
        public var os: GuestOS
        public var spec: VMSpec
        public var files: [FileEntry]
        public var payloadSHA256: String
        public var payloadBytes: UInt64
    }
    struct Header: Codable { var manifest: String; var signature: String?; var publicKey: String? }

    static let magic = Data("AVMIMG01".utf8)
    static let endMagic = Data("AVMIMGND".utf8)
    static let chunk = 1 << 20

    static let excluded: Set<String> = ["run.pid", "run.lock", "console.log", "run.log", "state.vzvmsave", "snapshots", "control.sock"]

    // MARK: pack

    @discardableResult
    public static func pack(vm: String, to out: URL, version: String = "1.0", description: String = "",
                            signingKey: URL?, progress: ((Double) -> Void)? = nil) throws -> Manifest {
        let bundle = try VMLibrary.find(vm)
        if bundle.isRunning { throw AltVMError.running(vm) }
        let spec = try bundle.loadSpec()
        let files = try FileManager.default.contentsOfDirectory(at: bundle.url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
            .filter { !excluded.contains($0.lastPathComponent) && !$0.lastPathComponent.hasSuffix(".vzvmsave") }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let entries = files.map { FileEntry(path: $0.lastPathComponent, size: DiskManager.logicalSize($0)) }
        let total = entries.reduce(0) { $0 + $1.size }

        FileManager.default.createFile(atPath: out.path, contents: nil)
        let fh = try FileHandle(forWritingTo: out)
        defer { try? fh.close() }
        fh.write(magic)
        var hasher = SHA256()
        var payloadBytes: UInt64 = 0
        func emit(_ d: Data) { fh.write(d); hasher.update(data: d); payloadBytes += UInt64(d.count) }

        var done: UInt64 = 0
        let batch = max(4, ProcessInfo.processInfo.activeProcessorCount * 2)
        for f in files {
            let fd = open(f.path, O_RDONLY)
            guard fd >= 0 else { throw AltVMError.io("open \(f.path)") }
            defer { close(fd) }
            let size = DiskManager.logicalSize(f)
            var off: UInt64 = 0
            var eof = false
            while !eof {
                // 1. Read up to `batch` non-hole chunks sequentially.
                var reads: [(UInt64, [UInt8])] = []
                while reads.count < batch && off < size {
                    let dataOff = lseek(fd, off_t(off), SEEK_DATA)   // skip holes without reading them
                    if dataOff < 0 { off = size; break }
                    off = UInt64(dataOff) / UInt64(chunk) * UInt64(chunk)
                    var buf = [UInt8](repeating: 0, count: chunk)
                    let n = pread(fd, &buf, chunk, off_t(off))
                    if n <= 0 { off = size; break }
                    if n < chunk { buf.removeSubrange(n...) }
                    reads.append((off, buf))
                    off += UInt64(n)
                }
                if off >= size { eof = true }
                // 2. Compress the batch on all cores.
                var records = [Data?](repeating: nil, count: reads.count)
                records.withUnsafeMutableBufferPointer { out in
                    nonisolated(unsafe) let out = out
                    DispatchQueue.concurrentPerform(iterations: reads.count) { i in
                        let (o, src) = reads[i]
                        if src.allSatisfy({ $0 == 0 }) { return }
                        var dst = [UInt8](repeating: 0, count: src.count + 4096)
                        let c = compression_encode_buffer(&dst, dst.count, src, src.count, nil, COMPRESSION_LZFSE)
                        var rec = Data()
                        rec.append(be: o)
                        if c > 0 && c < src.count {
                            rec.append(be: UInt32(c)); rec.append(be: UInt32(src.count)); rec.append(contentsOf: dst[0..<c])
                        } else { // incompressible: store raw (compLen == rawLen)
                            rec.append(be: UInt32(src.count)); rec.append(be: UInt32(src.count)); rec.append(contentsOf: src)
                        }
                        out[i] = rec
                    }
                }
                // 3. Emit in order (keeps the payload deterministic).
                for r in records { if let r { emit(r) } }
                done = min(total, done + reads.reduce(0) { $0 + UInt64($1.1.count) })
                progress?(total > 0 ? Double(done) / Double(total) : 1)
            }
            var end = Data(); end.append(be: UInt64.max)
            emit(end)
        }
        let manifest = Manifest(name: spec.name, version: version, description: description,
                                publisher: signingKey.map { _ in NSFullUserName() } ?? "unsigned",
                                created: Date(), os: spec.os, spec: spec, files: entries,
                                payloadSHA256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
                                payloadBytes: payloadBytes)
        let mdata = try JSON.compactEncoder.encode(manifest)
        var header = Header(manifest: mdata.base64EncodedString(), signature: nil, publicKey: nil)
        if let signingKey {
            let key = try Signing.loadPrivateKey(signingKey)
            header.signature = try Signing.sign(mdata, with: key)
            header.publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        }
        let hdata = try JSON.compactEncoder.encode(header)
        fh.write(hdata)
        var len = Data(); len.append(be: UInt64(hdata.count))
        fh.write(len)
        fh.write(endMagic)
        progress?(1)
        AuditLog.shared.record("image.pack", vm: vm, details: ["out": out.lastPathComponent, "signed": "\(signingKey != nil)", "sha256": manifest.payloadSHA256])
        return manifest
    }

    // MARK: inspect / verify

    public struct Inspection { public var manifest: Manifest; public var signed: Bool; public var trusted: Bool; public var publicKey: String?; var payloadStart: UInt64 }

    public static func inspect(_ url: URL) throws -> Inspection {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        guard try fh.read(upToCount: 8) == magic else { throw AltVMError.invalid("not an AltVM image") }
        let size = try fh.seekToEnd()
        guard size > 32 else { throw AltVMError.invalid("truncated image") }
        try fh.seek(toOffset: size - 16)
        let tail = try fh.read(upToCount: 16) ?? Data()
        guard tail.suffix(8) == endMagic else { throw AltVMError.invalid("truncated image (no trailer)") }
        let hlen = tail.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard hlen < size else { throw AltVMError.invalid("corrupt header length") }
        try fh.seek(toOffset: size - 16 - hlen)
        let hdata = try fh.read(upToCount: Int(hlen)) ?? Data()
        let header = try JSON.decoder.decode(Header.self, from: hdata)
        guard let mdata = Data(base64Encoded: header.manifest) else { throw AltVMError.invalid("manifest encoding") }
        let manifest = try JSON.decoder.decode(Manifest.self, from: mdata)
        var signed = false, trusted = false
        if let sig = header.signature, let pk = header.publicKey {
            guard Signing.verify(mdata, signature: sig, publicKey: pk) else {
                throw AltVMError.policy("image signature INVALID — the image was modified after signing")
            }
            signed = true
            trusted = Signing.trustedKeys().contains(pk)
        }
        return Inspection(manifest: manifest, signed: signed, trusted: trusted, publicKey: header.publicKey, payloadStart: 8)
    }

    // MARK: deploy

    /// Verifies (signature, trust, policy, payload hash) and materialises a new VM.
    @discardableResult
    public static func deploy(_ url: URL, as name: String, progress: ((Double) -> Void)? = nil) throws -> VMBundle {
        try VMLibrary.validateName(name)
        let ins = try inspect(url)
        if let policy = Policy.loadActive(), policy.requireSignedImages {
            guard ins.signed, ins.trusted else { throw AltVMError.policy("policy requires images signed by a trusted key") }
            if !policy.allowedImageSigners.isEmpty, !policy.allowedImageSigners.contains(ins.publicKey ?? "") {
                throw AltVMError.policy("image signer not in policy.allowedImageSigners")
            }
        }
        let dst = VMLibrary.bundleURL(named: name)
        if FileManager.default.fileExists(atPath: dst.path) { throw AltVMError.alreadyExists("VM '\(name)'") }
        try Paths.ensure()
        let staging = Paths.vms.appendingPathComponent(".\(name).deploying", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try extract(url, ins: ins, into: staging, progress: progress)
            try FileManager.default.moveItem(at: staging, to: dst)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        let bundle = VMBundle(url: dst)
        try? FileManager.default.createDirectory(at: bundle.snapshotsURL, withIntermediateDirectories: true)
        var spec = ins.manifest.spec
        spec.name = name
        spec.created = Date()
        spec.network = spec.network.map { var n = $0; n.macAddress = MACAddress.random(); return n }
        spec.labels["image"] = "\(ins.manifest.name)@\(ins.manifest.version)"
        if let p = Policy.loadActive(), p.organization != "LOCKDOWN" { p.remediate(&spec) }
        if spec.os != .macOS { try? FileManager.default.removeItem(at: bundle.machineIdentifierURL) }
        try bundle.saveSpec(spec)
        // Re-seed cloud-init so the clone gets its own hostname / instance id / host keys.
        if spec.disks.contains(where: { $0.file == "seed.iso" }) {
            var o = CreateOptions(name: name)
            o.username = NSUserName()
            try? CloudInit.writeSeed(to: bundle.url.appendingPathComponent("seed.iso"), spec: spec, options: o)
        }
        AuditLog.shared.record("image.deploy", vm: name, details: ["image": ins.manifest.name, "version": ins.manifest.version,
                                                                  "signed": "\(ins.signed)", "trusted": "\(ins.trusted)", "sha256": ins.manifest.payloadSHA256])
        return bundle
    }

    static func extract(_ url: URL, ins: Inspection, into dir: URL, progress: ((Double) -> Void)?) throws {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        try fh.seek(toOffset: ins.payloadStart)
        var hasher = SHA256()
        var consumed: UInt64 = 0
        func read(_ n: Int) throws -> Data {
            guard let d = try fh.read(upToCount: n), d.count == n else { throw AltVMError.io("image truncated") }
            hasher.update(data: d)
            consumed += UInt64(n)
            return d
        }
        var out = [UInt8](repeating: 0, count: chunk + 4096)
        for entry in ins.manifest.files {
            guard !entry.path.contains("/"), entry.path != ".." else { throw AltVMError.invalid("unsafe path in image: \(entry.path)") }
            let path = dir.appendingPathComponent(entry.path).path
            let fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
            guard fd >= 0 else { throw AltVMError.io("create \(path)") }
            defer { close(fd) }
            ftruncate(fd, off_t(entry.size))
            while true {
                let off = try read(8).beUInt64
                if off == UInt64.max { break }
                let clen = Int(try read(4).beUInt32), rlen = Int(try read(4).beUInt32)
                guard rlen <= chunk, off + UInt64(rlen) <= entry.size else { throw AltVMError.invalid("corrupt record") }
                let comp = try read(clen)
                if clen == rlen {
                    _ = comp.withUnsafeBytes { pwrite(fd, $0.baseAddress, rlen, off_t(off)) }
                } else {
                    let n = comp.withUnsafeBytes { compression_decode_buffer(&out, out.count, $0.bindMemory(to: UInt8.self).baseAddress!, clen, nil, COMPRESSION_LZFSE) }
                    guard n == rlen else { throw AltVMError.io("decompression failed") }
                    pwrite(fd, out, rlen, off_t(off))
                }
                progress?(Double(consumed) / Double(max(1, ins.manifest.payloadBytes)))
            }
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == ins.manifest.payloadSHA256, consumed == ins.manifest.payloadBytes else {
            throw AltVMError.policy("image payload hash mismatch — refusing to deploy a tampered image")
        }
    }
}

extension Data {
    mutating func append(be v: UInt64) { var x = v.bigEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
    mutating func append(be v: UInt32) { var x = v.bigEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
    var beUInt64: UInt64 { reduce(0) { $0 << 8 | UInt64($1) } }
    var beUInt32: UInt32 { reduce(0) { $0 << 8 | UInt32($1) } }
}
