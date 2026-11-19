import Foundation
import Virtualization

public struct CreateOptions: Sendable {
    public var name: String
    public var os: GuestOS = .linux
    public var profile: WorkloadProfile = .productivity
    public var cpus: Int?
    public var memoryMiB: UInt64?
    public var diskGiB: UInt64?
    public var username: String = NSUserName()
    public var password: String?
    public var sshKeys: [String] = Provisioner.defaultSSHKeys()
    public var shareHome = true
    public var isolated = false
    public var disposable = false
    public var secureBoot = false
    public var networkMode: NetworkMode = .nat
    public var switchName: String?
    public var packages: [String] = []
    public var runcmd: [String] = []
    public var labels: [String: String] = [:]

    public init(name: String) { self.name = name }
}

/// Builds VMs from catalog cloud images, ISOs or macOS restore images.
public enum Provisioner {
    public static func defaultSSHKeys() -> [String] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "pub" }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public static func baseSpec(_ o: CreateOptions) -> VMSpec {
        var spec = VMSpec.defaults(name: o.name, os: o.os, profile: o.profile, diskGiB: o.diskGiB)
        if let c = o.cpus { spec.cpus = c }
        if let m = o.memoryMiB { spec.memoryMiB = m }
        if !o.shareHome { spec.integration.sharedFolders = [] }
        spec.security.isolated = o.isolated
        spec.security.disposable = o.disposable
        spec.security.secureBoot = o.secureBoot
        if o.networkMode != .nat || o.switchName != nil {
            spec.network = [NetworkSpec(mode: o.switchName != nil ? .switch : o.networkMode, macAddress: MACAddress.random(), switchName: o.switchName)]
        }
        spec.labels = o.labels
        if let policy = Policy.loadActive(), policy.organization != "LOCKDOWN" { policy.remediate(&spec) }
        return spec
    }

    // MARK: cloud images

    /// Instant Linux VM from a cloud image: APFS-clone (or qcow2-convert) the cached image,
    /// grow it, attach a cloud-init seed. First boot is fully unattended.
    @discardableResult
    public static func createFromCloudImage(_ o: CreateOptions, image: URL, progress: ((String) -> Void)? = nil) throws -> VMBundle {
        var spec = baseSpec(o)
        spec.disks = [DiskSpec(file: "disk0.img", sizeGiB: o.diskGiB ?? 64), DiskSpec(file: "seed.iso", sizeGiB: 0, readOnly: true)]
        spec.labels["source"] = image.lastPathComponent
        spec.fastBoot = true
        let bundle = try VMLibrary.create(spec: spec, createDisks: false)
        do {
            let disk = bundle.url.appendingPathComponent("disk0.img")
            if QCOW2.isQCOW2(image) {
                progress?("converting qcow2 → raw")
                // Cache the converted raw image so the next VM is an instant clone.
                let raw = Paths.cache.appendingPathComponent(image.deletingPathExtension().lastPathComponent + ".raw")
                if !FileManager.default.fileExists(atPath: raw.path) {
                    let tmp = raw.appendingPathExtension("part")
                    try QCOW2.convert(image, to: tmp)
                    try FileManager.default.moveItem(at: tmp, to: raw)
                }
                try DiskManager.cloneFile(from: raw, to: disk)
            } else {
                progress?("cloning image (copy-on-write)")
                try DiskManager.cloneFile(from: image, to: disk)
            }
            let current = DiskManager.logicalSize(disk)
            let want = (o.diskGiB ?? 64) << 30
            if want > current { try DiskManager.resize(at: disk, toGiB: o.diskGiB ?? 64) }
            progress?("writing cloud-init seed")
            try CloudInit.writeSeed(to: bundle.url.appendingPathComponent("seed.iso"), spec: spec, options: o)
        } catch {
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
        }
        return bundle
    }

    // MARK: ISO installers

    @discardableResult
    public static func createFromISO(_ o: CreateOptions, iso: URL) throws -> VMBundle {
        var spec = baseSpec(o)
        spec.installMedia = iso.path
        spec.labels["source"] = iso.lastPathComponent
        return try VMLibrary.create(spec: spec)
    }

    @discardableResult
    public static func createBlank(_ o: CreateOptions) throws -> VMBundle {
        try VMLibrary.create(spec: baseSpec(o))
    }

    /// Detach installer media after the OS is installed.
    public static func ejectInstallMedia(_ name: String) throws {
        let b = try VMLibrary.find(name)
        var s = try b.loadSpec()
        s.installMedia = nil
        try b.saveSpec(s)
    }
}

// MARK: - cloud-init

