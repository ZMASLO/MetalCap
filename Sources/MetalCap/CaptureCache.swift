import MetalCapCore
import SwiftUI

/// Figures derived from a capture's frames. They are costly for long captures and the frames never
/// change, so they are computed once per capture instead of on every redraw (the shared pointer
/// redraws the whole result view on each mouse move).
@MainActor
final class CaptureCache {
    struct Entry {
        let metrics: FrameMetrics?
        let points: [FramePoint]
        let frameTimeRange: MetricRange?
    }

    static let shared = CaptureCache()
    private var entries: [Capture.ID: Entry] = [:]

    func entry(for capture: Capture) -> Entry {
        if let entry = entries[capture.id] { return entry }
        let entry = Entry(metrics: capture.metrics,
                          points: FrameTimeline.points(frameTimes: capture.frameTimes),
                          frameTimeRange: MetricRange(capture.frameTimes.filter { $0 > 0 }))
        entries[capture.id] = entry
        return entry
    }

    func forget(_ id: Capture.ID) {
        entries[id] = nil
    }
}
