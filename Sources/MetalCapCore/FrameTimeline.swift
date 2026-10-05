import Foundation

/// One point of the frame time chart.
public struct FramePoint: Equatable, Sendable {
    /// Index of the frame in the capture.
    public let index: Int
    /// Seconds since the start of the capture, at the end of this frame.
    public let time: Double
    /// Frame time in milliseconds.
    public let frameTime: Double
}

public enum FrameTimeline {
    /// One point per frame; long captures are reduced to the slowest frame of each bucket
    /// so stutters stay visible however many frames there are.
    public static func points(frameTimes: [Double], limit: Int = 3000) -> [FramePoint] {
        guard !frameTimes.isEmpty, limit > 0 else { return [] }
        let bucket = max(1, Int((Double(frameTimes.count) / Double(limit)).rounded(.up)))
        var points: [FramePoint] = []
        points.reserveCapacity(frameTimes.count / bucket + 1)
        var elapsed = 0.0
        var slowest: FramePoint?
        for (index, frameTime) in frameTimes.enumerated() {
            elapsed += frameTime / 1000
            if slowest == nil || frameTime > slowest!.frameTime {
                slowest = FramePoint(index: index, time: elapsed, frameTime: frameTime)
            }
            if (index + 1) % bucket == 0 || index == frameTimes.count - 1 {
                points.append(slowest!)
                slowest = nil
            }
        }
        return points
    }
}
