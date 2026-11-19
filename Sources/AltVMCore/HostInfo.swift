import Foundation
import IOKit.ps
import Virtualization

/// Snapshot of host capabilities and power state.
public struct HostInfo: Codable, Sendable {
    public var cpuCount: Int
    public var performanceCores: Int
    public var memoryMiB: UInt64
    public var onBattery: Bool
    public var batteryPercent: Int?
    public var lowPowerMode: Bool
    public var thermalState: String
    public var osVersion: String
    public var maxVMCPUs: Int
    public var maxVMMemoryMiB: UInt64
    public var rosettaAvailable: Bool

    public static func current() -> HostInfo {
        let pi = ProcessInfo.processInfo
        let perfCores = sysctlInt("hw.perflevel0.physicalcpu") ?? pi.activeProcessorCount
        let (onBattery, pct) = powerSource()
        let thermal: String
        switch pi.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        var rosetta = false
        #if arch(arm64)
        rosetta = VZLinuxRosettaDirectoryShare.availability != .notSupported
        #endif
        return HostInfo(
            cpuCount: pi.activeProcessorCount,
            performanceCores: perfCores,
            memoryMiB: pi.physicalMemory / (1024 * 1024),
            onBattery: onBattery,
            batteryPercent: pct,
            lowPowerMode: pi.isLowPowerModeEnabled,
            thermalState: thermal,
            osVersion: pi.operatingSystemVersionString,
            maxVMCPUs: VZVirtualMachineConfiguration.maximumAllowedCPUCount,
            maxVMMemoryMiB: VZVirtualMachineConfiguration.maximumAllowedMemorySize / (1024 * 1024),
            rosettaAvailable: rosetta
        )
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    static func powerSource() -> (Bool, Int?) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return (false, nil)
        }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            let state = desc[kIOPSPowerSourceStateKey] as? String
            let cur = desc[kIOPSCurrentCapacityKey] as? Int
            let max = desc[kIOPSMaxCapacityKey] as? Int
            let pct = (cur != nil && max != nil && max! > 0) ? cur! * 100 / max! : nil
            return (state == kIOPSBatteryPowerValue, pct)
        }
        return (false, nil)
    }
}

/// Computes VM resources from the host instead of hard-coded numbers. There are no artificial
/// caps (Parallels Standard: 8 GB / 4 vCPU). Limits come only from Virtualization.framework and
/// keeping the host responsive.
public enum ProfileEngine {
    public struct Resources: Equatable, Sendable {
        public var cpus: Int
        public var memoryMiB: UInt64
    }

    public static func resources(for profile: WorkloadProfile, os: GuestOS, host: HostInfo) -> Resources {
        let hostMem = host.memoryMiB
        let p = max(2, host.performanceCores)
        let all = max(2, host.cpuCount)
        var cpus: Int
        var memFraction: Double
        switch profile {
        case .productivity: cpus = max(2, p / 2); memFraction = 0.35
        case .gaming:       cpus = max(2, p);     memFraction = 0.50
        case .design:       cpus = max(2, p);     memFraction = 0.50
        case .development:  cpus = max(2, all - 2); memFraction = 0.50
        case .server:       cpus = max(2, all - 1); memFraction = 0.60
        case .travel:       cpus = 2;             memFraction = 0.25
        }
        // Thermal / battery awareness: never let the VM cook the laptop.
        if host.onBattery || host.lowPowerMode || host.thermalState == "serious" || host.thermalState == "critical" {
            cpus = min(cpus, max(2, p / 2))
        }
        var memMiB = UInt64(Double(hostMem) * memFraction)
        let minMem: UInt64 = os == .macOS ? 4096 : os == .windows ? 4096 : 1024
        memMiB = max(minMem, memMiB)
        // Keep at least 4 GiB (or 25%) for the host.
        let hostReserve = max(4096, hostMem / 4)
        if hostMem > hostReserve { memMiB = min(memMiB, hostMem - hostReserve) }
        memMiB = min(memMiB, host.maxVMMemoryMiB)
        memMiB = memMiB / 256 * 256 // align
        cpus = min(cpus, host.maxVMCPUs, all)
        return Resources(cpus: cpus, memoryMiB: memMiB)
    }

    /// Profile that should be in effect right now (adaptive resources).
    public static func effectiveProfile(requested: WorkloadProfile, host: HostInfo) -> WorkloadProfile {
        if requested != .travel, host.onBattery, (host.batteryPercent ?? 100) < 30 || host.lowPowerMode {
            return .travel
        }
        return requested
    }
}