public enum CloudInit {
    public static func userData(spec: VMSpec, options o: CreateOptions) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var y = "#cloud-config\n"
        y += "hostname: \(spec.name)\n"
        y += "users:\n  - name: \(q(o.username))\n    gecos: \(q(NSFullUserName()))\n    groups: [sudo, adm]\n    shell: /bin/bash\n    sudo: \"ALL=(ALL) NOPASSWD:ALL\"\n"
        if let pw = o.password {
            y += "    lock_passwd: false\n    plain_text_passwd: \(q(pw))\n"
        } else {
            y += "    lock_passwd: true\n"
        }
        if !o.sshKeys.isEmpty {
            y += "    ssh_authorized_keys:\n" + o.sshKeys.map { "      - \(q($0))\n" }.joined()
        }
        y += "ssh_pwauth: \(o.password != nil)\n"
        y += "write_files:\n"
        y += "  - path: /usr/local/bin/altvm-agent\n    permissions: '0755'\n    encoding: b64\n    content: \(Data(GuestAgentAssets.agentPy.utf8).base64EncodedString())\n"
        y += "  - path: /etc/systemd/system/altvm-agent.service\n    encoding: b64\n    content: \(Data(GuestAgentAssets.service.utf8).base64EncodedString())\n"
        y += "  - path: /etc/modules-load.d/altvm.conf\n    content: |\n      vmw_vsock_virtio_transport\n      virtiofs\n"
        var run: [String] = [
            "modprobe vmw_vsock_virtio_transport || true",
            "systemctl daemon-reload",
            "systemctl enable --now altvm-agent.service",
        ]
        if !spec.integration.sharedFolders.isEmpty && !spec.security.isolated {
            run += [
                "mkdir -p /mnt/mac",
                "grep -q ' /mnt/mac ' /etc/fstab || echo 'altvm /mnt/mac virtiofs rw,nofail 0 0' >> /etc/fstab",
                "mount /mnt/mac || true",
            ]
        }
        if spec.integration.rosetta {
            run += [
                "mkdir -p /media/rosetta",
                "grep -q rosetta /etc/fstab || echo 'rosetta /media/rosetta virtiofs ro,nofail 0 0' >> /etc/fstab",
                "mount /media/rosetta || true",
                #"if [ -x /media/rosetta/rosetta ]; then echo ':rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/media/rosetta/rosetta:CF' > /etc/binfmt.d/rosetta.conf; systemctl restart systemd-binfmt || true; fi"#,
            ]
        }
        run += o.runcmd
        run.append("sync")  // make provisioning durable immediately (see VMRunner.flushGuest)
        if !o.packages.isEmpty {
            y += "package_update: true\npackages:\n" + o.packages.map { "  - \($0)\n" }.joined()
        }
        y += "runcmd:\n" + run.map { "  - \(q($0))\n" }.joined()
        y += "final_message: \"AltVM: \(spec.name) ready after $UPTIME seconds\"\n"
        return y
    }

    public static func writeSeed(to iso: URL, spec: VMSpec, options: CreateOptions) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("altvm-seed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "instance-id: \(UUID().uuidString)\nlocal-hostname: \(spec.name)\n".write(to: dir.appendingPathComponent("meta-data"), atomically: true, encoding: .utf8)
        try userData(spec: spec, options: options).write(to: dir.appendingPathComponent("user-data"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: iso)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["makehybrid", "-quiet", "-o", iso.path, dir.path, "-iso", "-joliet", "-default-volume-name", "cidata"]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw AltVMError.io("hdiutil makehybrid failed (\(p.terminationStatus))") }
    }
}

// MARK: - macOS guests

#if arch(arm64)
@MainActor
public enum MacOSInstall {
    /// Resolves the IPSW (download latest if none given), creates the VM and runs the installer.
    public static func run(_ o: CreateOptions, ipsw: URL?, progress: @escaping @Sendable (String, Double) -> Void) async throws -> VMBundle {
        let ipswURL: URL
        if let ipsw {
            ipswURL = ipsw
        } else {
            progress("resolving latest macOS", 0)
            let image = try await VZMacOSRestoreImage.latestSupported
            let dest = Paths.cache.appendingPathComponent(image.url.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try Paths.ensure()
                try await Downloader.download(image.url, to: dest) { p, _ in progress("downloading \(image.url.lastPathComponent)", p) }
            }
            ipswURL = dest
        }
        progress("loading restore image", 0)
        let image = try await VZMacOSRestoreImage.image(from: ipswURL)
        guard let req = image.mostFeaturefulSupportedConfiguration else {
            throw AltVMError.unsupported("macOS \(image.operatingSystemVersion.majorVersion) cannot run on this host")
        }
        var opts = o
        opts.os = .macOS
        var spec = Provisioner.baseSpec(opts)
        spec.cpus = max(spec.cpus, req.minimumSupportedCPUCount)
        spec.memoryMiB = max(spec.memoryMiB, req.minimumSupportedMemorySize >> 20)
        if let pw = o.password {
            spec.provisioning = ProvisioningSpec(fullName: NSFullUserName(), username: o.username, password: pw)
        }
        spec.labels["source"] = ipswURL.lastPathComponent
        let bundle = try VMLibrary.create(spec: spec)
        do {
            try PlatformFactory.createMacPlatform(bundle: bundle, requirements: req)
            var builder = ConfigBuilder(spec: spec, bundle: bundle)
            let config = try builder.build()
            let vm = VZVirtualMachine(configuration: config)
            let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipswURL)
            let obs = installer.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
                progress("installing macOS", p.fractionCompleted)
            }
            defer { obs.invalidate() }
            try await installer.install()
            AuditLog.shared.record("vm.install", vm: spec.name, details: ["ipsw": ipswURL.lastPathComponent])
            return bundle
        } catch {
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
        }
    }
}
#endif
