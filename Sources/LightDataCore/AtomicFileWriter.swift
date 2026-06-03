import Foundation

enum AtomicFileWriter {
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
            try manager.removeItem(at: tempURL)
        }

        try data.write(to: tempURL, options: [.atomic])
        if manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }
        try manager.moveItem(at: tempURL, to: url)
    }
}
