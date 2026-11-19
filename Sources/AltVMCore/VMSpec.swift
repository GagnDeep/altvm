import Foundation

/// Guest operating-system family. Determines boot loader and device model.
public enum GuestOS: String, Codable, CaseIterable, Sendable {
    case macOS = "macos"
    case linux
    case windows
    case other

    public var displayName: String {
        switch self {
        case .macOS: return "macOS"
        case .linux: return "Linux"
        case .windows: return "Windows (ARM64)"
        case .other: return "Other (EFI)"
        }
    }
}

/// Workload profiles. Parallels offers 4; we offer 6 and they are *computed from the host*
/// instead of being fixed numbers, and are re-applied automatically (e.g. travel on battery).
public enum WorkloadProfile: String, Codable, CaseIterable, Sendable {
    case productivity, gaming, design, development, server, travel
}

public enum NetworkMode: String, Codable, Sendable {
    /// Shared NAT through the host (default, works everywhere).
    case nat
    /// Bridged to a physical interface (requires the com.apple.vm.networking entitlement).
    case bridged
    /// Attached to an AltVM virtual switch: custom L2 networks between VMs with
    /// latency / jitter / loss / bandwidth shaping (network conditioning).
    case `switch`
    /// No network at all (used by isolated mode).
    case none
}

public struct NetworkSpec: Codable, Equatable, Sendable {
    public var mode: NetworkMode = .nat
    /// Stable MAC address. Generated once on creation so DHCP leases survive restarts.
    public var macAddress: String?
    /// Bridged interface BSD name (e.g. en0) when mode == .bridged.
    public var bridgeInterface: String?
    /// Switch name when mode == .switch.
    public var switchName: String?

    public init(mode: NetworkMode = .nat, macAddress: String? = nil, bridgeInterface: String? = nil, switchName: String? = nil) {
        self.mode = mode
        self.macAddress = macAddress
        self.bridgeInterface = bridgeInterface
        self.switchName = switchName
    }
}

public struct DiskSpec: Codable, Equatable, Sendable {
    /// File name inside the bundle (or absolute path for external disks).
    public var file: String
    public var sizeGiB: UInt64
    public var readOnly: Bool = false
    /// Use NVMe instead of virtio-blk (better for Windows / EFI guests).
    public var nvme: Bool = false

    public init(file: String, sizeGiB: UInt64, readOnly: Bool = false, nvme: Bool = false) {
        self.file = file
        self.sizeGiB = sizeGiB
        self.readOnly = readOnly
        self.nvme = nvme
    }
}

public struct SharedFolderSpec: Codable, Equatable, Sendable {
    public var name: String
    public var hostPath: String
    public var readOnly: Bool = false

    public init(name: String, hostPath: String, readOnly: Bool = false) {
        self.name = name
        self.hostPath = hostPath
        self.readOnly = readOnly
    }

    /// The Mac-integration defaults: Desktop, Documents, Downloads.
    public static var macDefaults: [SharedFolderSpec] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["Desktop", "Documents", "Downloads"].map {
            SharedFolderSpec(name: $0.lowercased(), hostPath: "\(home)/\($0)")
        }
    }
}

public struct DisplaySpec: Codable, Equatable, Sendable {
    public var width: Int = 1920
    public var height: Int = 1200
    public var pixelsPerInch: Int = 144   // Retina
    /// Additional virtual displays (macOS guests support several).
    public var extraDisplays: Int = 0
    /// Follow the window size live (macOS 14+ guests).
    public var autoResize: Bool = true

    public init(width: Int = 1920, height: Int = 1200, pixelsPerInch: Int = 144, extraDisplays: Int = 0, autoResize: Bool = true) {
        self.width = width
        self.height = height
        self.pixelsPerInch = pixelsPerInch
        self.extraDisplays = extraDisplays
        self.autoResize = autoResize
    }
}

/// Integration toggles. Each is individually lockable by enterprise policy.
public struct IntegrationSpec: Codable, Equatable, Sendable {
    public var clipboard: Bool = true
    public var sharedFolders: [SharedFolderSpec] = []
    public var audioOutput: Bool = true
    public var microphone: Bool = false
    /// Rosetta 2 inside Linux guests: run x86_64 Linux binaries at near-native speed.
    public var rosetta: Bool = true
    /// Guest agent channel over virtio-vsock (exec, IP discovery, time sync, graceful shutdown).
    public var guestAgent: Bool = true
    /// USB passthrough device matchers ("vendorID:productID", hex).
    public var usbPassthrough: [String] = []

    public init() {}
}

