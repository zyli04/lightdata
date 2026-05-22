import Foundation

struct ViewMetadata: Codable {
    var columnWidths: [String: Double] = [:]
    var schemaEnabled: Bool = false
}

enum ViewMetadataStore {
    static func load(for fileURL: URL) -> ViewMetadata {
        let url = metadataURL(for: fileURL)
        guard let data = try? Data(contentsOf: url),
              let metadata = try? JSONDecoder().decode(ViewMetadata.self, from: data) else {
            return ViewMetadata()
        }
        return metadata
    }

    static func save(_ metadata: ViewMetadata, for fileURL: URL) {
        let url = metadataURL(for: fileURL)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: url, options: [.atomic])
        } catch {
            NSLog("LightData metadata save failed: \(error.localizedDescription)")
        }
    }

    private static func metadataURL(for fileURL: URL) -> URL {
        fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(".lightdata", isDirectory: true)
            .appendingPathComponent(fileURL.lastPathComponent + ".views.json")
    }
}
