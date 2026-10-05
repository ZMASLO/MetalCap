import Foundation
import IOKit

/// The IOReport functions MetalCap uses. IOReport is a private library (power tools such as mactop
/// use the same entry points), so it is opened at run time instead of linked: if a future macOS drops
/// it or any of these functions, MetalCap still starts and simply has no CPU/GPU power or clocks.
struct IOReportFunctions {
    typealias CopyChannels = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    typealias MergeChannels = @convention(c) (CFMutableDictionary, CFDictionary, CFTypeRef?) -> Void
    typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, CFMutableDictionary,
                                                  UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64,
                                                  CFTypeRef?) -> Unmanaged<CFTypeRef>?
    typealias CreateSamples = @convention(c) (CFTypeRef, CFMutableDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias CreateSamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    typealias ChannelInteger = @convention(c) (CFDictionary, Int32) -> Int64
    typealias StateCount = @convention(c) (CFDictionary) -> Int32
    typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?

    let copyChannelsInGroup: CopyChannels
    let mergeChannels: MergeChannels
    let createSubscription: CreateSubscription
    let createSamples: CreateSamples
    let createSamplesDelta: CreateSamplesDelta
    let channelGetGroup: ChannelString
    let channelGetSubGroup: ChannelString
    let channelGetChannelName: ChannelString
    let channelGetUnitLabel: ChannelString
    let simpleGetIntegerValue: ChannelInteger
    let stateGetCount: StateCount
    let stateGetNameForIndex: StateName
    let stateGetResidency: ChannelInteger

    static let shared = IOReportFunctions(libraryPath: "/usr/lib/libIOReport.dylib")

    /// Nil when the library or any of the functions is missing.
    init?(libraryPath: String) {
        guard let library = dlopen(libraryPath, RTLD_NOW | RTLD_LOCAL) else { return nil }
        func function<T>(_ name: String, _: T.Type) -> T? {
            dlsym(library, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let copyChannelsInGroup = function("IOReportCopyChannelsInGroup", CopyChannels.self),
              let mergeChannels = function("IOReportMergeChannels", MergeChannels.self),
              let createSubscription = function("IOReportCreateSubscription", CreateSubscription.self),
              let createSamples = function("IOReportCreateSamples", CreateSamples.self),
              let createSamplesDelta = function("IOReportCreateSamplesDelta", CreateSamplesDelta.self),
              let channelGetGroup = function("IOReportChannelGetGroup", ChannelString.self),
              let channelGetSubGroup = function("IOReportChannelGetSubGroup", ChannelString.self),
              let channelGetChannelName = function("IOReportChannelGetChannelName", ChannelString.self),
              let channelGetUnitLabel = function("IOReportChannelGetUnitLabel", ChannelString.self),
              let simpleGetIntegerValue = function("IOReportSimpleGetIntegerValue", ChannelInteger.self),
              let stateGetCount = function("IOReportStateGetCount", StateCount.self),
              let stateGetNameForIndex = function("IOReportStateGetNameForIndex", StateName.self),
              let stateGetResidency = function("IOReportStateGetResidency", ChannelInteger.self)
        else { return nil }
        self.copyChannelsInGroup = copyChannelsInGroup
        self.mergeChannels = mergeChannels
        self.createSubscription = createSubscription
        self.createSamples = createSamples
        self.createSamplesDelta = createSamplesDelta
        self.channelGetGroup = channelGetGroup
        self.channelGetSubGroup = channelGetSubGroup
        self.channelGetChannelName = channelGetChannelName
        self.channelGetUnitLabel = channelGetUnitLabel
        self.simpleGetIntegerValue = simpleGetIntegerValue
        self.stateGetCount = stateGetCount
        self.stateGetNameForIndex = stateGetNameForIndex
        self.stateGetResidency = stateGetResidency
    }
}

/// Pure helpers for interpreting IOReport power channels, following mactop's approach.
enum PowerChannels {
    /// CPU cluster power histograms live in the PMP groups' "Energy" subgroup and are named
    /// like "PACC", "PACC0", "MACC1" or "PACC0 SRAM". "AGX" (the GPU) is not one of them.
    static func isCPUPowerHistogram(subgroup: String, name: String) -> Bool {
        guard subgroup == "Energy", name.count >= 4, name.dropFirst().hasPrefix("ACC") else { return false }
        let rest = name.dropFirst(4).drop(while: \.isNumber)
        return rest.isEmpty || rest == " SRAM"
    }

    /// The value a histogram bin stands for, read from its label ("2W" -> 2, "0.250W" -> 0.25).
    static func binValue(_ label: String) -> Double {
        Double(label.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber || $0 == "." }) ?? 0
    }

    /// Residency-weighted average of histogram bins. The lowest bin counts as zero: an idle,
    /// power-gated cluster sits in it all the time and reading it at its label would add
    /// that many watts per idle cluster.
    static func weightedAverage(bins: [Double], residency: [Int64]) -> Double {
        let total = residency.reduce(0, +)
        guard total > 0 else { return 0 }
        let weighted = zip(bins, residency).dropFirst().reduce(0.0) { $0 + $1.0 * Double($1.1) }
        return weighted / Double(total)
    }

    /// Frequencies in MHz from a `voltage-states…` table of the power manager: 8-byte entries
    /// whose first 4 bytes are the frequency, in Hz on older chips and in kHz from the M5 on.
    static func frequencies(fromTable data: Data) -> [Double] {
        stride(from: 0, to: data.count - 7, by: 8).compactMap { offset in
            let raw = data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            if raw >= 100_000_000 { return Double(raw / 1_000_000) }
            if raw >= 100_000 { return Double(raw / 1000) }
            return nil
        }
    }

    /// Share of time a state channel spent outside its idle states and the residency-weighted
    /// frequency while active. Active states are matched to `table` by the index in their name
    /// ("V3P2" -> 3) or, when the name carries none, by their position among the active states.
    static func activity(states: [(name: String, residency: Int64)], table: [Double]) -> (active: Double, frequency: Double?)? {
        let total = states.reduce(Int64(0)) { $0 + $1.residency }
        guard total > 0 else { return nil }
        var activeTime: Int64 = 0
        var weighted = 0.0
        var position = 0
        for state in states where !["OFF", "IDLE", "DOWN"].contains(state.name) {
            defer { position += 1 }
            activeTime += state.residency
            var index = position
            if state.name.hasPrefix("V"), let named = Int(state.name.dropFirst().prefix(while: \.isNumber)) { index = named }
            if table.indices.contains(index) { weighted += table[index] * Double(state.residency) }
        }
        return (Double(activeTime) / Double(total) * 100,
                activeTime > 0 && weighted > 0 ? weighted / Double(activeTime) : nil)
    }

    static func joules(_ value: Int64, unit: String) -> Double? {
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "mJ": Double(value) / 1e3
        case "uJ": Double(value) / 1e6
        case "nJ": Double(value) / 1e9
        default: nil
        }
    }
}

