import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Built-in autonomous computer-use agent: Claude operates a VM (any guest OS) through screenshots,
/// mouse and keyboard, plus a shell for Linux guests, until the task is done.
///
/// Raw HTTP to the Messages API (Swift has no official Anthropic SDK). Contract implemented:
/// `computer_toolset_20260801` (no beta header; member tool_use blocks carry
/// `toolset_name: "computer"`, every result echoes it), Anthropic-defined `bash_20250124`,
/// adaptive thinking, refusal handling and server-side fallbacks.
public final class AgentRunner {
    public struct Config {
        public var vm: String
        public var task: String
        public var model = "claude-opus-5-5"
        public var effort = "high"
        public var maxSteps = 60
        public var maxDimension = 1280          // recommended desktop screenshot size for computer use
        public var snapshotFirst = true
        public var fallbacks = true
        public var baseURL = ProcessInfo.processInfo.environment["ANTHROPIC_BASE_URL"] ?? "https://api.anthropic.com"
        public init(vm: String, task: String) { self.vm = vm; self.task = task }
    }

    public enum Outcome: Equatable { case done(String), refused(String), stepLimit, error(String) }

    let config: Config
    let log: (String) -> Void
    private var cursor = (x: 0, y: 0)          // last pointer position, screenshot coordinates
    private var screenSize = (w: 0, h: 0)       // last full screenshot size
    public private(set) var inputTokens = 0
    public private(set) var outputTokens = 0

    public init(config: Config, log: @escaping (String) -> Void) {
        self.config = config
        self.log = log
    }

    // MARK: credentials

