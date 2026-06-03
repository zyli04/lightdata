import CryptoKit
import Foundation

enum MetadataLocation {
    static func centralizedURL(for fileURL: URL, kind: String) -> URL {
        updateIndex(for: fileURL)
        return metadataDirectory()
            .appendingPathComponent(fileIdentity(for: fileURL) + ".\(kind).json")
    }

    static func ensureMetadataDirectory() throws {
        try FileManager.default.createDirectory(at: metadataDirectory(), withIntermediateDirectories: true)
    }

    private static func updateIndex(for fileURL: URL) {
        do {
            try ensureMetadataDirectory()
            var index = loadIndex()
            let identity = fileIdentity(for: fileURL)
            let bookmark = try? fileURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            index.files[identity] = MetadataFileRecord(
                id: identity,
                fileName: fileURL.lastPathComponent,
                lastKnownPath: fileURL.standardizedFileURL.path,
                bookmarkBase64: bookmark?.base64EncodedString(),
                updatedAt: ISO8601DateFormatter().string(from: Date())
            )
            saveIndex(index)
        } catch {
            NSLog("LightData metadata index update failed: \(error.localizedDescription)")
        }
    }

    private static func metadataDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("LightData", isDirectory: true)
            .appendingPathComponent("Metadata", isDirectory: true)
    }

    private static func fileIdentity(for fileURL: URL) -> String {
        if let resourceID = resourceIdentifier(for: fileURL) {
            return "resource-" + sha256(resourceID)
        }
        let path = fileURL.standardizedFileURL.path
        return "path-" + sha256(path)
    }

    private static func resourceIdentifier(for fileURL: URL) -> String? {
        guard let values = try? fileURL.resourceValues(forKeys: [.fileResourceIdentifierKey]),
              let identifier = values.fileResourceIdentifier else {
            return nil
        }
        return String(describing: identifier)
    }

    private static func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func indexURL() -> URL {
        metadataDirectory().appendingPathComponent("index.json")
    }

    private static func loadIndex() -> MetadataIndex {
        let url = indexURL()
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(MetadataIndex.self, from: data) else {
            return MetadataIndex()
        }
        return index
    }

    private static func saveIndex(_ index: MetadataIndex) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(index)
            try data.write(to: indexURL(), options: [.atomic])
        } catch {
            NSLog("LightData metadata index save failed: \(error.localizedDescription)")
        }
    }
}

private struct MetadataIndex: Codable {
    var files: [String: MetadataFileRecord] = [:]
}

private struct MetadataFileRecord: Codable {
    var id: String
    var fileName: String
    var lastKnownPath: String
    var bookmarkBase64: String?
    var updatedAt: String
}
