import Foundation
import IOKit
import IOKit.ps

/// System state at one moment of a capture.
public struct SystemSample: Codable, Equatable, Sendable {
    /// Seconds since the start of the capture.
    public var time: Double
    /// GPU utilization in percent.
    public var gpuUtilization: Double?
    /// Memory in use by the GPU, in megabytes.
    public var gpuMemory: Double?
    /// Hottest CPU core sensor, in °C.
    public var cpuTemperature: Double?
    /// Hottest GPU sensor, in °C.
    public var gpuTemperature: Double?
    /// Mean of the CPU core sensors, in °C. This is the figure tools such as mactop report.
    public var cpuTemperatureAverage: Double?
    /// Mean of the GPU sensors, in °C.
    public var gpuTemperatureAverage: Double?
    /// CPU power in watts. On macOS 27 an estimate from per-cluster power histograms.
    public var cpuPower: Double?
    /// GPU power in watts.
    public var gpuPower: Double?
    /// Power drawn by the whole Mac, in watts.
    public var systemPower: Double?
    /// CPU load across all cores in percent (100 = every core busy).
    public var cpuUsage: Double?
    /// CPU used by the game in percent of one core (can exceed 100).
    public var processCPU: Double?
    /// Memory footprint of the game, in megabytes.
    public var processMemory: Double?
    /// Memory in use system-wide, in megabytes.
    public var systemMemory: Double?
    /// `ProcessInfo.ThermalState` raw value: 0 nominal, 1 fair, 2 serious, 3 critical.
    public var thermalState: Int

    public init(time: Double, gpuUtilization: Double? = nil, gpuMemory: Double? = nil,
                cpuTemperature: Double? = nil, gpuTemperature: Double? = nil, cpuUsage: Double? = nil,
                processCPU: Double? = nil, processMemory: Double? = nil, systemMemory: Double? = nil,
                thermalState: Int = 0) {
        self.time = time
        self.gpuUtilization = gpuUtilization
        self.gpuMemory = gpuMemory
        self.cpuTemperature = cpuTemperature
        self.gpuTemperature = gpuTemperature
        self.cpuUsage = cpuUsage
        self.processCPU = processCPU
        self.processMemory = processMemory
        self.systemMemory = systemMemory
        self.thermalState = thermalState
    }
}

/// Average and peak of one metric over a capture.
public struct MetricRange: Equatable, Sendable {
    public var average: Double
    public var maximum: Double

    public init?(_ values: [Double]) {
        guard let maximum = values.max() else { return nil }
        self.maximum = maximum
        average = values.reduce(0, +) / Double(values.count)
    }
}

extension Array where Element == SystemSample {
    public func range(of metric: KeyPath<SystemSample, Double?>) -> MetricRange? {
        MetricRange(compactMap { $0[keyPath: metric] })
    }

    public var worstThermalState: Int { map(\.thermalState).max() ?? 0 }
}

/// One reading of everything the sampler measures, before it is tied to a capture and a game.
public struct SystemReading: Sendable {
    public struct ProcessUsage: Sendable {
        /// Percent of one core since the previous reading; nil on the first reading of a process.
        public var cpu: Double?
        public var memory: Double
    }

    public var date: Date
    public var sample: SystemSample
    public var processes: [Int32: ProcessUsage]
}

/// Reads GPU load, temperatures, CPU and memory use. Everything works without administrator rights.
/// Rates (CPU use) are measured between consecutive calls to `read`, so call it at a steady interval.
public final class SystemSampler {
    private let smc = SMCReader()
    private let power = PowerReader()
    private var previousCPUTicks: (busy: Double, total: Double)?
    private var previousProcessTime: [Int32: (cpuSeconds: Double, date: Date)] = [:]

    public init() {}

    public static var isOnBattery: Bool? {
        guard let type = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() as String? else { return nil }
        return type == kIOPMBatteryPowerKey
    }

    public func read(pids: [Int32], at date: Date = Date()) -> SystemReading {
        let gpu = Self.gpuStatistics()
        let temperatures = smc?.temperatures()
        var sample = SystemSample(time: 0)
        sample.gpuUtilization = gpu?.utilization
        sample.gpuMemory = gpu?.memory
        sample.cpuTemperature = temperatures?.cpu?.maximum
        sample.gpuTemperature = temperatures?.gpu?.maximum
        sample.cpuTemperatureAverage = temperatures?.cpu?.average
        sample.gpuTemperatureAverage = temperatures?.gpu?.average
        let watts = power?.read(at: date)
        sample.cpuPower = watts?.cpu
        sample.gpuPower = watts?.gpu
        sample.systemPower = smc?.systemPower()
        sample.cpuUsage = cpuUsage()
        sample.systemMemory = Self.systemMemory()
        sample.thermalState = ProcessInfo.processInfo.thermalState.rawValue

        var processes: [Int32: SystemReading.ProcessUsage] = [:]
        for pid in pids {
            guard let usage = Self.processUsage(pid) else { continue }
            var cpu: Double?
            if let previous = previousProcessTime[pid], date > previous.date {
                cpu = (usage.cpuSeconds - previous.cpuSeconds) / date.timeIntervalSince(previous.date) * 100
            }
            previousProcessTime[pid] = (usage.cpuSeconds, date)
            processes[pid] = .init(cpu: cpu, memory: usage.memory)
        }
        previousProcessTime = previousProcessTime.filter { pids.contains($0.key) }
        return SystemReading(date: date, sample: sample, processes: processes)
    }

    // MARK: GPU

