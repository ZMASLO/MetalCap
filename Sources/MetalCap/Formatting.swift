import Foundation

func fps(_ value: Double) -> String {
    value.isFinite ? String(format: "%.1f", value) : "–"
}

func formatted(_ date: Date, date dateStyle: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
    date.formatted(Date.FormatStyle(date: dateStyle, time: time).locale(L10n.language.locale))
}

/// Value formats shared by the system tiles and the timeline.
enum MetricFormat {
    static func megabytes(_ value: Double) -> String {
        value >= 1024 ? String(format: "%.1f GB", value / 1024) : String(format: "%.0f MB", value)
    }

    static func percent(_ value: Double) -> String { String(format: "%.0f%%", value) }
    static func degrees(_ value: Double) -> String { String(format: "%.0f°C", value) }
    static func megahertz(_ value: Double) -> String { String(format: "%.0f MHz", value) }
    static func rpm(_ value: Double) -> String { String(format: "%.0f", value) }
    static func watts(_ value: Double) -> String { String(format: value < 10 ? "%.1f W" : "%.0f W", value) }
}
