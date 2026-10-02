import Foundation

/// Frame statistics computed the same way CapFrameX does
/// (CapFrameX.Statistics.NetStandard/FrametimeStatisticProvider.cs).
public enum Statistics {
    /// R-8 quantile of `values`, matching MathNet.Numerics `Quantile`, which CapFrameX uses.
    public static func quantile(_ values: [Double], _ tau: Double) -> Double {
        guard !values.isEmpty, tau >= 0, tau <= 1 else { return .nan }
        return quantile(sorted: values.sorted(), tau)
    }

    static func quantile(sorted data: [Double], _ tau: Double) -> Double {
        let h = (Double(data.count) + 1.0 / 3.0) * tau + 1.0 / 3.0
        let hf = Int(h)
        if hf < 1 { return data[0] }
        if hf >= data.count { return data[data.count - 1] }
        return data[hf - 1] + (h - Double(hf)) * (data[hf] - data[hf - 1])
    }

    /// Average FPS: frame count over total time, not the mean of per-frame FPS values.
    public static func averageFPS(frameTimes: [Double]) -> Double {
        let total = frameTimes.reduce(0, +)
        guard total > 0 else { return .nan }
        return Double(frameTimes.count) * 1000 / total
    }

    /// "x% low average": mean of the frame times at or above the `quantile` frame time.
    public static func percentageHighAverage(frameTimes: [Double], quantile q: Double) -> Double {
        guard !frameTimes.isEmpty else { return .nan }
        let threshold = quantile(frameTimes, q)
        let slow = frameTimes.filter { $0 >= threshold }
        return slow.reduce(0, +) / Double(slow.count)
    }

    /// "x% low integral" (MSI Afterburner definition): walk the slowest frames until they
    /// add up to `1 - quantile` of the total time and return the frame time reached.
    public static func percentageHighIntegral(frameTimes: [Double], quantile q: Double) -> Double {
        guard !frameTimes.isEmpty else { return .nan }
        let descending = frameTimes.sorted(by: >)
        let lowTime = descending.reduce(0, +) * (1 - q)
        var sum = 0.0
        var index = 0
        for (i, frameTime) in descending.enumerated() {
            sum += frameTime
            index = i
            if sum >= lowTime { break }
        }
        return descending[index]
    }
}

public struct FrameMetrics: Equatable, Sendable {
    public var frameCount: Int
    /// Total capture time in seconds.
    public var duration: Double
    public var average: Double
    public var median: Double
    public var max: Double
    public var min: Double
    public var p99: Double
    public var p95: Double
    public var p5: Double
    public var p1: Double
    public var p0_2: Double
    public var p0_1: Double
    public var onePercentLowAverage: Double
    public var pointOnePercentLowAverage: Double
    public var onePercentLowIntegral: Double
    public var pointOnePercentLowIntegral: Double

    /// - Parameter frameTimes: frame times in milliseconds; non-positive values are ignored.
    public init?(frameTimes raw: [Double]) {
        let frameTimes = raw.filter { $0 > 0 && $0.isFinite }
        guard !frameTimes.isEmpty else { return nil }
        let fps = frameTimes.map { 1000 / $0 }.sorted()

        frameCount = frameTimes.count
        duration = frameTimes.reduce(0, +) / 1000
        average = Statistics.averageFPS(frameTimes: frameTimes)
        median = Statistics.quantile(sorted: fps, 0.5)
        max = fps[fps.count - 1]
        min = fps[0]
        p99 = Statistics.quantile(sorted: fps, 0.99)
        p95 = Statistics.quantile(sorted: fps, 0.95)
        p5 = Statistics.quantile(sorted: fps, 0.05)
        p1 = Statistics.quantile(sorted: fps, 0.01)
        p0_2 = Statistics.quantile(sorted: fps, 0.002)
        p0_1 = Statistics.quantile(sorted: fps, 0.001)
        onePercentLowAverage = 1000 / Statistics.percentageHighAverage(frameTimes: frameTimes, quantile: 0.99)
        pointOnePercentLowAverage = 1000 / Statistics.percentageHighAverage(frameTimes: frameTimes, quantile: 0.999)
        onePercentLowIntegral = 1000 / Statistics.percentageHighIntegral(frameTimes: frameTimes, quantile: 0.99)
        pointOnePercentLowIntegral = 1000 / Statistics.percentageHighIntegral(frameTimes: frameTimes, quantile: 0.999)
    }
}