    private static func gpuStatistics() -> (utilization: Double?, memory: Double?)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: (utilization: Double?, memory: Double?)?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let statistics = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString,
                                                                   kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            let utilization = (statistics["Device Utilization %"] as? NSNumber)?.doubleValue
            let memory = (statistics["In use system memory"] as? NSNumber).map { $0.doubleValue / 1_048_576 }
            // With several GPUs, report the busiest one.
            if result == nil || (utilization ?? 0) > (result?.utilization ?? 0) { result = (utilization, memory) }
        }
        return result
    }

    // MARK: CPU and memory

    private func cpuUsage() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        // cpu_ticks: user, system, idle, nice.
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3].map(Double.init)
        let current = (busy: ticks[0] + ticks[1] + ticks[3], total: ticks.reduce(0, +))
        defer { previousCPUTicks = current }
        guard let previous = previousCPUTicks, current.total > previous.total else { return nil }
        return (current.busy - previous.busy) / (current.total - previous.total) * 100
    }

    /// Memory in use as Activity Monitor counts it: app memory, wired and compressed.
    private static func systemMemory() -> Double? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let pages = Double(statistics.internal_page_count) - Double(statistics.purgeable_count)
            + Double(statistics.wire_count) + Double(statistics.compressor_page_count)
        return pages * Double(vm_kernel_page_size) / 1_048_576
    }

    private static let machTimeToSeconds: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1e9
    }()

    private static func processUsage(_ pid: Int32) -> (cpuSeconds: Double, memory: Double)? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard status == 0 else { return nil }
        // The kernel reports CPU time in Mach time units.
        return (Double(info.ri_user_time + info.ri_system_time) * machTimeToSeconds,
                Double(info.ri_phys_footprint) / 1_048_576)
    }
}

/// Reads temperature sensors from the System Management Controller.
///
/// The key names are undocumented. On Apple silicon `Tp…`, `Te…` and `Ts…` keys are CPU core
/// sensors (performance, efficiency and super cores) and `Tg…` keys GPU sensors — the same
/// selection mactop makes. Which exact keys exist differs per chip, so they are discovered at start-up.
private final class SMCReader {
    private struct KeyData {
        struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
        struct PowerLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0 }
        struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var attributes: UInt8 = 0 }
        var key: UInt32 = 0
        var version = Version()
        var powerLimit = PowerLimit()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0, status: UInt8 = 0, command: UInt8 = 0
        var index: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
            = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private enum Command: UInt8 {
        case readBytes = 5, keyAtIndex = 8, readKeyInfo = 9
    }

    private static let floatType: UInt32 = 0x666C_7420  // 'flt '
    private static let keyCountKey: UInt32 = 0x234B_4559  // '#KEY'
    /// Readings outside this range are disconnected or unrelated sensors.
    private static let plausible: ClosedRange<Float> = 10...130

    private var connection: io_connect_t = 0
    private var cpuKeys: [UInt32] = []
    private var gpuKeys: [UInt32] = []

    init?() {
        guard MemoryLayout<KeyData>.size == 80 else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        discoverKeys()
        if cpuKeys.isEmpty && gpuKeys.isEmpty { return nil }
    }

    deinit {
        IOServiceClose(connection)
    }

    func temperatures() -> (cpu: MetricRange?, gpu: MetricRange?) {
        func range(_ keys: [UInt32]) -> MetricRange? {
            MetricRange(keys.compactMap(float).filter(Self.plausible.contains).map(Double.init))
        }
        return (range(cpuKeys), range(gpuKeys))
    }

    /// Power drawn by the whole machine in watts: the first of these keys that reads a plausible
    /// value. `PSTR` is the system total on laptops; desktops report it on the DC-in keys.
    func systemPower() -> Double? {
        for name in ["PSTR", "PDTR", "PD0R"] {
            let key = name.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard let info = keyInfo(key), info.dataType == Self.floatType, info.dataSize == 4,
                  let watts = float(key), watts > 0, watts <= 1000 else { continue }
            return Double(watts)
        }
        return nil
    }

    private func discoverKeys() {
        guard let count = read(Self.keyCountKey, size: 4) else { return }
        let total = count.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        for index in 0..<total {
            var input = KeyData()
            input.command = Command.keyAtIndex.rawValue
            input.index = index
            guard let key = call(&input)?.key else { continue }
            // 'Tp..', 'Te..', 'Ts..' are CPU cores; 'Tg..' is the GPU.
            let prefix = key >> 16
            let isCPU = prefix == 0x5470 || prefix == 0x5465 || prefix == 0x5473
            guard isCPU || prefix == 0x5467,
                  let info = keyInfo(key), info.dataType == Self.floatType, info.dataSize == 4,
                  let value = float(key), Self.plausible.contains(value) else { continue }
            if isCPU { cpuKeys.append(key) } else { gpuKeys.append(key) }
        }
    }

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        var size = MemoryLayout<KeyData>.size
        let status = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<KeyData>.size, &output, &size)
        return status == KERN_SUCCESS && output.result == 0 ? output : nil
    }

    private func keyInfo(_ key: UInt32) -> KeyData.KeyInfo? {
        var input = KeyData()
        input.key = key
        input.command = Command.readKeyInfo.rawValue
        return call(&input)?.keyInfo
    }

    private func read(_ key: UInt32, size: UInt32) -> [UInt8]? {
        var input = KeyData()
        input.key = key
        input.keyInfo.dataSize = size
        input.command = Command.readBytes.rawValue
        guard let output = call(&input) else { return nil }
        return withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(size))) }
    }

    private func float(_ key: UInt32) -> Float? {
        read(key, size: 4)?.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
    }
}
