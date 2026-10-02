import Foundation
import IOKit

/// The machine a capture was recorded on.
public struct HardwareInfo: Codable, Equatable, Sendable {
    public struct CoreTier: Codable, Equatable, Sendable {
        /// The system's name for the tier, e.g. "Super", "Performance" or "Efficiency".
        public var name: String
        public var cores: Int

        public init(name: String, cores: Int) {
            self.name = name
            self.cores = cores
        }
    }

    /// Marketing name, e.g. "MacBook Pro (16-inch, M5 Pro)".
    public var modelName: String?
    /// Model identifier, e.g. "Mac17,8".
    public var modelIdentifier: String
    /// System on a chip, e.g. "Apple M5 Pro".
    public var chip: String
    /// CPU core tiers, fastest first.
    public var coreTiers: [CoreTier]
    public var gpuCores: Int?
    public var memoryGB: Int
    /// e.g. "27.0.1"
    public var osVersion: String
    /// e.g. "26A434"
    public var osBuild: String

    public init(modelName: String?, modelIdentifier: String, chip: String, coreTiers: [CoreTier],
                gpuCores: Int?, memoryGB: Int, osVersion: String, osBuild: String) {
        self.modelName = modelName
        self.modelIdentifier = modelIdentifier
        self.chip = chip
        self.coreTiers = coreTiers
        self.gpuCores = gpuCores
        self.memoryGB = memoryGB
        self.osVersion = osVersion
        self.osBuild = osBuild
    }

    public var cpuCores: Int { coreTiers.reduce(0) { $0 + $1.cores } }

    /// One line for display: "MacBook Pro (16-inch, M5 Pro) · Apple M5 Pro · 48 GB · macOS 27.0.1".
    /// The chip is left out when the model name already contains it.
    public var summary: String {
        let model = modelName ?? modelIdentifier
        let shortChip = chip.replacingOccurrences(of: "Apple ", with: "")
        let parts = [model, model.contains(shortChip) ? nil : chip, "\(memoryGB) GB", "macOS \(osVersion)"]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// Reads the current machine.
    public static func current() -> HardwareInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let tiers = (0..<(sysctlInteger("hw.nperflevels") ?? 0)).compactMap { level -> CoreTier? in
            guard let cores = sysctlInteger("hw.perflevel\(level).physicalcpu"), cores > 0 else { return nil }
            return CoreTier(name: sysctlString("hw.perflevel\(level).name") ?? "", cores: cores)
        }
        return HardwareInfo(
            modelName: registryString(path: "IODeviceTree:/product", key: "product-name"),
            modelIdentifier: sysctlString("hw.model") ?? "",
            chip: sysctlString("machdep.cpu.brand_string") ?? "",
            coreTiers: tiers,
            gpuCores: gpuCoreCount(),
            memoryGB: Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()),
            osVersion: [version.majorVersion, version.minorVersion, version.patchVersion]
                .map(String.init).joined(separator: "."),
            osBuild: sysctlString("kern.osversion") ?? "")
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
    }

    private static func sysctlInteger(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }

    /// Device-tree strings are stored as NUL-terminated bytes.
    private static func registryString(path: String, key: String) -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, path)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        let value = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    private static func gpuCoreCount() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if let count = IORegistryEntryCreateCFProperty(entry, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber {
                return count.intValue
            }
        }
        return nil
    }
}
