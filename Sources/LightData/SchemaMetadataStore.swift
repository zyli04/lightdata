import Foundation

enum SchemaMetadataStore {
    static func load(for fileURL: URL, headers: [String], rows: [[String]]) -> TableSchema {
        let url = metadataURL(for: fileURL)
        if let data = try? Data(contentsOf: url),
           var schema = try? JSONDecoder().decode(TableSchema.self, from: data) {
            schema.removeMissingColumns(validHeaders: headers)
            return schema
        }
        return TableSchema.inferred(headers: headers, rows: rows)
    }

    static func save(_ schema: TableSchema, for fileURL: URL) {
        let url = metadataURL(for: fileURL)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(schema)
            try data.write(to: url, options: [.atomic])
        } catch {
            NSLog("LightData schema save failed: \(error.localizedDescription)")
        }
    }

    private static func metadataURL(for fileURL: URL) -> URL {
        fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(".lightdata", isDirectory: true)
            .appendingPathComponent(fileURL.lastPathComponent + ".schema.json")
    }
}
