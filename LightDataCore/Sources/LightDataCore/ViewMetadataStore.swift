import Foundation

public struct ViewMetadata: Codable {
    public var columnWidths: [String: Double] = [:]
    public var columnOrder: [String] = []
    public var schemaEnabled: Bool = false
    /// Persisted sort: the column's header name and direction (nil = no sort).
    /// Stored by name (not index) so it survives column reordering.
    public var sortColumnName: String?
    public var sortAscending: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        columnWidths = try container.decodeIfPresent([String: Double].self, forKey: .columnWidths) ?? [:]
        columnOrder = try container.decodeIfPresent([String].self, forKey: .columnOrder) ?? []
        schemaEnabled = try container.decodeIfPresent(Bool.self, forKey: .schemaEnabled) ?? false
        sortColumnName = try container.decodeIfPresent(String.self, forKey: .sortColumnName)
        sortAscending = try container.decodeIfPresent(Bool.self, forKey: .sortAscending) ?? true
    }
}

public enum ViewMetadataStore {
    public static func load(for fileURL: URL) -> ViewMetadata {
        let url = MetadataLocation.centralizedURL(for: fileURL, kind: "views")
        if let data = try? Data(contentsOf: url),
           let metadata = try? JSONDecoder().decode(ViewMetadata.self, from: data) {
            return metadata
        }
        return ViewMetadata()
    }

    public static func save(_ metadata: ViewMetadata, for fileURL: URL) {
        let url = MetadataLocation.centralizedURL(for: fileURL, kind: "views")
        do {
            try MetadataLocation.ensureMetadataDirectory()
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: url, options: [.atomic])
        } catch {
            NSLog("LightData metadata save failed: \(error.localizedDescription)")
        }
    }
}
