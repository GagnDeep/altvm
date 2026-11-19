import Foundation
import CryptoKit

/// One-click guest OS catalog. Cloud images boot fully provisioned in seconds (cloud-init: your
/// user, your SSH key, guest agent, shared folders, Rosetta); ISOs give the classic installer.
public struct CatalogEntry: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case cloudImage, iso, macOS, manual }
    public var id: String
    public var title: String
    public var os: GuestOS
    public var kind: Kind
    public var url: String?
    /// Checksum list URL + filename pattern to resolve versioned files and verify downloads.
    public var checksumURL: String?
    public var checksumPattern: String?
    public var notes: String = ""
}

public enum Catalog {
    public static let entries: [CatalogEntry] = [
        CatalogEntry(id: "debian-13", title: "Debian 13 \"Trixie\" (cloud, unattended)", os: .linux, kind: .cloudImage,
                     url: "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.raw",
                     checksumURL: "https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS",
                     checksumPattern: "debian-13-genericcloud-arm64.raw"),
        CatalogEntry(id: "debian-12", title: "Debian 12 \"Bookworm\" (cloud, unattended)", os: .linux, kind: .cloudImage,
                     url: "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.raw",
                     checksumURL: "https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS",
                     checksumPattern: "debian-12-genericcloud-arm64.raw"),
        CatalogEntry(id: "ubuntu-24.04", title: "Ubuntu 24.04 LTS Server (cloud, unattended)", os: .linux, kind: .cloudImage,
                     url: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img",
                     checksumURL: "https://cloud-images.ubuntu.com/releases/24.04/release/SHA256SUMS",
                     checksumPattern: "ubuntu-24.04-server-cloudimg-arm64.img"),
        CatalogEntry(id: "ubuntu-24.04-desktop", title: "Ubuntu 24.04 LTS Desktop (installer ISO)", os: .linux, kind: .iso,
                     url: "https://cdimage.ubuntu.com/releases/24.04/release/",
                     checksumURL: "https://cdimage.ubuntu.com/releases/24.04/release/SHA256SUMS",
                     checksumPattern: "desktop-arm64.iso"),
        CatalogEntry(id: "debian-13-installer", title: "Debian 13 netinst (installer ISO)", os: .linux, kind: .iso,
                     url: "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/",
                     checksumURL: "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/SHA512SUMS",
                     checksumPattern: "netinst.iso"),
        CatalogEntry(id: "macos", title: "macOS (latest supported by this Mac)", os: .macOS, kind: .macOS,
                     notes: "Downloads the IPSW from Apple and installs automatically."),
    ]

    public static func find(_ id: String) throws -> CatalogEntry {
        guard let e = entries.first(where: { $0.id == id }) else {
            throw AltVMError.notFound("catalog entry '\(id)' (try: \(entries.map(\.id).joined(separator: ", ")))")
        }
        return e
    }

    /// Resolves the concrete file URL and expected checksum (hex, sha256 or sha512 by length).
    public static func resolve(_ e: CatalogEntry) async throws -> (url: URL, checksum: String?) {
        var checksum: String? = nil
        var fileName: String? = nil
        if let cu = e.checksumURL, let pattern = e.checksumPattern, let u = URL(string: cu) {
            if let (data, resp) = try? await URLSession.shared.data(from: u), (resp as? HTTPURLResponse)?.statusCode == 200,
               let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                    guard parts.count >= 2 else { continue }
                    let name = parts.last!.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
                    if name.hasSuffix(pattern) || name.contains(pattern) {
                        checksum = String(parts[0]).lowercased()
                        fileName = name
                        break
                    }
                }
            }
        }
        guard let base = e.url else { throw AltVMError.unsupported("\(e.id) has no download URL") }
        if base.hasSuffix("/") {
            guard let f = fileName else { throw AltVMError.io("could not resolve current file for \(e.id)") }
            return (URL(string: base + f)!, checksum)
        }
        return (URL(string: base)!, checksum)
    }

    /// Download into the shared cache (reused by every VM: creating the 2nd Debian VM is instant).
    public static func fetch(_ e: CatalogEntry, progress: @escaping @Sendable (Double, Int64) -> Void) async throws -> URL {
        try Paths.ensure()
        let (url, checksum) = try await resolve(e)
        let dest = Paths.cache.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            if let checksum, try verifyChecksum(dest, checksum) == false {
                try FileManager.default.removeItem(at: dest)
            } else {
                return dest
            }
        }
        try await Downloader.download(url, to: dest, progress: progress)
        if let checksum {
            guard try verifyChecksum(dest, checksum) else {
                try? FileManager.default.removeItem(at: dest)
                throw AltVMError.io("checksum mismatch for \(url.lastPathComponent) — download discarded")
            }
        }
        AuditLog.shared.record("catalog.download", vm: nil, details: ["id": e.id, "file": url.lastPathComponent, "verified": "\(checksum != nil)"])
        return dest
    }

    public static func verifyChecksum(_ file: URL, _ expected: String) throws -> Bool {
        let fh = try FileHandle(forReadingFrom: file)
        defer { try? fh.close() }
        if expected.count == 128 {
            var h = SHA512()
            while let d = try fh.read(upToCount: 8 << 20), !d.isEmpty { h.update(data: d) }
            return h.finalize().map { String(format: "%02x", $0) }.joined() == expected
        } else {
            var h = SHA256()
            while let d = try fh.read(upToCount: 8 << 20), !d.isEmpty { h.update(data: d) }
            return h.finalize().map { String(format: "%02x", $0) }.joined() == expected
        }
    }
}

/// URLSession downloader with progress and atomic finalisation.
public final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private let progress: @Sendable (Double, Int64) -> Void
    private let dest: URL

    init(dest: URL, progress: @escaping @Sendable (Double, Int64) -> Void) {
        self.dest = dest
        self.progress = progress
    }

    public static func download(_ url: URL, to dest: URL, progress: @escaping @Sendable (Double, Int64) -> Void) async throws {
        let d = Downloader(dest: dest, progress: progress)
        let session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        _ = try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            d.continuation = c
            session.downloadTask(with: url).resume()
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let p = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        progress(p, totalBytesWritten)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation?.resume(throwing: AltVMError.io("HTTP \(http.statusCode) for \(downloadTask.originalRequest?.url?.absoluteString ?? "")"))
            continuation = nil
            return
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            continuation?.resume(returning: dest)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