/// What `PowerReader` measured between two calls.
struct PowerReading {
    var cpuPower: Double?
    var gpuPower: Double?
    /// The fastest CPU cluster (performance cores up to the M4, super cores from the M5 on).
    var fastCluster: (active: Double, frequency: Double?)?
    /// The other CPU cluster (efficiency cores up to the M4, performance cores from the M5 on).
    var secondCluster: (active: Double, frequency: Double?)?
    var gpuFrequency: Double?
}

/// Reads CPU and GPU power, CPU cluster activity and clock frequencies from IOReport.
/// Works without administrator rights.
///
/// GPU power comes from the "GPU Energy" counter. The CPU counter reads zero on macOS 27,
/// so CPU power falls back to the per-cluster power histograms, which makes it an estimate.
final class PowerReader {
    /// Frequency tables of the power manager, by cluster.
    private var fastTable: [Double] = []
    private var secondTable: [Double] = []
    private var efficiencyTable: [Double] = []
    private var gpuTable: [Double] = []

    private let api: IOReportFunctions
    private let subscription: CFTypeRef
    private let channels: CFMutableDictionary
    private var previous: (sample: CFDictionary, date: Date)?
    /// Once the CPU energy counter has read zero while the histograms showed power,
    /// keep using the histograms so the figure does not flip between the two sources.
    private var cpuCounterGated = false

