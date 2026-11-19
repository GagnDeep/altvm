import Foundation
import Virtualization

/// Creates per-OS platform identity files.
public enum PlatformFactory {
    public static func createEFIStore(bundle: VMBundle, secureBoot: Bool) throws {
        let store = try VZEFIVariableStore(creatingVariableStoreAt: bundle.efiVarsURL, options: [.allowOverwrite])
        if secureBoot { try enableSecureBoot(store) }
    }

    static func enableSecureBoot(_ store: VZEFIVariableStore) throws {
        if #available(macOS 27.0, *) {
            try store.enableSecureBootUsingDefaultPlatformKey()
            try store.enrollDefaultSecureBootSignatures()
        } else {
            throw AltVMError.unsupported("EFI Secure Boot requires a macOS 27 host")
        }
    }

    #if arch(arm64)
    /// Writes hardware model + auxiliary storage + machine identifier for a macOS guest.
    public static func createMacPlatform(bundle: VMBundle, requirements: VZMacOSConfigurationRequirements) throws {
        let model = requirements.hardwareModel
        guard model.isSupported else { throw AltVMError.unsupported("this macOS version cannot be virtualized on this host") }
        try model.dataRepresentation.write(to: bundle.hardwareModelURL)
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: bundle.auxStorageURL, hardwareModel: model, options: [.allowOverwrite])
        try VZMacMachineIdentifier().dataRepresentation.write(to: bundle.machineIdentifierURL)
    }
    #endif
}

/// Translates a declarative `VMSpec` into a `VZVirtualMachineConfiguration`.
public struct ConfigBuilder {
    public struct Options {
        public var gui: Bool = true
        /// Datagram socket fds for switch-mode NICs, in NIC order.
        public var switchHandles: [Int: FileHandle] = [:]
        /// Serial console sink. Defaults to bundle/console.log.
        public var consoleToStdio: Bool = false
        public init() {}
    }

    public let spec: VMSpec
    public let bundle: VMBundle
    public var options: Options
    public private(set) var warnings: [String] = []

    public init(spec: VMSpec, bundle: VMBundle, options: Options = Options()) {
        self.spec = spec
        self.bundle = bundle
        self.options = options
    }

