import Foundation

enum AtomicFileWriter {
    /// Replaces `url`'s contents atomically, preserving as much of the file's metadata
    /// (permissions, extended attributes, Finder tags, creation date) as the platform
    /// allows via `replaceItemAt`.
    ///
    /// Note: on APFS this still assigns a new inode, so callers must NOT assume the
    /// file's resource identifier is stable across a save — view/schema metadata keying
    /// is path-primary for exactly this reason (see MetadataLocation).
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let backupURL = directory.appendingPathComponent(".\(url.lastPathComponent).lightdata-backup")
        let tempURL = directory.appendingPathComponent(".\(url.lastPathComponent).lightdata-tmp")

        let manager = FileManager.default
        if manager.fileExists(atPath: backupURL.path) {
            try? manager.removeItem(at: backupURL)
        }
        if manager.fileExists(atPath: url.path) {
            try manager.copyItem(at: url, to: backupURL)
        }
        if manager.fileExists(atPath: tempURL.path) {
            try? manager.removeItem(at: tempURL)
        }

        try data.write(to: tempURL, options: [.atomic])
        if manager.fileExists(atPath: url.path) {
            // Atomic swap that keeps the destination's file identity and metadata.
            // (withItemAt consumes the temp file.)
            _ = try manager.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try manager.moveItem(at: tempURL, to: url)
        }
    }
}
