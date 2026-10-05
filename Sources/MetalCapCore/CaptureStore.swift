import Foundation

/// Persists captures as one JSON file each.
public struct CaptureStore {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MetalCap/Captures", isDirectory: true)
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    public func save(_ capture: Capture) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // Keep fractions of a second: `.iso8601` drops them, so a saved capture would not
        // read back equal to the one in memory.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.timestamp(fractionalSeconds: true).string(from: date))
        }
        try encoder.encode(capture).write(to: url(for: capture.id), options: .atomic)
    }

    /// All stored captures, newest first. Unreadable files are skipped.
    public func loadAll() -> [Capture] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        // Files written before fractions were kept have whole seconds.
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = Self.timestamp(fractionalSeconds: true).date(from: text)
                    ?? Self.timestamp(fractionalSeconds: false).date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(text)"))
            }
            return date
        }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Capture.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private static func timestamp(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        if fractionalSeconds { formatter.formatOptions.insert(.withFractionalSeconds) }
        return formatter
    }

    public func delete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: url(for: id))
    }
}