    /// Resources after adaptive adjustments (battery / thermal) — never above the spec.
    public static func effectiveResources(_ spec: VMSpec, host: HostInfo = .current()) -> ProfileEngine.Resources {
        var cpus = spec.cpus
        var mem = spec.memoryMiB
        if spec.adaptiveResources {
            let eff = ProfileEngine.effectiveProfile(requested: spec.profile, host: host)
            if eff == .travel && spec.profile != .travel {
                let t = ProfileEngine.resources(for: .travel, os: spec.os, host: host)
                cpus = min(cpus, max(2, t.cpus))
                // Memory can't shrink below what the guest booted with safely; the balloon handles it at runtime.
            }
        }
        cpus = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount, min(cpus, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
        mem = max(VZVirtualMachineConfiguration.minimumAllowedMemorySize / (1 << 20), min(mem, VZVirtualMachineConfiguration.maximumAllowedMemorySize / (1 << 20)))
        return .init(cpus: cpus, memoryMiB: mem)
    }

    public mutating func build() throws -> VZVirtualMachineConfiguration {
        let c = VZVirtualMachineConfiguration()
        let res = Self.effectiveResources(spec)
        c.cpuCount = res.cpus
        c.memorySize = res.memoryMiB * 1024 * 1024
        let isolated = spec.security.isolated

        try configurePlatformAndBoot(c)
        try configureStorage(c)
        configureNetwork(c, isolated: isolated)
        configureGraphicsAndInput(c)
        configureAudio(c, isolated: isolated)
        try configureSharing(c, isolated: isolated)
        configureConsoleAndAgent(c, isolated: isolated)

        c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        c.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        if #available(macOS 27.0, *) { c.label = spec.name }

        try c.validate()
        return c
    }

    // MARK: platform

    private mutating func configurePlatformAndBoot(_ c: VZVirtualMachineConfiguration) throws {
        switch spec.os {
        case .macOS:
            #if arch(arm64)
            let p = VZMacPlatformConfiguration()
            guard let hwData = try? Data(contentsOf: bundle.hardwareModelURL),
                  let hw = VZMacHardwareModel(dataRepresentation: hwData) else {
                throw AltVMError.invalid("macOS VM has no hardware model — run `avm install \(spec.name)` first")
            }
            p.hardwareModel = hw
            p.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxStorageURL)
            if let idData = try? Data(contentsOf: bundle.machineIdentifierURL),
               let id = VZMacMachineIdentifier(dataRepresentation: idData) {
                p.machineIdentifier = id
            } else {
                let id = VZMacMachineIdentifier()
                try id.dataRepresentation.write(to: bundle.machineIdentifierURL)
                p.machineIdentifier = id
            }
            c.platform = p
            c.bootLoader = VZMacOSBootLoader()
            #else
            throw AltVMError.unsupported("macOS guests require Apple silicon")
            #endif
        case .linux, .windows, .other:
            let p = VZGenericPlatformConfiguration()
            if let idData = try? Data(contentsOf: bundle.machineIdentifierURL),
               let id = VZGenericMachineIdentifier(dataRepresentation: idData) {
                p.machineIdentifier = id
            } else {
                let id = VZGenericMachineIdentifier()
                try id.dataRepresentation.write(to: bundle.machineIdentifierURL)
                p.machineIdentifier = id
            }
            if #available(macOS 15.0, *), spec.os == .linux, VZGenericPlatformConfiguration.isNestedVirtualizationSupported {
                // Nested virtualization (KVM inside the Linux guest) on M3+ hosts.
                p.isNestedVirtualizationEnabled = spec.labels["nested"] == "true"
            }
            c.platform = p
            if let kernel = spec.kernel {
                func resolve(_ p: String) -> URL { p.hasPrefix("/") ? URL(fileURLWithPath: p) : bundle.url.appendingPathComponent(p) }
                let lb = VZLinuxBootLoader(kernelURL: resolve(kernel))
                if let initrd = spec.initrd { lb.initialRamdiskURL = resolve(initrd) }
                var cmdline = spec.kernelCommandLine ?? "console=hvc0 root=/dev/vda rw"
                if spec.labels["repairOnNextBoot"] == "true" { cmdline += " fsck.mode=force fsck.repair=yes" }
                lb.commandLine = cmdline
                c.bootLoader = lb
            } else {
                let boot = VZEFIBootLoader()
                if !FileManager.default.fileExists(atPath: bundle.efiVarsURL.path) {
                    try PlatformFactory.createEFIStore(bundle: bundle, secureBoot: spec.security.secureBoot)
                }
                boot.variableStore = VZEFIVariableStore(url: bundle.efiVarsURL)
                c.bootLoader = boot
            }
        }
    }

    // MARK: storage

    private mutating func configureStorage(_ c: VZVirtualMachineConfiguration) throws {
        var storage: [VZStorageDeviceConfiguration] = []
        for disk in spec.disks {
            let url = bundle.diskURL(disk)
            guard FileManager.default.fileExists(atPath: url.path) else { throw AltVMError.notFound("disk \(url.path)") }
            // `.full` (F_FULLFSYNC) makes every guest flush durable even across host power loss.
            // Disposable / CI VMs can opt into `.fsync` speed (`avm set vm disk.sync=fast`).
            let fast = spec.labels["disk.sync"] == "fast" || spec.security.disposable
            let att = try VZDiskImageStorageDeviceAttachment(
                url: url, readOnly: disk.readOnly,
                cachingMode: .automatic, synchronizationMode: fast ? .fsync : .full)
            if disk.nvme, spec.os != .macOS {
                storage.append(VZNVMExpressControllerDeviceConfiguration(attachment: att))
            } else {
                storage.append(VZVirtioBlockDeviceConfiguration(attachment: att))
            }
        }
        var usbDevices: [VZUSBDeviceConfiguration] = []
        if let media = spec.installMedia, spec.os != .macOS {
            let url = URL(fileURLWithPath: (media as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { throw AltVMError.notFound("install media \(url.path)") }
            let att = try VZDiskImageStorageDeviceAttachment(url: url, readOnly: true)
            usbDevices.append(VZUSBMassStorageDeviceConfiguration(attachment: att))
        }
        for m in spec.extraMedia ?? [] {
            let url = m.hasPrefix("/") ? URL(fileURLWithPath: m) : bundle.url.appendingPathComponent(m)
            guard FileManager.default.fileExists(atPath: url.path) else { throw AltVMError.notFound("media \(url.path)") }
            usbDevices.append(VZUSBMassStorageDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: url, readOnly: true)))
        }
        c.storageDevices = storage
        let xhci = VZXHCIControllerConfiguration()
        xhci.usbDevices = usbDevices
        c.usbControllers = [xhci]
    }

    // MARK: network

    private mutating func configureNetwork(_ c: VZVirtualMachineConfiguration, isolated: Bool) {
        var nics: [VZNetworkDeviceConfiguration] = []
        for (i, n) in spec.network.enumerated() {
            // Isolated mode only permits private virtual switches (lab networks), never host/Internet.
            if isolated && n.mode != .switch { continue }
            let dev = VZVirtioNetworkDeviceConfiguration()
            if let mac = n.macAddress, let m = VZMACAddress(string: mac) { dev.macAddress = m }
            switch n.mode {
            case .none: continue
            case .nat:
                dev.attachment = VZNATNetworkDeviceAttachment()
            case .bridged:
                let ifs = VZBridgedNetworkInterface.networkInterfaces
                if let iface = ifs.first(where: { $0.identifier == n.bridgeInterface }) ?? ifs.first {
                    dev.attachment = VZBridgedNetworkDeviceAttachment(interface: iface)
                } else {
                    warnings.append("bridged networking unavailable (needs com.apple.vm.networking entitlement); falling back to NAT")
                    dev.attachment = VZNATNetworkDeviceAttachment()
                }
            case .switch:
                if let fh = options.switchHandles[i] {
                    dev.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: fh)
                } else {
                    warnings.append("switch '\(n.switchName ?? "?")' not connected; NIC \(i) left unplugged")
                    continue
                }
            }
            nics.append(dev)
        }
        c.networkDevices = nics
    }

    // MARK: display & input

    private func configureGraphicsAndInput(_ c: VZVirtualMachineConfiguration) {
        let d = spec.display
        switch spec.os {
        case .macOS:
            #if arch(arm64)
            let g = VZMacGraphicsDeviceConfiguration()
            let count = 1 + max(0, min(d.extraDisplays, 3))
            g.displays = (0..<count).map { _ in
                VZMacGraphicsDisplayConfiguration(widthInPixels: d.width, heightInPixels: d.height, pixelsPerInch: d.pixelsPerInch)
            }
            c.graphicsDevices = [g]
            c.keyboards = [VZMacKeyboardConfiguration()]
            c.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
            #endif
        default:
            let g = VZVirtioGraphicsDeviceConfiguration()
            let count = 1 + max(0, min(d.extraDisplays, 3))
            g.scanouts = (0..<count).map { _ in
                VZVirtioGraphicsScanoutConfiguration(widthInPixels: d.width, heightInPixels: d.height)
            }
            c.graphicsDevices = [g]
            c.keyboards = [VZUSBKeyboardConfiguration()]
            c.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        }
    }

    // MARK: audio

    private func configureAudio(_ c: VZVirtualMachineConfiguration, isolated: Bool) {
        let ig = spec.integration
        guard ig.audioOutput || ig.microphone else { return }
        let sound = VZVirtioSoundDeviceConfiguration()
        var streams: [VZVirtioSoundDeviceStreamConfiguration] = []
        if ig.audioOutput {
            let out = VZVirtioSoundDeviceOutputStreamConfiguration()
            out.sink = VZHostAudioOutputStreamSink()
            streams.append(out)
        }
        if ig.microphone && !isolated {
            let inp = VZVirtioSoundDeviceInputStreamConfiguration()
            inp.source = VZHostAudioInputStreamSource()
            streams.append(inp)
        }
        sound.streams = streams
        c.audioDevices = [sound]
    }

    // MARK: shared folders + Rosetta

    private mutating func configureSharing(_ c: VZVirtualMachineConfiguration, isolated: Bool) throws {
        var devices: [VZDirectorySharingDeviceConfiguration] = []
        if !isolated && !spec.integration.sharedFolders.isEmpty {
            var dirs: [String: VZSharedDirectory] = [:]
            for f in spec.integration.sharedFolders {
                let path = (f.hostPath as NSString).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: path) else { warnings.append("shared folder missing: \(path)"); continue }
                dirs[f.name] = VZSharedDirectory(url: URL(fileURLWithPath: path), readOnly: f.readOnly)
            }
            if !dirs.isEmpty {
                let tag = spec.os == .macOS ? VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag : "altvm"
                let fs = VZVirtioFileSystemDeviceConfiguration(tag: tag)
                fs.share = VZMultipleDirectoryShare(directories: dirs)
                devices.append(fs)
            }
        }
        #if arch(arm64)
        if spec.os == .linux && spec.integration.rosetta {
            switch VZLinuxRosettaDirectoryShare.availability {
            case .installed:
                let fs = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
                fs.share = try VZLinuxRosettaDirectoryShare()
                devices.append(fs)
            case .notInstalled:
                warnings.append("Rosetta not installed on host — run `avm rosetta install` to run x86_64 Linux binaries")
            default: break
            }
        }
        #endif
        c.directorySharingDevices = devices
    }

    // MARK: console, clipboard, guest agent

    private func configureConsoleAndAgent(_ c: VZVirtualMachineConfiguration, isolated: Bool) {
        var consoles: [VZConsoleDeviceConfiguration] = []
        // Clipboard sharing via SPICE agent (spice-vdagent in Linux/Windows guests).
        if spec.integration.clipboard && !isolated && spec.os != .macOS {
            let console = VZVirtioConsoleDeviceConfiguration()
            let port = VZVirtioConsolePortConfiguration()
            port.name = VZSpiceAgentPortAttachment.spiceAgentPortName
            let spice = VZSpiceAgentPortAttachment()
            spice.sharesClipboard = true
            port.attachment = spice
            console.ports[0] = port
            consoles.append(console)
        }
        c.consoleDevices = consoles

        // Serial console → log file (or stdio) for headless / CI debugging.
        if spec.os != .macOS {
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            if options.consoleToStdio {
                serial.attachment = VZFileHandleSerialPortAttachment(
                    fileHandleForReading: FileHandle.standardInput, fileHandleForWriting: FileHandle.standardOutput)
            } else if let att = try? VZFileSerialPortAttachment(url: bundle.consoleLogURL, append: true) {
                serial.attachment = att
            }
            c.serialPorts = [serial]
        }
        if spec.integration.guestAgent {
            c.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        }
    }
}
