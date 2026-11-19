import Foundation
import Virtualization

/// Host side of the guest agent protocol: newline-delimited JSON over virtio-vsock port 7700.
/// No network needed (works in isolated VMs), no SSH keys, no IP discovery games.
///
/// Requests:  {"id":1,"op":"ping"|"info"|"exec"|"shutdown"|"reboot"|"fstrim"|"growfs"|"timesync"|"write_file", ...}
/// Responses: {"id":1,"ok":true,"result":{...}} or {"id":1,"ok":false,"error":"..."}
public enum GuestAgentProtocol {
    public static let port: UInt32 = 7700
}

@MainActor
public final class GuestAgentClient {
    private weak var device: VZVirtioSocketDevice?
    private var nextID = 1

    public init(device: VZVirtioSocketDevice) { self.device = device }

    /// Opens a fresh connection per request (simple and robust across guest agent restarts).
    public func call(_ op: String, params: [String: Any] = [:], timeout: Int = 30) async throws -> [String: Any] {
        guard let device else { throw AltVMError.unsupported("VM has no vsock device") }
        let conn: VZVirtioSocketConnection = try await withCheckedThrowingContinuation { cont in
            device.connect(toPort: GuestAgentProtocol.port) { result in
                switch result {
                case .success(let c): cont.resume(returning: c)
                case .failure(let e): cont.resume(throwing: AltVMError.io("guest agent not reachable (\(e.localizedDescription)) — is altvm-agent running in the guest?"))
                }
            }
        }
        let id = nextID
        nextID += 1
        var req = params
        req["id"] = id
        req["op"] = op
        let fd = dup(conn.fileDescriptor)
        let body = try JSONSerialization.data(withJSONObject: req)
        let result: [String: Any] = try await Task.detached {
            let ch = LineChannel(fd: fd)
            ch.setTimeout(seconds: timeout)
            try ch.send(body)
            guard let resp = try ch.readJSON() else { throw AltVMError.io("guest agent closed connection") }
            return resp
        }.value
        conn.close()
        if result["ok"] as? Bool == true { return result["result"] as? [String: Any] ?? [:] }
        throw AltVMError.io("guest: \(result["error"] as? String ?? "unknown error")")
    }
}
