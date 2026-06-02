import Foundation

enum SchemaMetadataStore {
    static func load(for fileURL: URL, headers: [String], rows: [[String]]) -> TableSchema {
        let url = MetadataLocation.centralizedURL(for: fileURL, kind: "schema")
        if let data = try? Data(contentsOf: url),
           var schema = try? JSONDecoder().decode(TableSchema.self, from: data) {
            schema.removeMissingColumns(validHeaders: headers)
            return schema
        }
        return TableSchema.inferred(headers: headers, rows: rows)
    }

    static func save(_ schema: TableSchema, for fileURL: URL) {
        let url = MetadataLocation.centralizedURL(for: fileURL, kind: "schema")
        do {
            try MetadataLocation.ensureMetadataDirectory()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(schema)
            try data.write(to: url, options: [.atomic])
        } catch {
            NSLog("LightData schema save failed: \(error.localizedDescription)")
        }
    }
}
