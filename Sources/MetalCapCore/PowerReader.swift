import Foundation

// IOReport is a private framework; these are the entry points power tools such as mactop use.
@_silgen_name("IOReportCopyChannelsInGroup")
private func IOReportCopyChannelsInGroup(_ group: CFString?, _ subgroup: CFString?, _ a: UInt64, _ b: UInt64, _ c: UInt64) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportMergeChannels")
private func IOReportMergeChannels(_ into: CFMutableDictionary, _ other: CFDictionary, _ unused: CFTypeRef?)
@_silgen_name("IOReportCreateSubscription")
private func IOReportCreateSubscription(_ a: UnsafeRawPointer?, _ channels: CFMutableDictionary, _ subscribed: UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, _ id: UInt64, _ b: CFTypeRef?) -> Unmanaged<AnyObject>?
@_silgen_name("IOReportCreateSamples")
private func IOReportCreateSamples(_ subscription: AnyObject, _ channels: CFMutableDictionary?, _ unused: CFTypeRef?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportCreateSamplesDelta")
private func IOReportCreateSamplesDelta(_ previous: CFDictionary, _ current: CFDictionary, _ unused: CFTypeRef?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportChannelGetGroup")
private func IOReportChannelGetGroup(_ channel: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportChannelGetSubGroup")
private func IOReportChannelGetSubGroup(_ channel: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportChannelGetChannelName")
private func IOReportChannelGetChannelName(_ channel: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportChannelGetUnitLabel")
private func IOReportChannelGetUnitLabel(_ channel: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportSimpleGetIntegerValue")
private func IOReportSimpleGetIntegerValue(_ channel: CFDictionary, _ index: Int32) -> Int64
@_silgen_name("IOReportStateGetCount")
private func IOReportStateGetCount(_ channel: CFDictionary) -> Int32
@_silgen_name("IOReportStateGetNameForIndex")
private func IOReportStateGetNameForIndex(_ channel: CFDictionary, _ index: Int32) -> Unmanaged<CFString>?
@_silgen_name("IOReportStateGetResidency")
private func IOReportStateGetResidency(_ channel: CFDictionary, _ index: Int32) -> Int64

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

    static func joules(_ value: Int64, unit: String) -> Double? {
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "mJ": Double(value) / 1e3
        case "uJ": Double(value) / 1e6
        case "nJ": Double(value) / 1e9
        default: nil
        }
    }
}

/// Reads CPU and GPU power from IOReport. Works without administrator rights.
///
/// GPU power comes from the "GPU Energy" counter. The CPU counter reads zero on macOS 27,
/// so CPU power falls back to the per-cluster power histograms, which makes it an estimate.
final class PowerReader {
    private let subscription: AnyObject
    private let channels: CFMutableDictionary
    private var previous: (sample: CFDictionary, date: Date)?
    /// Once the CPU energy counter has read zero while the histograms showed power,
    /// keep using the histograms so the figure does not flip between the two sources.
    private var cpuCounterGated = false

    init?() {
        guard let energy = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
              let merged = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, energy) else { return nil }
        // Some chips keep the histograms in "PMP", others in per-die groups "PMP0", "PMP1", ...
        for group in ["PMP"] + (0..<8).map({ "PMP\($0)" }) {
            guard let found = IOReportCopyChannelsInGroup(group as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
                  let all = (found as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { continue }
            // The PMP groups hold hundreds of channels; subscribe only to the ones that are read.
            let wanted = all.filter { channel in
                PowerChannels.isCPUPowerHistogram(
                    subgroup: IOReportChannelGetSubGroup(channel)?.takeUnretainedValue() as String? ?? "",
                    name: IOReportChannelGetChannelName(channel)?.takeUnretainedValue() as String? ?? "")
            }
            guard !wanted.isEmpty, let filtered = (found as NSDictionary).mutableCopy() as? NSMutableDictionary else { continue }
            filtered["IOReportChannels"] = wanted
            IOReportMergeChannels(merged, filtered, nil)
        }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = IOReportCreateSubscription(nil, merged, &subscribed, 0, nil)?.takeRetainedValue()
        else { return nil }
        self.subscription = subscription
        channels = merged
    }

    /// Average power since the previous call, in watts; nil on the first call.
    func read(at date: Date) -> (cpu: Double?, gpu: Double?)? {
        guard let sample = IOReportCreateSamples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        defer { previous = (sample, date) }
        guard let previous, date > previous.date,
              let delta = IOReportCreateSamplesDelta(previous.sample, sample, nil)?.takeRetainedValue(),
              let items = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return nil }
        let seconds = date.timeIntervalSince(previous.date)

        var cpuTotal = 0.0, cpuClusters = 0.0, gpu = 0.0, gpuAlias = 0.0
        var histograms: [String: Double] = [:]
        for item in items {
            let group = IOReportChannelGetGroup(item)?.takeUnretainedValue() as String? ?? ""
            let name = IOReportChannelGetChannelName(item)?.takeUnretainedValue() as String? ?? ""
            if group == "Energy Model" {
                let unit = IOReportChannelGetUnitLabel(item)?.takeUnretainedValue() as String? ?? ""
                guard let joules = PowerChannels.joules(IOReportSimpleGetIntegerValue(item, 0), unit: unit),
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
            } else if group.hasPrefix("PMP") {
                let subgroup = IOReportChannelGetSubGroup(item)?.takeUnretainedValue() as String? ?? ""
                let count = IOReportStateGetCount(item)
                guard count > 1, PowerChannels.isCPUPowerHistogram(subgroup: subgroup, name: name) else { continue }
                let states = 0..<count
                let watts = PowerChannels.weightedAverage(
                    bins: states.map { PowerChannels.binValue(IOReportStateGetNameForIndex(item, $0)?.takeUnretainedValue() as String? ?? "") },
                    residency: states.map { IOReportStateGetResidency(item, $0) })
                // A channel merged into the subscription twice must count once.
                let key = group + "/" + name
                histograms[key] = max(histograms[key] ?? 0, watts)
            }
        }

        var cpu = cpuTotal > 0 ? cpuTotal : cpuClusters
        let estimated = histograms.values.reduce(0, +)
        if cpu <= 0, estimated > 0 { cpuCounterGated = true }
        if cpuCounterGated { cpu = estimated }
        let gpuPower = gpu > 0 ? gpu : gpuAlias
        return (cpu > 0 || cpuCounterGated ? cpu : nil, gpuPower)
    }
}
