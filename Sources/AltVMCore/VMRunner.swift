import Foundation
import Virtualization

/// Owns one running VM: boot / resume, lifecycle, live snapshots, suspend-to-disk, the guest agent
/// and a control socket so CLI, REST API, web portal and GUI all drive the same running instance.
@MainActor
public final class VMRunner: NSObject, VZVirtualMachineDelegate {
    public enum RunState: String, Sendable { case stopped, starting, running, paused, saving, stopping, error }

    public let bundle: VMBundle
    public private(set) var spec: VMSpec
    public private(set) var vm: VZVirtualMachine?
    public private(set) var state: RunState = .stopped { didSet { onStateChange?(state) } }
    public private(set) var warnings: [String] = []
    public private(set) var startedAt: Date?
    public var onStateChange: ((RunState) -> Void)?
    /// Called once the VM has fully stopped (guest shutdown, stop, suspend, error).
    public var onExit: ((Int32) -> Void)?

    /// Cold boot instead of failing when a suspended session cannot be restored.
    public var discardSavedStateOnFailure = false

    public struct Options {
        public var gui = false
        public var consoleToStdio = false
        public var recovery = false
        /// Path of the `avm` binary used to spawn helper daemons (virtual switches).
        public var helperExecutable: String?
        public init() {}
    }
    private let options: Options
    private var controlFD: Int32 = -1
    private var controlSource: DispatchSourceRead?
    private var switchFDs: [Int32] = []
    private var agent: GuestAgentClient?
    private var hotplugged: [String: VZUSBMassStorageDevice] = [:]
    private var config: VZVirtualMachineConfiguration?
    private var lockFD: Int32 = -1
    private var pressureSource: DispatchSourceMemoryPressure?
    private var vncServer: VNCServerHost?
    private var rfb: RFBClient?
    /// Scale of the last screenshot handed to an agent (so it can click in screenshot coordinates).
    private var lastScreenshotScale = 1.0

    private func validateSaveRestore() throws {
        guard let config else { throw AltVMError.notRunning(spec.name) }
        try config.validateSaveRestoreSupport()
    }

    public init(bundle: VMBundle, options: Options = Options()) throws {
        self.bundle = bundle
        self.spec = try bundle.loadSpec()
        self.options = options
    }

    // MARK: lifecycle

