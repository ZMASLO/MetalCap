import AppKit
import Charts
import MetalCapCore
import SwiftUI

/// Axes shared by the timeline charts. Value labels get a fixed width so every plot area has the
/// same width and the time axes, and the pointer line, line up from chart to chart.
extension View {
    func timelineAxes(showsTimeAxis: Bool) -> some View {
        chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    Text(value.as(Double.self).map { String(format: "%.0f", $0) } ?? "")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .leading)
                }
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine()
                if showsTimeAxis {
                    AxisTick()
                    AxisValueLabel()
                }
            }
        }
    }
}

/// "min · avg · max" for one series, optionally led by the series' colour and name.
struct RangeSummary: View {
    var color: Color?
    var name: String?
    let range: MetricRange
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: 6) {
            if let color { Circle().fill(color).frame(width: 8, height: 8) }
            if let name { Text(name) }
            Text("min \(format(range.minimum)) · \(tr("śr.", "avg")) \(format(range.average)) · \(tr("maks.", "max")) \(format(range.maximum))")
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}


/// One or more metrics over the capture, with a readout under the pointer and
/// each series' lowest, average and highest value underneath.
struct TimeSeriesChart: View {
    struct Point {
        let time: Double
        let value: Double
    }

    struct Series: Identifiable {
        let id: String
        let points: [Point]
    }

    let series: [Series]
    /// Length of the capture in seconds; the time axis spans it so all charts line up.
    let duration: Double
    /// Fixed value axis, or nil to fit the data.
    let range: ClosedRange<Double>?
    let format: (Double) -> String
    /// The moment under the pointer, shared by every chart of the timeline.
    @Binding var hoverTime: Double?
    var height: CGFloat = 90
    var showsTimeAxis = true

    /// Categorical colours in a fixed order, with separate steps for light and dark appearance.
    private static let seriesColors: [Color] = [
        (0x2A78D6, 0x3987E5), (0xEB6834, 0xD95926), (0x1BAF7A, 0x199E70),
    ].map { light, dark in
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    private var fittedRange: ClosedRange<Double> {
        let values = series.flatMap { $0.points.map(\.value) }
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let margin = Swift.max((high - low) * 0.15, high * 0.02, 1)
        return Swift.max(0, low - margin)...(high + margin)
    }

    private func value(of series: Series, at time: Double) -> Double? {
        series.points.min { abs($0.time - time) < abs($1.time - time) }?.value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            chart.frame(height: height)
            // These rows double as the legend.
            ForEach(Array(series.enumerated()), id: \.offset) { index, series in
                if let range = MetricRange(series.points.map(\.value)) {
                    RangeSummary(color: self.series.count > 1 ? Self.seriesColors[index % Self.seriesColors.count] : nil,
                                 name: self.series.count > 1 ? series.id : nil, range: range, format: format)
                }
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(series) { series in
                ForEach(series.points.indices, id: \.self) { index in
                    LineMark(x: .value("Time", series.points[index].time),
                             y: .value("Value", series.points[index].value),
                             series: .value("Series", series.id))
                        .foregroundStyle(by: .value("Series", series.id))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            if let hoverTime {
                RuleMark(x: .value("Time", hoverTime))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text(series.compactMap { series in
                            value(of: series, at: hoverTime).map { value in
                                self.series.count > 1 ? "\(series.id) \(format(value))" : format(value)
                            }
                        }.joined(separator: " · "))
                            .font(.caption)
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.background, in: RoundedRectangle(cornerRadius: 4))
                    }
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.id), range: Self.seriesColors)
        .chartLegend(.hidden)
        .chartXScale(domain: 0...max(duration, 1))
        .chartYScale(domain: range ?? fittedRange)
        .timelineAxes(showsTimeAxis: showsTimeAxis)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let location) = phase, let frame = proxy.plotFrame,
                              let time: Double = proxy.value(atX: location.x - geometry[frame].origin.x),
                              (0...duration).contains(time) else {
                            hoverTime = nil
                            return
                        }
                        hoverTime = time
                    }
            }
        }
    }
}

/// Horizontal bars comparing the headline metrics, as on CapFrameX's analysis page.
struct MetricBarChart: View {
    struct Item: Identifiable {
        let id: String
        let value: Double
    }

    let items: [Item]

    var body: some View {
        Chart(items) { item in
            BarMark(x: .value("FPS", item.value), y: .value("Metric", item.id), height: .fixed(18))
                .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4))
                .annotation(position: .trailing, spacing: 6) {
                    Text(fps(item.value)).font(.callout.weight(.medium)).monospacedDigit()
                }
        }
        // Headroom so the value label of the longest bar is not clipped.
        .chartXScale(domain: 0...((items.map(\.value).filter(\.isFinite).max() ?? 1) * 1.12))
        .chartYAxis {
            AxisMarks(preset: .extended, position: .leading) { _ in AxisValueLabel(centered: true) }
        }
        .frame(height: CGFloat(items.count) * 32 + 24)
    }
}

extension FramePoint: Identifiable {
    public var id: Int { index }
}

struct FrameTimeChart: View {
    typealias Point = FramePoint

    let points: [Point]
    /// Length of the capture in seconds.
    let duration: Double
    /// The moment under the pointer, shared by every chart of the timeline.
    @Binding var hoverTime: Double?
    var showsTimeAxis = true

    private var hovered: Point? { hoverTime.flatMap(nearestPoint) }

    var body: some View {
        Chart {
            ForEach(points) { point in
                LineMark(x: .value("Time", point.time), y: .value("Frame time", point.frameTime))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            if let hovered {
                RuleMark(x: .value("Time", hovered.time))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text("\(String(format: "%.2f", hovered.frameTime)) ms · \(fps(1000 / hovered.frameTime)) FPS")
                            .font(.caption)
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.background, in: RoundedRectangle(cornerRadius: 4))
                    }
                PointMark(x: .value("Time", hovered.time), y: .value("Frame time", hovered.frameTime))
                    .symbolSize(40)
            }
        }
        // Span exactly the capture; the automatic axis rounds up and leaves empty space at the end.
        .chartXScale(domain: 0...max(duration, 1))
        .timelineAxes(showsTimeAxis: showsTimeAxis)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let location) = phase, let frame = proxy.plotFrame,
                              let time: Double = proxy.value(atX: location.x - geometry[frame].origin.x),
                              (0...duration).contains(time) else {
                            hoverTime = nil
                            return
                        }
                        hoverTime = time
                    }
            }
        }
    }

    private func nearestPoint(to time: Double) -> Point? {
        guard let after = points.firstIndex(where: { $0.time >= time }) else { return points.last }
        guard after > 0 else { return points[after] }
        let before = after - 1
        return time - points[before].time < points[after].time - time ? points[before] : points[after]
    }
}