    init?() {
        guard let api = IOReportFunctions.shared else { return nil }
        self.api = api
        guard let energy = api.copyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
              let merged = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, energy) else { return nil }
        // Some chips keep the histograms in "PMP", others in per-die groups "PMP0", "PMP1", ...
        for group in ["PMP"] + (0..<8).map({ "PMP\($0)" }) {
            guard let found = api.copyChannelsInGroup(group as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
                  let all = (found as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { continue }
            // The PMP groups hold hundreds of channels; subscribe only to the ones that are read.
            let wanted = all.filter { channel in
                PowerChannels.isCPUPowerHistogram(
                    subgroup: api.channelGetSubGroup(channel)?.takeUnretainedValue() as String? ?? "",
                    name: api.channelGetChannelName(channel)?.takeUnretainedValue() as String? ?? "")
            }
            guard !wanted.isEmpty, let filtered = (found as NSDictionary).mutableCopy() as? NSMutableDictionary else { continue }
            filtered["IOReportChannels"] = wanted
            api.mergeChannels(merged, filtered, nil)
        }
        // Performance-state residencies of the CPU clusters and the GPU.
        for (group, subgroup) in [("CPU Stats", "CPU Complex Performance States"), ("GPU Stats", "GPU Performance States")] {
            if let found = api.copyChannelsInGroup(group as CFString, subgroup as CFString, 0, 0, 0)?.takeRetainedValue() {
                api.mergeChannels(merged, found, nil)
            }
        }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = api.createSubscription(nil, merged, &subscribed, 0, nil)?.takeRetainedValue()
        else { return nil }
        self.subscription = subscription
        channels = merged
        loadFrequencyTables()
    }

    /// The table numbers are undocumented; this is the assignment mactop uses.
    private func loadFrequencyTables() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var name = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS, String(cString: name) == "pmgr" else { continue }
            func table(_ keys: String...) -> [Double] {
                for key in keys {
                    if let data = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? Data {
                        let frequencies = PowerChannels.frequencies(fromTable: data)
                        if !frequencies.isEmpty { return frequencies }
                    }
                }
                return []
            }
            fastTable = table("voltage-states5-sram")
            secondTable = table("voltage-states22-sram", "voltage-states23-sram", "voltage-states3-sram")
            efficiencyTable = table("voltage-states1-sram")
            gpuTable = table("voltage-states9-sram", "voltage-states9")
        }
    }

    /// Averages since the previous call; nil on the first call.
    func read(at date: Date) -> PowerReading? {
        guard let sample = api.createSamples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        defer { previous = (sample, date) }
        guard let previous, date > previous.date,
              let delta = api.createSamplesDelta(previous.sample, sample, nil)?.takeRetainedValue(),
              let items = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return nil }
        let seconds = date.timeIntervalSince(previous.date)

        var cpuTotal = 0.0, cpuClusters = 0.0, gpu = 0.0, gpuAlias = 0.0
        var histograms: [String: Double] = [:]
        var reading = PowerReading()
        var secondClusters: [(active: Double, frequency: Double?)] = []
        for item in items {
            let group = api.channelGetGroup(item)?.takeUnretainedValue() as String? ?? ""
            let name = api.channelGetChannelName(item)?.takeUnretainedValue() as String? ?? ""
            if group == "Energy Model" {
                let unit = api.channelGetUnitLabel(item)?.takeUnretainedValue() as String? ?? ""
                guard let joules = PowerChannels.joules(api.simpleGetIntegerValue(item, 0), unit: unit),
                      joules >= 0 else { continue }
                let watts = joules / seconds
                if name.contains("ECPU Energy") || name.contains("PCPU Energy") || name.contains("MCPU Energy") {
                    cpuClusters += watts
                } else if name.contains("CPU Energy") {
                    cpuTotal += watts
                } else if name == "GPU Energy" {
                    gpu += watts
                } else if name == "GPU" {
                    gpuAlias += watts
                }
            } else if group == "CPU Stats" || group == "GPU Stats" {
                let count = api.stateGetCount(item)
                guard count > 1 else { continue }
                let states = (0..<count).map {
                    (name: api.stateGetNameForIndex(item, $0)?.takeUnretainedValue() as String? ?? "",
                     residency: api.stateGetResidency(item, $0))
                }
                if group == "GPU Stats" {
                    if name == "GPUPH" { reading.gpuFrequency = PowerChannels.activity(states: states, table: gpuTable)?.frequency }
                } else if name.contains("MCPU") {
                    // From the M5 on: the performance tier, one channel per cluster.
                    if let activity = PowerChannels.activity(states: states, table: secondTable.isEmpty ? fastTable : secondTable) {
                        secondClusters.append(activity)
                    }
                } else if name.contains("ECPU") {
                    if let activity = PowerChannels.activity(states: states, table: efficiencyTable) { secondClusters.append(activity) }
                } else if name.contains("PCPU") {
                    // Several dies each report a cluster; keep the busiest.
                    if let activity = PowerChannels.activity(states: states, table: fastTable),
                       activity.active >= reading.fastCluster?.active ?? -1 {
                        reading.fastCluster = activity
                    }
                }
            } else if group.hasPrefix("PMP") {
                let subgroup = api.channelGetSubGroup(item)?.takeUnretainedValue() as String? ?? ""
                let count = api.stateGetCount(item)
                guard count > 1, PowerChannels.isCPUPowerHistogram(subgroup: subgroup, name: name) else { continue }
                let states = 0..<count
                let watts = PowerChannels.weightedAverage(
                    bins: states.map { PowerChannels.binValue(api.stateGetNameForIndex(item, $0)?.takeUnretainedValue() as String? ?? "") },
                    residency: states.map { api.stateGetResidency(item, $0) })
                // A channel merged into the subscription twice must count once.
                let key = group + "/" + name
                histograms[key] = max(histograms[key] ?? 0, watts)
            }
        }

        var cpu = cpuTotal > 0 ? cpuTotal : cpuClusters
        let estimated = histograms.values.reduce(0, +)
        if cpu <= 0, estimated > 0 { cpuCounterGated = true }
        if cpuCounterGated { cpu = estimated }
        reading.cpuPower = cpu > 0 || cpuCounterGated ? cpu : nil
        reading.gpuPower = gpu > 0 ? gpu : gpuAlias
        if !secondClusters.isEmpty {
            // Activity is averaged across the clusters of the tier; the frequency shown is the highest.
            reading.secondCluster = (secondClusters.map(\.active).reduce(0, +) / Double(secondClusters.count),
                                     secondClusters.compactMap(\.frequency).max())
        }
        return reading
    }
}