    public func start() async throws {
        if let pid = bundle.runningPID, pid != getpid() { throw AltVMError.running("\(spec.name) (pid \(pid))") }
        // Kernel-enforced exclusivity: two processes must never drive the same disks.
        lockFD = open(bundle.url.appendingPathComponent("run.lock").path, O_RDWR | O_CREAT, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD); lockFD = -1 }
            throw AltVMError.running("\(spec.name) is already running in another process")
        }
        state = .starting
        do {
            try preflight()
            let config = try buildConfiguration()
            self.config = config
            let machine = VZVirtualMachine(configuration: config)
            machine.delegate = self
            vm = machine
            if let sock = machine.socketDevices.first as? VZVirtioSocketDevice { agent = GuestAgentClient(device: sock) }

            try "\(getpid())".write(to: bundle.pidURL, atomically: true, encoding: .utf8)
            try startControlServer()

            if bundle.hasSavedState, (try? config.validateSaveRestoreSupport()) != nil {
                do {
                    try await machine.restoreMachineStateFrom(url: bundle.savedStateURL)
                    try await machine.resume()
                    try? FileManager.default.removeItem(at: bundle.savedStateURL)
                    AuditLog.shared.record("vm.resume-from-disk", vm: spec.name)
                    Task { @MainActor in await self.resyncGuestClock() }
                } catch {
                    let msg = error.localizedDescription
                    // Saved states are sealed with a Secure Enclave key usable only while the Mac is
                    // unlocked. Never throw the session away for that: keep it and tell the user.
                    if msg.contains("permission denied") && !discardSavedStateOnFailure {
                        throw AltVMError.message("the suspended session is protected by this Mac's Secure Enclave and can only be resumed while the Mac is unlocked — unlock and retry (or `avm start \(spec.name) --discard-state` to cold boot)")
                    }
                    // Genuinely incompatible state (e.g. host OS update): set it aside, never delete,
                    // and cold boot on a fresh machine object (no half-restored device state).
                    let kept = bundle.url.appendingPathComponent("state-unrestorable-\(Int(Date().timeIntervalSince1970)).vzvmsave")
                    try? FileManager.default.moveItem(at: bundle.savedStateURL, to: kept)
                    warnings.append("saved state could not be restored (\(msg)); kept as \(kept.lastPathComponent); cold booting")
                    AuditLog.shared.record("vm.restore-failed", vm: spec.name, details: ["error": msg])
                    let fresh = VZVirtualMachine(configuration: config)
                    fresh.delegate = self
                    vm = fresh
                    if let sock = fresh.socketDevices.first as? VZVirtioSocketDevice { agent = GuestAgentClient(device: sock) }
                    try await coldBoot(fresh)
                }
            } else {
                try await coldBoot(machine)
            }
            startedAt = Date()
            state = .running
            startMemoryPressureWatch()
            if spec.labels["repairOnNextBoot"] != nil, var s = try? bundle.loadSpec() {
                s.labels["repairOnNextBoot"] = nil
                try? bundle.saveSpec(s)
                AuditLog.shared.record("vm.repair-boot", vm: spec.name)
            }
            if spec.os == .linux, spec.fastBoot == true, agent != nil {
                Task { @MainActor in await self.syncKernel() }
            }
            AuditLog.shared.record("vm.start", vm: spec.name, details: ["cpus": "\(config.cpuCount)", "memoryMiB": "\(config.memorySize >> 20)", "pid": "\(getpid())"])
        } catch {
            state = .error
            cleanup()
            throw error
        }
    }

    private func coldBoot(_ machine: VZVirtualMachine) async throws {
        #if arch(arm64)
        if spec.os == .macOS {
            let opts = VZMacOSVirtualMachineStartOptions()
            opts.startUpFromMacOSRecovery = options.recovery
            var provisioned = false
            if #available(macOS 27.0, *), let p = spec.provisioning, let pw = p.password {
                let po = VZMacGuestProvisioningOptions()
                po.fullName = p.fullName
                po.username = p.username
                po.password = pw
                po.logsInAutomatically = p.autoLogin
                po.enablesRemoteLogin = p.enableSSH
                try opts.setGuestProvisioning(po)
                provisioned = true
            }
            try await machine.start(options: opts)
            if provisioned {
                // Never keep the password at rest.
                spec.provisioning?.password = nil
                try? bundle.saveSpec(spec)
                AuditLog.shared.record("vm.provision", vm: spec.name, details: ["user": spec.provisioning?.username ?? ""])
            }
            return
        }
        #endif
        try await machine.start()
    }

    private func preflight() throws {
        let policy = Policy.loadActive()
        if let policy {
            let v = policy.violations(spec)
            if !v.isEmpty { throw AltVMError.policy(v.joined(separator: "; ")) }
        }
        if let org = spec.security.organization, policy?.organization != org {
            throw AltVMError.policy("VM is bound to organization '\(org)' but no matching signed policy is installed")
        }
        if let exp = spec.security.expires, exp < Date() { throw AltVMError.policy("VM expired on \(exp)") }
        if spec.security.disposable {
            let sm = SnapshotManager(bundle: bundle)
            if (try? sm.find("disposable-base")) == nil {
                try sm.create(name: "disposable-base", note: "baseline for disposable mode")
            }
        }
    }

    private func buildConfiguration() throws -> VZVirtualMachineConfiguration {
        var opts = ConfigBuilder.Options()
        opts.gui = options.gui
        opts.consoleToStdio = options.consoleToStdio
        for (i, nic) in spec.network.enumerated() where nic.mode == .switch {
            let name = nic.switchName ?? "default"
            try SwitchDaemon.ensureRunning(name, helper: options.helperExecutable)
            let local = Runtime.switchClientSocket(vm: spec.name, nic: i).path
            let fd = try UnixSocket.datagramPair(local: local, remote: Runtime.switchSocket(name).path)
            switchFDs.append(fd)
            opts.switchHandles[i] = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        }
        var builder = ConfigBuilder(spec: spec, bundle: bundle, options: opts)
        let config = try builder.build()
        warnings += builder.warnings
        return config
    }

    /// Graceful stop: ask the guest agent / ACPI first, then force after `timeout` seconds.
    public func stop(force: Bool = false, timeout: TimeInterval = 30) async throws {
        guard let vm else { throw AltVMError.notRunning(spec.name) }
        state = .stopping
        if !force {
            if let agent, (try? await agent.call("shutdown", timeout: 5)) != nil {
                // agent acknowledged
            } else if vm.canRequestStop {
                try? vm.requestStop()
            }
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline, self.vm != nil, vm.state != .stopped {
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            if self.vm == nil || vm.state == .stopped { return }
        }
        await flushGuest(timeout: 3) // a forced power-off still shouldn't lose recently written files
        if vm.canStop { try await vm.stop() }
        finish(code: 0, event: "vm.stop", details: ["force": "true"])
    }

    public func pause() async throws {
        guard let vm, vm.canPause else { throw AltVMError.invalid("cannot pause in state \(state.rawValue)") }
        try await vm.pause()
        state = .paused
        AuditLog.shared.record("vm.pause", vm: spec.name)
    }

    public func resume() async throws {
        guard let vm, vm.canResume else { throw AltVMError.invalid("cannot resume in state \(state.rawValue)") }
        try await vm.resume()
        state = .running
        AuditLog.shared.record("vm.resume", vm: spec.name)
    }

    /// Suspend to disk: full RAM + device state saved, VM process exits, next `start` resumes instantly.
    public func suspend() async throws {
        guard let vm else { throw AltVMError.notRunning(spec.name) }
        try validateSaveRestore()
        await flushGuest()
        if vm.state == .running { try await vm.pause() }
        state = .saving
        try? FileManager.default.removeItem(at: bundle.savedStateURL)
        try await vm.saveMachineStateTo(url: bundle.savedStateURL)
        if vm.canStop { try await vm.stop() }
        finish(code: 0, event: "vm.suspend")
    }

    /// Live snapshot: pause → save RAM state → CoW-clone disks (consistent, VM is paused) → resume.
    /// Typically well under a second of guest pause plus RAM write time.
    public func liveSnapshot(name: String, note: String = "") async throws -> SnapshotInfo {
        guard let vm else { throw AltVMError.notRunning(spec.name) }
        await flushGuest()
        let wasRunning = vm.state == .running
        if wasRunning { try await vm.pause() }
        defer {
            if wasRunning { Task { @MainActor in try? await self.vm?.resume(); self.state = .running } }
        }
        var stateFile: URL? = nil
        if (try? validateSaveRestore()) != nil {
            let tmp = bundle.url.appendingPathComponent("snap-\(UUID().uuidString).vzvmsave")
            try await vm.saveMachineStateTo(url: tmp)
            stateFile = tmp
        } else {
            warnings.append("live snapshot without RAM state (configuration does not support save/restore)")
        }
        return try SnapshotManager(bundle: bundle).create(name: name, note: note, machineState: stateFile)
    }

    /// Flush the guest's page cache to the virtual disk so the disk is self-consistent even if a
    /// saved RAM state is later lost (or the VM is powered off). Without this, files written in the
    /// last ~30 s live only in guest RAM and come back empty after a crash (ext4 delalloc).
    func flushGuest(timeout: Int = 15) async {
        guard let agent, vm?.state == .running else { return }
        _ = try? await agent.call("exec", params: ["args": ["sync"], "timeout": timeout], timeout: timeout + 2)
    }

    /// The guest's wall clock is frozen while its RAM state sits on disk; fix it after resume.
    func resyncGuestClock() async {
        for _ in 0..<20 {
            guard vm != nil else { return }
            if (try? await agent?.call("timesync", params: ["epoch": Int(Date().timeIntervalSince1970)], timeout: 3)) != nil { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: FastBoot kernel sync

    /// Copies the guest's newest kernel + initrd into the bundle so the next boot is a direct
    /// kernel boot. Re-runs on every boot; only transfers when the guest kernel version changed.
    func syncKernel() async {
        let probe = #"""
        set -e
        K=$(ls -1t /boot/vmlinuz-* 2>/dev/null | head -1)  # most recently installed kernel
        [ -n "$K" ] || { echo '{"error":"no kernel"}'; exit 0; }
        V=${K#/boot/vmlinuz-}
        I=/boot/initrd.img-$V
        [ -f "$I" ] || { echo '{"error":"no initrd"}'; exit 0; }
        M=$(od -An -tx1 -N2 "$K" | tr -d ' ')
        if [ "$M" = "1f8b" ]; then zcat "$K" > /var/tmp/altvm-Image; K=/var/tmp/altvm-Image; fi
        A=$(od -An -c -j 56 -N4 "$K" | tr -d ' ')
        R=$(tr ' ' '\n' < /proc/cmdline | grep -E '^(root|rootflags|rootfstype)=' | tr '\n' ' ')
        printf '{"version":"%s","kernel":"%s","initrd":"%s","arm64":"%s","root":"%s"}\n' "$V" "$K" "$I" "$A" "$R"
        """#
        // Wait for the agent (first boot runs cloud-init first).
        var info: [String: Any]?
        for _ in 0..<90 {
            guard vm != nil else { return }
            if (try? await agent?.call("ping", timeout: 3)) != nil {
                info = try? await agent?.call("exec", params: ["args": ["/bin/sh", "-c", probe], "timeout": 60], timeout: 70)
                break
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        guard let out = info?["stdout"] as? String,
              let meta = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: String],
              let version = meta["version"], let kpath = meta["kernel"], let ipath = meta["initrd"] else { return }
        guard meta["arm64"] == "ARMd" else {
            warnings.append("FastBoot: guest kernel is not a raw arm64 Image; staying on EFI boot")
            return
        }
        let current = (try? bundle.loadSpec())?.labels["fastBootKernel"]
        let kURL = bundle.url.appendingPathComponent("vmlinuz"), iURL = bundle.url.appendingPathComponent("initrd.img")
        if current == version, FileManager.default.fileExists(atPath: kURL.path), FileManager.default.fileExists(atPath: iURL.path) { return }
        do {
            for (src, dst) in [(kpath, kURL), (ipath, iURL)] {
                let r = try await agentCall("read_file", params: ["path": src], timeout: 120)
                guard let b64 = r["content"] as? String, let data = Data(base64Encoded: b64), data.count > 1024 else {
                    throw AltVMError.io("FastBoot: could not read \(src)")
                }
                try data.write(to: dst, options: .atomic)
            }
            var s = try bundle.loadSpec()
            s.kernel = "vmlinuz"
            s.initrd = "initrd.img"
            s.kernelCommandLine = "\((meta["root"] ?? "").trimmingCharacters(in: .whitespaces)) ro console=hvc0"
            s.labels["fastBootKernel"] = version
            try bundle.saveSpec(s)
            AuditLog.shared.record("vm.fastboot-sync", vm: spec.name, details: ["kernel": version])
        } catch {
            warnings.append(error.localizedDescription)
        }
    }

    // MARK: guest agent & devices

    public func agentCall(_ op: String, params: [String: Any] = [:], timeout: Int = 60) async throws -> [String: Any] {
        guard let agent else { throw AltVMError.unsupported("guest agent disabled for this VM") }
        return try await agent.call(op, params: params, timeout: timeout)
    }

    /// Hot-plug a disk image / ISO as a USB stick into the running VM.
    public func usbAttach(path: String, readOnly: Bool) async throws -> String {
        guard let vm, let usb = vm.usbControllers.first else { throw AltVMError.unsupported("no USB controller") }
        let att = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: path), readOnly: readOnly)
        let dev = VZUSBMassStorageDevice(configuration: VZUSBMassStorageDeviceConfiguration(attachment: att))
        try await usb.attach(device: dev)
        let id = UUID().uuidString.prefix(8).lowercased()
        hotplugged[String(id)] = dev
        AuditLog.shared.record("usb.attach", vm: spec.name, details: ["path": path, "id": String(id)])
        return String(id)
    }

    public func usbDetach(id: String) async throws {
        guard let vm, let usb = vm.usbControllers.first, let dev = hotplugged[id] else { throw AltVMError.notFound("USB device \(id)") }
        try await usb.detach(device: dev)
        hotplugged[id] = nil
        AuditLog.shared.record("usb.detach", vm: spec.name, details: ["id": id])
    }

    // MARK: dynamic memory (virtio balloon)

    /// Sets the guest's usable memory live (the guest returns the difference to the Mac).
    public func setMemoryTarget(mib: UInt64) throws -> UInt64 {
        guard let vm, let config else { throw AltVMError.notRunning(spec.name) }
        guard let balloon = vm.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice else {
            throw AltVMError.unsupported("VM has no memory balloon device")
        }
        let maxMiB = config.memorySize >> 20
        let target = min(maxMiB, max(512, mib))
        balloon.targetVirtualMachineMemorySize = target << 20
        AuditLog.shared.record("vm.memory-target", vm: spec.name, details: ["targetMiB": "\(target)"])
        return target
    }

    /// Host memory pressure → shrink guests (75% warning / 50% critical), restore when normal.
    private func startMemoryPressureWatch() {
        guard spec.adaptiveResources, config != nil else { return }
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let config = self.config else { return }
                let full = config.memorySize >> 20
                let ev = src.data
                let target = ev.contains(.critical) ? full / 2 : ev.contains(.warning) ? full * 3 / 4 : full
                _ = try? self.setMemoryTarget(mib: target)
                if target < full { self.warnings.append("host memory pressure: guest RAM reduced to \(target) MiB") }
            }
        }
        src.resume()
        pressureSource = src
    }

    // MARK: remote display & computer use

    /// Starts (once) the VM's remote display server and an RFB client attached to it.
    public func display() throws -> (VNCServerHost, RFBClient) {
        if let v = vncServer, let r = rfb, r.isAlive { return (v, r) }
        rfb = nil
        if Policy.loadActive()?.allowRemoteDisplay == false { throw AltVMError.policy("remote display / computer use is disabled by policy") }
        guard let vm else { throw AltVMError.notRunning(spec.name) }
        var lastError: Error = AltVMError.io("display unavailable")
        // If the existing server can't be reached, replace it (fresh port + password) and retry.
        for generation in 0..<2 {
            let fresh = vncServer == nil
            let server = try vncServer ?? VNCServerHost(vm: vm)
            vncServer = server
            if fresh { nudgeDisplay(vm) }
            for _ in 0..<(fresh ? 20 : 3) {
                do {
                    let client = try RFBClient(port: server.port, password: server.password)
                    rfb = client
                    AuditLog.shared.record("display.open", vm: spec.name, details: ["port": "\(server.port)", "generation": "\(generation)"])
                    return (server, client)
                } catch { lastError = error; usleep(100_000) }
            }
            server.stop()
            vncServer = nil
        }
        throw lastError
    }

    /// The display server only sees frames the guest draws after it started; a quick resize
    /// round-trip makes the guest repaint the whole screen.
    private func nudgeDisplay(_ vm: VZVirtualMachine) {
        guard let display = vm.graphicsDevices.first?.displays.first else { return }
        let size = display.sizeInPixels
        guard size.width > 64 else { return }
        try? display.reconfigure(sizeInPixels: CGSize(width: size.width - 8, height: size.height))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { try? display.reconfigure(sizeInPixels: size) }
        usleep(800_000)
    }

    /// Computer-use operation (screenshot / mouse / keyboard). Coordinates are display pixels, or
    /// coordinates in the last screenshot when `scaled` is true.
    public func computerUse(_ req: [String: Any]) async throws -> [String: Any] {
        do { return try await computerUseOnce(req) } catch {
            // One transparent reconnect if the display connection dropped.
            guard error.localizedDescription.contains("display") else { throw error }
            rfb = nil
            return try await computerUseOnce(req)
        }
    }

    private func computerUseOnce(_ req: [String: Any]) async throws -> [String: Any] {
        let (_, client) = try display()
        let action = req["action"] as? String ?? "screenshot"
        let scale = (req["scaled"] as? Bool ?? false) ? lastScreenshotScale : 1.0
        func px(_ k: String) -> Int { Int((Double(req[k] as? Int ?? Int((req[k] as? Double) ?? 0)) / scale).rounded()) }
        let (x, y, x2, y2) = (px("x"), px("y"), px("x2"), px("y2"))
        let maxDim = req["maxDimension"] as? Int
        nonisolated(unsafe) let req = req
        let result: [String: Any] = try await Task.detached { () -> [String: Any] in
            switch action {
            case "screenshot":
                let s = try client.screenshotPNG(maxDimension: maxDim)
                return ["png": s.png.base64EncodedString(), "width": s.width, "height": s.height,
                        "displayWidth": client.width, "displayHeight": client.height, "scale": s.scale]
            case "click", "double_click", "right_click", "middle_click":
                let button: RFBClient.Button = action == "right_click" ? .right : action == "middle_click" ? .middle : RFBClient.Button(rawValue: req["button"] as? String ?? "left") ?? .left
                try client.click(x: x, y: y, button: button, count: action == "double_click" ? 2 : (req["count"] as? Int ?? 1))
            case "move":
                try client.pointer(x: x, y: y, buttons: 0)
            case "drag":
                try client.drag(from: (x, y), to: (x2, y2))
            case "scroll":
                try client.scroll(x: x, y: y, dy: req["dy"] as? Int ?? 3, dx: req["dx"] as? Int ?? 0)
            case "key":
                try client.press(req["keys"] as? String ?? "")
            case "type":
                try client.type(req["text"] as? String ?? "")
            case "button_down":
                try client.pointer(x: x, y: y, buttons: 1)
            case "button_up":
                try client.pointer(x: x, y: y, buttons: 0)
            case "keys_down", "keys_up":
                // Hold or release a modifier chord (e.g. shift+ctrl) around other actions.
                let down = action == "keys_down"
                let keys = (req["keys"] as? String ?? "").split(separator: "+").map(String.init)
                for k in (down ? keys : keys.reversed()) {
                    guard let sym = Keysym.named(k) else { throw AltVMError.invalid("unknown key '\(k)'") }
                    try client.keyEvent(sym, down: down)
                }
            case "size":
                return ["displayWidth": client.width, "displayHeight": client.height]
            default:
                throw AltVMError.invalid("unknown computer-use action '\(action)'")
            }
            return ["ok": true]
        }.value
        if action == "screenshot", req["keepScale"] as? Bool != true, let s = result["scale"] as? Double { lastScreenshotScale = s }
        return result
    }

    public var status: [String: Any] {
        var s: [String: Any] = ["name": spec.name, "state": state.rawValue, "pid": Int(getpid())]
        if let config, vm != nil {
            s["cpus"] = config.cpuCount
            s["memoryMiB"] = Int(config.memorySize >> 20)
        }
        if let startedAt { s["uptimeSeconds"] = Int(Date().timeIntervalSince(startedAt)) }
        if !warnings.isEmpty { s["warnings"] = warnings }
        if !hotplugged.isEmpty { s["usb"] = Array(hotplugged.keys) }
        if let v = vncServer { s["display"] = ["port": Int(v.port)] }
        return s
    }

    // MARK: delegate

    nonisolated public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in self.finish(code: 0, event: "vm.guest-shutdown") }
    }

    nonisolated public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor in
            self.warnings.append(error.localizedDescription)
            self.finish(code: 1, event: "vm.crash", details: ["error": error.localizedDescription])
        }
    }

    nonisolated public func virtualMachine(_ virtualMachine: VZVirtualMachine, networkDevice: VZNetworkDevice, attachmentWasDisconnectedWithError error: Error) {
        Task { @MainActor in self.warnings.append("network disconnected: \(error.localizedDescription)") }
    }

    private var finished = false
    private func finish(code: Int32, event: String, details: [String: String] = [:]) {
        guard !finished else { return }
        finished = true
        state = .stopped
        AuditLog.shared.record(event, vm: spec.name, details: details)
        if spec.security.disposable, event != "vm.suspend" {
            // Throw away everything the session did.
            try? FileManager.default.removeItem(at: bundle.pidURL)
            try? SnapshotManager(bundle: bundle).restore("disposable-base")
        }
        cleanup()
        onExit?(code)
    }

    private func cleanup() {
        pressureSource?.cancel()
        pressureSource = nil
        rfb = nil
        vncServer?.stop()
        vncServer = nil
        controlSource?.cancel()
        controlSource = nil
        if controlFD >= 0 { close(controlFD); controlFD = -1 }
        unlink(bundle.controlSocketURL.path)
        for fd in switchFDs { close(fd) }
        for i in spec.network.indices { unlink(Runtime.switchClientSocket(vm: spec.name, nic: i).path) }
        switchFDs = []
        if let s = try? String(contentsOf: bundle.pidURL, encoding: .utf8), s.trimmingCharacters(in: .whitespacesAndNewlines) == "\(getpid())" {
            try? FileManager.default.removeItem(at: bundle.pidURL)
        }
        vm = nil
        agent = nil
        config = nil
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
    }

    // MARK: control socket

    private func startControlServer() throws {
        let fd = try UnixSocket.listen(path: bundle.controlSocketURL.path)
        controlFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        src.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            Thread.detachNewThread { self?.serveClient(client) }
        }
        src.resume()
        controlSource = src
    }

    nonisolated private func serveClient(_ fd: Int32) {
        let ch = LineChannel(fd: fd)
        while let req = try? ch.readJSON() {
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var response: [String: Any] = [:]
            nonisolated(unsafe) let request = req
            Task { @MainActor in
                response = await self.handle(request)
                sem.signal()
            }
            sem.wait()
            try? ch.sendJSON(response)
        }
    }

    private func handle(_ req: [String: Any]) async -> [String: Any] {
        let op = req["op"] as? String ?? ""
        do {
            let result: Any
            switch op {
            case "status": result = status
            case "stop":
                let force = req["force"] as? Bool ?? false
                Task { try? await self.stop(force: force) }
                result = ["accepted": true]
            case "pause": try await pause(); result = status
            case "resume": try await resume(); result = status
            case "suspend":
                Task { try? await self.suspend() }
                result = ["accepted": true]
            case "snapshot":
                let s = try await liveSnapshot(name: req["name"] as? String ?? "snapshot", note: req["note"] as? String ?? "")
                result = ["id": s.id, "name": s.name, "live": s.live]
            case "agent":
                result = try await agentCall(req["agentOp"] as? String ?? "ping", params: req["params"] as? [String: Any] ?? [:],
                                             timeout: req["timeout"] as? Int ?? 60)
            case "usb-attach":
                result = ["id": try await usbAttach(path: req["path"] as? String ?? "", readOnly: req["readOnly"] as? Bool ?? true)]
            case "computer":
                result = try await computerUse(req)
            case "memory":
                result = ["targetMiB": try setMemoryTarget(mib: UInt64(req["mib"] as? Int ?? 0))]
            case "vnc":
                let (server, _) = try display()
                result = ["url": server.url, "port": Int(server.port), "password": server.password]
            case "usb-detach":
                try await usbDetach(id: req["id"] as? String ?? ""); result = ["ok": true]
            default: throw AltVMError.invalid("unknown op '\(op)'")
            }
            return ["ok": true, "result": result]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }
}
