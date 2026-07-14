import CryptoKit
import Foundation

public enum MetadataLocation {
    static func centralizedURL(for fileURL: URL, kind: String) -> URL {
        let identity = resolveIdentity(for: fileURL)
        updateIndex(for: fileURL, identity: identity)
        return metadataDirectory()
            .appendingPathComponent(identity + ".\(kind).json")
    }

    /// Resolves the metadata identity for a file, keyed PRIMARILY BY PATH.
    ///
    /// Path-primary (not inode-primary) is deliberate: saving rewrites the file with a
    /// fresh inode on APFS (AtomicFileWriter/replaceItemAt), so an inode-keyed identity
    /// would orphan all view/schema metadata on every single save. The path is stable
    /// across an in-place save.
    ///
    /// To survive rename/move (where the path changes but the file is "the same"), we
    /// migrate: if no record exists for the current path, look through the index for a
    /// record whose stored security-scoped bookmark now resolves to this same path, and
    /// rename its metadata files onto the new path identity.
    private static func resolveIdentity(for fileURL: URL) -> String {
        let identity = pathIdentity(for: fileURL)
        let metaExists = FileManager.default.fileExists(atPath: metadataURL(identity: identity, kind: "views").path)
            || FileManager.default.fileExists(atPath: metadataURL(identity: identity, kind: "schema").path)
        if metaExists { return identity }
        migrateFromMovedFile(to: fileURL, newIdentity: identity)
        return identity
    }

    /// If some indexed record's bookmark resolves to `fileURL` (the file was renamed or
    /// moved), rename that record's metadata files onto the new path identity so the
    /// remembered view state follows the file.
    private static func migrateFromMovedFile(to fileURL: URL, newIdentity: String) {
        let index = loadIndex()
        let fm = FileManager.default
        let targetPath = fileURL.standardizedFileURL.path
        for (oldIdentity, record) in index.files where oldIdentity != newIdentity {
            guard let b64 = record.bookmarkBase64, let data = Data(base64Encoded: b64) else { continue }
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: data, options: .withoutUI, bookmarkDataIsStale: &stale),
                  resolved.standardizedFileURL.path == targetPath else { continue }
            for kind in ["views", "schema"] {
                let from = metadataURL(identity: oldIdentity, kind: kind)
                let to = metadataURL(identity: newIdentity, kind: kind)
                guard fm.fileExists(atPath: from.path) else { continue }
                try? fm.removeItem(at: to)
                try? fm.moveItem(at: from, to: to)
            }
            return
        }
    }

    static func ensureMetadataDirectory() throws {
        try FileManager.default.createDirectory(at: metadataDirectory(), withIntermediateDirectories: true)
    }

    /// Walk the index and remove entries whose source files no longer exist.
    /// Call once on app launch — cheap (one stat per entry; index is tiny).
    public static func pruneOrphans() {
        var index = loadIndex()
        let fm = FileManager.default
        var removed = false
        for (identity, record) in index.files {
            let exists = fileExists(record: record)
            if !exists {
                try? fm.removeItem(at: metadataURL(identity: identity, kind: "views"))
                try? fm.removeItem(at: metadataURL(identity: identity, kind: "schema"))
                index.files.removeValue(forKey: identity)
                removed = true
            }
        }
        if removed { saveIndex(index) }
    }

    private static func fileExists(record: MetadataFileRecord) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: record.lastKnownPath) { return true }
        if let b64 = record.bookmarkBase64,
           let data = Data(base64Encoded: b64) {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: data, options: .withoutUI,
                                        bookmarkDataIsStale: &stale),
               !stale, fm.fileExists(atPath: resolved.path) {
                return true
            }
        }
        return false
    }

    private static func metadataURL(identity: String, kind: String) -> URL {
        metadataDirectory().appendingPathComponent("\(identity).\(kind).json")
    }

    private static func updateIndex(for fileURL: URL, identity: String) {
        do {
            try ensureMetadataDirectory()
            var index = loadIndex()
            let bookmark = try? fileURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let record = MetadataFileRecord(
                id: identity,
                fileName: fileURL.lastPathComponent,
                lastKnownPath: fileURL.standardizedFileURL.path,
                bookmarkBase64: bookmark?.base64EncodedString(),
                updatedAt: ISO8601DateFormatter().string(from: Date())
            )
            // Skip the disk write when nothing but the timestamp would change —
            // centralizedURL runs on every metadata load/save, so this path is hot.
            if let existing = index.files[identity],
               existing.fileName == record.fileName,
               existing.lastKnownPath == record.lastKnownPath,
               existing.bookmarkBase64 == record.bookmarkBase64 {
                return
            }
            index.files[identity] = record
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

    private static func pathIdentity(for fileURL: URL) -> String {
        "path-" + sha256(fileURL.standardizedFileURL.path)
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