public struct SecuritySpec: Codable, Equatable, Sendable {
    /// Isolated mode: no network (unless switch), no clipboard, no shared folders, no mic, no USB.
    public var isolated: Bool = false
    /// Disposable: every boot starts from the "clean" snapshot; changes are thrown away on stop.
    public var disposable: Bool = false
    /// VM bundle lives in an AES-256 encrypted container.
    public var encrypted: Bool = false
    /// EFI Secure Boot (macOS 27 hosts) for Linux/Windows guests.
    public var secureBoot: Bool = false
    /// Organisation id this VM is bound to. Bound VMs refuse to start without a matching policy.
    public var organization: String?
    /// Expiry date after which the VM refuses to start (contractor / training VMs).
    public var expires: Date?

    public init() {}
}

/// Automatic first-boot provisioning (macOS 27 hosts, macOS guests): creates the user,
/// optionally enables auto-login and SSH. Nobody clicks through Setup Assistant.
public struct ProvisioningSpec: Codable, Equatable, Sendable {
    public var fullName: String
    public var username: String
    /// Stored only until first boot, then scrubbed from spec.json.
    public var password: String?
    public var autoLogin: Bool = true
    public var enableSSH: Bool = true

    public init(fullName: String, username: String, password: String?, autoLogin: Bool = true, enableSSH: Bool = true) {
        self.fullName = fullName
        self.username = username
        self.password = password
        self.autoLogin = autoLogin
        self.enableSSH = enableSSH
    }
}

/// The complete, declarative description of a VM. This is what `spec.json` contains and what a
/// `Vmfile` declares. Everything the UI can do is expressible here, so VMs are reproducible as code.
public struct VMSpec: Codable, Equatable, Sendable {
    public var name: String
    public var os: GuestOS
    public var cpus: Int
    public var memoryMiB: UInt64
    public var profile: WorkloadProfile = .productivity
    /// Let the profile engine re-size CPU/RAM at each boot based on the host's current state.
    public var adaptiveResources: Bool = true
    public var disks: [DiskSpec]
    public var network: [NetworkSpec] = [NetworkSpec()]
    public var display: DisplaySpec = DisplaySpec()
    public var integration: IntegrationSpec = IntegrationSpec()
    public var security: SecuritySpec = SecuritySpec()
    public var provisioning: ProvisioningSpec?
    /// Installer / live ISO attached as a read-only USB mass-storage device (EFI guests).
    public var installMedia: String?
    /// Additional read-only USB media (e.g. the Windows answer-file stick); bundle-relative or absolute.
    public var extraMedia: [String]?
    /// Direct Linux kernel boot (fast CI VMs): kernel + initrd + cmdline, skipping EFI.
    public var kernel: String?
    public var initrd: String?
    public var kernelCommandLine: String?
    /// FastBoot (Linux): after provisioning, the guest's own kernel/initrd are synced out via the
    /// agent and booted directly (no firmware): ~2 s boots and reliable suspend/resume. The EFI
    /// store is kept, so `avm set <vm> boot=efi` reverts at any time.
    public var fastBoot: Bool?
    /// Free-form labels for fleet management (team, cost-center, purpose).
    public var labels: [String: String] = [:]
    public var notes: String = ""
    public var created: Date = Date()

    public init(name: String, os: GuestOS, cpus: Int, memoryMiB: UInt64, disks: [DiskSpec]) {
        self.name = name
        self.os = os
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.disks = disks
    }

    /// Opinionated defaults per guest OS, sized by the profile engine for *this* host.
    public static func defaults(name: String, os: GuestOS, profile: WorkloadProfile = .productivity, diskGiB: UInt64? = nil) -> VMSpec {
        let res = ProfileEngine.resources(for: profile, os: os, host: HostInfo.current())
        let defaultDisk: UInt64 = diskGiB ?? (os == .macOS ? 96 : os == .windows ? 128 : 64)
        var spec = VMSpec(
            name: name, os: os, cpus: res.cpus, memoryMiB: res.memoryMiB,
            disks: [DiskSpec(file: "disk0.img", sizeGiB: defaultDisk, nvme: os == .windows)]
        )
        spec.profile = profile
        spec.network = [NetworkSpec(mode: .nat, macAddress: MACAddress.random())]
        spec.integration.sharedFolders = os == .macOS ? [] : SharedFolderSpec.macDefaults
        spec.integration.rosetta = os == .linux
        return spec
    }
}

public enum MACAddress {
    /// Locally-administered unicast MAC.
    public static func random() -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] & 0xFC) | 0x02
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}