    static func authHeaders() throws -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        if let k = env["ANTHROPIC_API_KEY"], !k.isEmpty { return ["x-api-key": k] }
        if let t = env["ANTHROPIC_AUTH_TOKEN"], !t.isEmpty { return ["authorization": "Bearer \(t)"] }
        throw AltVMError.message("set ANTHROPIC_API_KEY (or ANTHROPIC_AUTH_TOKEN) to use `avm agent`")
    }

    // MARK: run

    public func run() throws -> Outcome {
        let auth = try Self.authHeaders()
        let bundle = try VMLibrary.find(config.vm)
        let spec = try bundle.loadSpec()
        if !bundle.isRunning { log("starting \(config.vm)"); try Manager.start(config.vm) }
        let linuxShell = spec.os == .linux && spec.integration.guestAgent && (try? Manager.waitForAgent(config.vm, timeout: 60, op: "ping")) != nil

        if config.snapshotFirst {
            let s = try Manager.snapshot(config.vm, label: "before-agent-\(Int(Date().timeIntervalSince1970))", note: config.task)
            log("rollback point: snapshot \(s["name"] ?? "") — undo everything with `avm snapshot restore \(config.vm) \(s["id"] ?? "")`")
        }
        AuditLog.shared.record("agent.start", vm: config.vm, details: ["model": config.model, "task": String(config.task.prefix(200))])

        var tools: [[String: Any]] = [["type": "computer_toolset_20260801"]]
        if linuxShell { tools.append(["type": "bash_20250124", "name": "bash"]) }
        let system = """
        You are operating a \(spec.os.displayName) virtual machine named "\(config.vm)" running inside AltVM on the user's Mac. \
        You see it through screenshots and control it with the mouse and keyboard\(linuxShell ? "; for command-line work, prefer the bash tool, which runs as root inside the guest" : ""). \
        The machine is a sandbox and a snapshot was taken before you started, so it can be rolled back. \
        On macOS guests the Command key is "super" (e.g. "super+space" opens Spotlight). \
        Take a screenshot whenever you need to see the current state. When the task is complete, reply with a short summary of what you did and what you verified.
        """
        var messages: [[String: Any]] = [["role": "user", "content": config.task]]

        for step in 1...config.maxSteps {
            var body: [String: Any] = [
                "model": config.model,
                "max_tokens": 16000,
                "system": system,
                "tools": tools,
                "messages": messages,
                "thinking": ["type": "adaptive", "display": "summarized"],
                "output_config": ["effort": config.effort],
            ]
            if config.fallbacks { body["fallbacks"] = "default" }
            let resp = try post(body, auth: auth)
            if let usage = resp["usage"] as? [String: Any] {
                inputTokens += (usage["input_tokens"] as? Int ?? 0) + (usage["cache_read_input_tokens"] as? Int ?? 0) + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                outputTokens += usage["output_tokens"] as? Int ?? 0
            }
            let content = resp["content"] as? [[String: Any]] ?? []
            // Append the assistant turn exactly as received (thinking blocks included).
            messages.append(["role": "assistant", "content": content])
            for block in content {
                switch block["type"] as? String {
                case "text": if let t = block["text"] as? String, !t.isEmpty { log("claude: \(t)") }
                case "thinking": if let t = block["thinking"] as? String, !t.isEmpty { log("thinking: \(t.prefix(300))") }
                default: break
                }
            }
            let stop = resp["stop_reason"] as? String ?? ""
            switch stop {
            case "refusal":
                let d = resp["stop_details"] as? [String: Any]
                let why = "\(d?["category"] ?? "unspecified"): \(d?["explanation"] ?? "")"
                AuditLog.shared.record("agent.refused", vm: config.vm, details: ["why": why])
                return .refused(why)
            case "pause_turn":
                continue
            case "tool_use":
                break
            default: // end_turn, stop_sequence, max_tokens
                let final = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
                AuditLog.shared.record("agent.done", vm: config.vm, details: ["steps": "\(step)", "in": "\(inputTokens)", "out": "\(outputTokens)"])
                return .done(final)
            }
            // Execute every tool call of this turn in order; one result per call, all in one user message.
            var results: [[String: Any]] = []
            var halted = false
            for call in content where call["type"] as? String == "tool_use" {
                let id = call["id"] as? String ?? ""
                let name = call["name"] as? String ?? ""
                let toolset = call["toolset_name"] as? String
                let input = call["input"] as? [String: Any] ?? [:]
                var result: [String: Any] = ["type": "tool_result", "tool_use_id": id]
                if let toolset { result["toolset_name"] = toolset }
                if halted {
                    result["content"] = "Not executed: an earlier computer action in this turn failed."
                    result["is_error"] = true
                    results.append(result)
                    continue
                }
                do {
                    let out: [[String: Any]]
                    if toolset == "computer" {
                        log("→ \(name) \(Self.brief(input))")
                        out = try computer(name, input)
                    } else if name == "bash" {
                        log("→ bash: \(input["command"] as? String ?? "")")
                        out = try bash(input)
                    } else {
                        throw AltVMError.invalid("unknown tool \(name)")
                    }
                    result["content"] = out
                } catch {
                    result["content"] = "Error: \(error.localizedDescription)"
                    result["is_error"] = true
                    if toolset == "computer" { halted = true }
                    log("  ! \(error.localizedDescription)")
                }
                results.append(result)
            }
            messages.append(["role": "user", "content": results])
        }
        AuditLog.shared.record("agent.step-limit", vm: config.vm)
        return .stepLimit
    }

    // MARK: HTTP

    func post(_ body: [String: Any], auth: [String: String]) throws -> [String: Any] {
        var req = URLRequest(url: URL(string: config.baseURL + "/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        if config.fallbacks { req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
        for (k, v) in auth { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        var attempt = 0
        while true {
            attempt += 1
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var data: Data?
            nonisolated(unsafe) var response: URLResponse?
            nonisolated(unsafe) var err: Error?
            URLSession.shared.dataTask(with: req) { d, r, e in data = d; response = r; err = e; sem.signal() }.resume()
            sem.wait()
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Retry what the API marks retryable: 429, 5xx (incl. 529 overloaded), and network errors.
            let retryable = err != nil || status == 429 || status >= 500
            if retryable && attempt < 5 {
                let after = Double((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after") ?? "") ?? pow(2, Double(attempt))
                log("  (API \(status == 0 ? "network error" : "HTTP \(status)"), retrying in \(Int(after))s)")
                Thread.sleep(forTimeInterval: min(after, 30))
                continue
            }
            if let err { throw AltVMError.io("Claude API: \(err.localizedDescription)") }
            guard let data, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw AltVMError.io("Claude API: HTTP \(status), unreadable response")
            }
            guard status == 200 else {
                let e = json["error"] as? [String: Any]
                throw AltVMError.message("Claude API error \(status): \(e?["type"] ?? "") — \(e?["message"] ?? "")")
            }
            return json
        }
    }

    // MARK: tools

    static func brief(_ input: [String: Any]) -> String {
        input.map { k, v in "\(k)=\(String(describing: v).replacingOccurrences(of: "\n", with: " ").prefix(60))" }.sorted().joined(separator: " ")
    }

    func control(_ req: [String: Any]) throws -> [String: Any] {
        try Manager.control(config.vm, "computer", extra: req, timeout: 120) as? [String: Any] ?? [:]
    }

    func xy(_ input: [String: Any], _ key: String = "coordinate") -> (Int, Int)? {
        guard let c = input[key] as? [Any], c.count == 2 else { return nil }
        func n(_ v: Any) -> Int { (v as? Int) ?? Int((v as? Double) ?? 0) }
        return (n(c[0]), n(c[1]))
    }

    static func image(_ b64: String) -> [[String: Any]] {
        [["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": b64]]]
    }
    static let ok: [[String: Any]] = [["type": "text", "text": "OK"]]

    /// Runs `body` with modifier keys (from the member's `text`) held down.
    func withModifiers(_ input: [String: Any], _ body: () throws -> Void) throws {
        let mods = (input["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let mods { _ = try control(["action": "keys_down", "keys": mods]) }
        defer { if let mods { _ = try? control(["action": "keys_up", "keys": mods]) } }
        try body()
    }

    func computer(_ member: String, _ input: [String: Any]) throws -> [[String: Any]] {
        func at(_ p: (Int, Int)?) -> (Int, Int) {
            if let p { cursor = (p.0, p.1) }
            return (cursor.x, cursor.y)
        }
        switch member {
        case "screenshot":
            let r = try control(["action": "screenshot", "maxDimension": config.maxDimension])
            screenSize = (r["width"] as? Int ?? 0, r["height"] as? Int ?? 0)
            return Self.image(r["png"] as? String ?? "")
        case "zoom":
            guard let reg = input["region"] as? [Any], reg.count == 4 else { throw AltVMError.invalid("zoom needs region [x0,y0,x1,y1]") }
            func n(_ v: Any) -> Double { (v as? Double) ?? Double((v as? Int) ?? 0) }
            // Crop from a native-resolution capture (without changing the coordinate space Claude uses).
            let full = try control(["action": "screenshot", "keepScale": true])
            guard let b64 = full["png"] as? String, let data = Data(base64Encoded: b64),
                  let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                throw AltVMError.io("zoom capture failed")
            }
            let k = screenSize.w > 0 ? Double(img.width) / Double(screenSize.w) : 1
            let rect = CGRect(x: n(reg[0]) * k, y: n(reg[1]) * k, width: max(1, (n(reg[2]) - n(reg[0])) * k), height: max(1, (n(reg[3]) - n(reg[1])) * k))
                .intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
            guard let crop = img.cropping(to: rect) else { throw AltVMError.invalid("zoom region outside the screen") }
            return Self.image(try Self.pngFitting(crop, maxDimension: config.maxDimension).base64EncodedString())
        case "left_click", "right_click", "middle_click", "double_click", "triple_click":
            let (x, y) = at(xy(input))
            let action = member == "right_click" ? "right_click" : member == "middle_click" ? "middle_click" : member == "double_click" ? "double_click" : "click"
            try withModifiers(input) {
                _ = try control(["action": action, "x": x, "y": y, "scaled": true, "count": member == "triple_click" ? 3 : 1])
            }
            return Self.ok
        case "left_click_drag":
            guard let from = xy(input, "start_coordinate"), let to = xy(input) else { throw AltVMError.invalid("drag needs start_coordinate and coordinate") }
            try withModifiers(input) {
                _ = try control(["action": "drag", "x": from.0, "y": from.1, "x2": to.0, "y2": to.1, "scaled": true])
            }
            cursor = (to.0, to.1)
            return Self.ok
        case "mouse_move":
            let (x, y) = at(xy(input))
            _ = try control(["action": "move", "x": x, "y": y, "scaled": true])
            return Self.ok
        case "left_mouse_down", "left_mouse_up":
            _ = try control(["action": member == "left_mouse_down" ? "button_down" : "button_up", "x": cursor.x, "y": cursor.y, "scaled": true])
            return Self.ok
        case "cursor_position":
            return [["type": "text", "text": "X=\(cursor.x), Y=\(cursor.y)"]]
        case "scroll":
            let (x, y) = at(xy(input))
            let amount = (input["scroll_amount"] as? Int) ?? Int((input["scroll_amount"] as? Double) ?? 3)
            let dir = input["scroll_direction"] as? String ?? "down"
            try withModifiers(input) {
                _ = try control(["action": "scroll", "x": x, "y": y, "scaled": true,
                                 "dy": dir == "down" ? amount : dir == "up" ? -amount : 0,
                                 "dx": dir == "right" ? amount : dir == "left" ? -amount : 0])
            }
            return Self.ok
        case "type":
            _ = try control(["action": "type", "text": input["text"] as? String ?? ""])
            return Self.ok
        case "key":
            let repeatCount = max(1, min(100, (input["repeat"] as? Int) ?? 1))
            for _ in 0..<repeatCount { _ = try control(["action": "key", "keys": input["text"] as? String ?? ""]) }
            return Self.ok
        case "hold_key":
            let keys = input["text"] as? String ?? ""
            let secs = min(300, (input["duration"] as? Double) ?? Double((input["duration"] as? Int) ?? 1))
            _ = try control(["action": "keys_down", "keys": keys])
            Thread.sleep(forTimeInterval: secs)
            _ = try control(["action": "keys_up", "keys": keys])
            return Self.ok
        case "wait":
            Thread.sleep(forTimeInterval: min(300, (input["duration"] as? Double) ?? Double((input["duration"] as? Int) ?? 1)))
            return Self.ok
        default:
            throw AltVMError.invalid("unsupported computer action '\(member)'")
        }
    }

    func bash(_ input: [String: Any]) throws -> [[String: Any]] {
        if input["restart"] as? Bool == true { return [["type": "text", "text": "shell restarted (each command runs in a fresh shell)"]] }
        let cmd = input["command"] as? String ?? ""
        let (code, out, err) = try Manager.exec(config.vm, command: ["/bin/bash", "-lc", cmd], timeout: 600)
        var text = out
        if !err.isEmpty { text += (text.isEmpty ? "" : "\n") + err }
        if code != 0 { text += "\n(exit code \(code))" }
        // Keep tool results bounded; the full output stays available in the guest.
        if text.count > 30_000 { text = String(text.prefix(15_000)) + "\n…[truncated \(text.count - 30_000) chars]…\n" + String(text.suffix(15_000)) }
        return [["type": "text", "text": text.isEmpty ? "(no output)" : text]]
    }

    static func pngFitting(_ image: CGImage, maxDimension: Int) throws -> Data {
        var img = image
        let longest = max(image.width, image.height)
        if longest > maxDimension {
            let s = Double(maxDimension) / Double(longest)
            let w = Int(Double(image.width) * s), h = Int(Double(image.height) * s)
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                if let scaled = ctx.makeImage() { img = scaled }
            }
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { throw AltVMError.io("png") }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
