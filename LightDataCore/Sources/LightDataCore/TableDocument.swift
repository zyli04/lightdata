import Foundation

public enum TableFileFormat: Equatable {
    case csv
    case tsv
    case json
    case jsonl
    case xlsx
    case parquet

    public var displayName: String {
        switch self {
        case .csv: "CSV"
        case .tsv: "TSV"
        case .json: "JSON"
        case .jsonl: "JSONL"
        case .xlsx: "XLSX"
        case .parquet: "Parquet"
        }
    }

    public var delimiter: Character? {
        switch self {
        case .csv: ","
        case .tsv: "\t"
        default: nil
        }
    }

    public var fileExtension: String {
        switch self {
        case .csv: "csv"
        case .tsv: "tsv"
        case .json: "json"
        case .jsonl: "jsonl"
        case .xlsx: "xlsx"
        case .parquet: "parquet"
        }
    }

    /// Formats LightData can write to via "Save As". XLSX/Parquet writing is not
    /// supported yet, so they are intentionally excluded.
    public static let writableFormats: [TableFileFormat] = [.csv, .tsv, .json, .jsonl]
}

public enum DelimiterKind: Codable, Equatable {
    case comma
    case tab
    case semicolon
    case pipe
    case custom(String)
    case none

    public init(character: Character?) {
        switch character {
        case ",": self = .comma
        case "\t": self = .tab
        case ";": self = .semicolon
        case "|": self = .pipe
        case let character?: self = .custom(String(character))
        case nil: self = .none
        }
    }

    public var character: Character? {
        switch self {
        case .comma: ","
        case .tab: "\t"
        case .semicolon: ";"
        case .pipe: "|"
        case .custom(let value): value.first
        case .none: nil
        }
    }

    public var displayName: String {
        switch self {
        case .comma: "Comma"
        case .tab: "Tab"
        case .semicolon: "Semicolon"
        case .pipe: "Pipe"
        case .custom(let value): "Custom \(value)"
        case .none: "-"
        }
    }
}

public struct FileOpenInfo: Codable, Equatable {
    public var encoding: TextEncodingKind?
    public var lineEnding: LineEnding?
    public var delimiter: DelimiterKind
    public var readOnlyReason: String?

    public init(encoding: TextEncodingKind?, lineEnding: LineEnding?, delimiter: DelimiterKind, readOnlyReason: String?) {
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.delimiter = delimiter
        self.readOnlyReason = readOnlyReason
    }

    public var displaySummary: String {
        var parts: [String] = []
        if let encoding {
            parts.append(encoding.displayName)
        }
        if let lineEnding {
            parts.append(lineEnding.displayName)
        }
        if delimiter != .none {
            parts.append(delimiter.displayName)
        }
        if let readOnlyReason {
            parts.append(readOnlyReason)
        }
        return parts.joined(separator: " - ")
    }
}

public enum TableDocumentError: LocalizedError {
    case unsupportedFile(URL)
    case emptyFile
    case saveUnsupported(String)
    case invalidJSON
    case invalidParquet(String)
    case fileChangedExternally(URL)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile(let url):
            "Unsupported file type: \(url.lastPathComponent)"
        case .emptyFile:
            "The file does not contain table data."
        case .saveUnsupported(let reason):
            reason
        case .invalidJSON:
            "JSON must be an array of objects or JSON Lines object records."
        case .invalidParquet(let reason):
            "Could not read Parquet file: \(reason)"
        case .fileChangedExternally(let url):
            "\(url.lastPathComponent) was modified outside LightData after it was opened. Reopen the file before saving to avoid overwriting newer changes."
        }
    }
}

public struct TableDocument {
    public let url: URL
    public let format: TableFileFormat
    public var headers: [String]
    public var rows: [[String]]
    public var readOnly: Bool
    public var dirty: Bool = false
    public var sheetName: String?
    public var openInfo: FileOpenInfo
    public var loadedModificationDate: Date?

    public var rowCount: Int { rows.count }
    public var columnCount: Int { headers.count }
    public var canEditFormat: Bool { !readOnly }

    /// Builds a header-only, read-only document for the lazy/paged path: row data is
    /// served on demand by a `DuckDBTableSource` rather than held in `rows`. Reuses the
    /// same model so UI code can keep reading url/format/headers/openInfo uniformly.
    public static func lazyHeaderOnly(url: URL, format: TableFileFormat, headers: [String], readOnlyReason: String) -> TableDocument {
        TableDocument(
            url: url,
            format: format,
            headers: headers,
            rows: [],
            readOnly: true,
            openInfo: FileOpenInfo(encoding: nil, lineEnding: nil, delimiter: .none, readOnlyReason: readOnlyReason),
            loadedModificationDate: modificationDate(for: url)
        )
    }

    public static func load(url: URL, delimiterOverride: Character? = nil) throws -> TableDocument {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "csv":
            let table = try delimiterOverride.map { try DelimitedTextParser.read(url: url, delimiter: $0) } ?? DelimitedTextParser.readAuto(url: url)
            return TableDocument(url: url, format: .csv, headers: table.headers, rows: table.rows, readOnly: false, openInfo: table.openInfo, loadedModificationDate: modificationDate(for: url))
        case "tsv", "tab":
            let table = try DelimitedTextParser.read(url: url, delimiter: delimiterOverride ?? "\t")
            return TableDocument(url: url, format: .tsv, headers: table.headers, rows: table.rows, readOnly: false, openInfo: table.openInfo, loadedModificationDate: modificationDate(for: url))
        case "json":
            let table = try JSONTableParser.readJSON(url: url)
            return TableDocument(url: url, format: .json, headers: table.headers, rows: table.rows, readOnly: false, openInfo: table.openInfo, loadedModificationDate: modificationDate(for: url))
        case "jsonl", "ndjson":
            let table = try JSONTableParser.readJSONLines(url: url)
            return TableDocument(url: url, format: .jsonl, headers: table.headers, rows: table.rows, readOnly: false, openInfo: table.openInfo, loadedModificationDate: modificationDate(for: url))
        case "xlsx":
            let table = try XLSXReader.readFirstSheet(url: url)
            return TableDocument(url: url, format: .xlsx, headers: table.headers, rows: table.rows, readOnly: true, sheetName: table.sheetName, openInfo: table.openInfo, loadedModificationDate: modificationDate(for: url))
        case "parquet", "pq":
            let table = try ParquetReader.read(url: url)
            return TableDocument(url: url, format: .parquet, headers: table.headers, rows: table.rows, readOnly: true, openInfo: table.openInfo, loadedModificationDate: modificationDate(for: url))
        default:
            throw TableDocumentError.unsupportedFile(url)
        }
    }

    public mutating func setValue(_ value: String, row: Int, column: Int) {
        guard !readOnly, rows.indices.contains(row), headers.indices.contains(column) else { return }
        while rows[row].count < headers.count {
            rows[row].append("")
        }
        if rows[row][column] != value {
            rows[row][column] = value
            dirty = true
        }
    }

    public mutating func addRow(after row: Int? = nil) {
        guard !readOnly else { return }
        let newRow = Array(repeating: "", count: headers.count)
        if let row, rows.indices.contains(row) {
            rows.insert(newRow, at: row + 1)
        } else {
            rows.append(newRow)
        }
        dirty = true
    }

    public mutating func deleteRows(_ indexes: IndexSet) {
        guard !readOnly else { return }
        for index in indexes.sorted(by: >) where rows.indices.contains(index) {
            rows.remove(at: index)
        }
        dirty = true
    }

    /// Re-inserts rows at the given document indices (ascending), restoring the
    /// positions captured before a deletion. Used by undo.
    public mutating func insertRows(_ rowsByIndex: [Int: [String]]) {
        guard !readOnly else { return }
        for index in rowsByIndex.keys.sorted() {
            let clamped = min(max(index, 0), rows.count)
            rows.insert(rowsByIndex[index] ?? [], at: clamped)
        }
        dirty = true
    }

    public mutating func moveRows(_ indexes: IndexSet, to target: Int) {
        guard !readOnly else { return }
        let sorted = indexes.sorted().filter { rows.indices.contains($0) }
        guard !sorted.isEmpty else { return }
        let moving = sorted.map { rows[$0] }
        let removedBefore = sorted.filter { $0 < target }.count
        for index in sorted.reversed() {
            rows.remove(at: index)
        }
        let insertAt = min(max(target - removedBefore, 0), rows.count)
        rows.insert(contentsOf: moving, at: insertAt)
        dirty = true
    }

    public mutating func renameColumn(at index: Int, to newName: String) {
        guard !readOnly, headers.indices.contains(index) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        headers[index] = trimmed.isEmpty ? "Column \(index + 1)" : trimmed
        headers = makeUnique(headers)
        dirty = true
    }

    public mutating func deleteColumn(at index: Int) {
        guard !readOnly, headers.indices.contains(index), headers.count > 1 else { return }
        headers.remove(at: index)
        for rowIndex in rows.indices where rows[rowIndex].indices.contains(index) {
            rows[rowIndex].remove(at: index)
        }
        dirty = true
    }

    public mutating func reorderColumns(to order: [Int]) {
        guard !readOnly,
              order.count == headers.count,
              Set(order) == Set(headers.indices) else {
            return
        }
        guard order != Array(headers.indices) else { return }

        headers = order.map { headers[$0] }
        rows = rows.map { row in
            order.map { columnIndex in
                columnIndex < row.count ? row[columnIndex] : ""
            }
        }
        dirty = true
    }

    public mutating func pasteRows(_ pastedRows: [[String]], startingAt startRow: Int, column startColumn: Int) {
        guard !readOnly, !pastedRows.isEmpty, headers.indices.contains(startColumn) else { return }
        while rows.count <= startRow + pastedRows.count - 1 {
            rows.append(Array(repeating: "", count: headers.count))
        }

        for (rowOffset, pastedRow) in pastedRows.enumerated() {
            let rowIndex = startRow + rowOffset
            while rows[rowIndex].count < headers.count {
                rows[rowIndex].append("")
            }
            for (columnOffset, value) in pastedRow.enumerated() {
                let columnIndex = startColumn + columnOffset
                guard headers.indices.contains(columnIndex) else { break }
                rows[rowIndex][columnIndex] = value
            }
        }
        dirty = true
    }

    public mutating func save() throws {
        guard !readOnly else {
            throw TableDocumentError.saveUnsupported("\(format.displayName) is read-only in this MVP.")
        }
        try ensureFileWasNotChangedExternally()

        switch format {
        case .csv:
            try DelimitedTextParser.write(url: url, headers: headers, rows: rows, delimiter: openInfo.delimiter.character ?? ",", encoding: openInfo.encoding ?? .utf8, lineEnding: openInfo.lineEnding ?? .lf)
        case .tsv:
            try DelimitedTextParser.write(url: url, headers: headers, rows: rows, delimiter: openInfo.delimiter.character ?? "\t", encoding: openInfo.encoding ?? .utf8, lineEnding: openInfo.lineEnding ?? .lf)
        case .json:
            try JSONTableParser.writeJSON(url: url, headers: headers, rows: rows, encoding: openInfo.encoding ?? .utf8, lineEnding: openInfo.lineEnding ?? .lf)
        case .jsonl:
            try JSONTableParser.writeJSONLines(url: url, headers: headers, rows: rows, encoding: openInfo.encoding ?? .utf8, lineEnding: openInfo.lineEnding ?? .lf)
        case .xlsx:
            throw TableDocumentError.saveUnsupported("XLSX editing is intentionally disabled in this MVP.")
        case .parquet:
            throw TableDocumentError.saveUnsupported("Parquet editing is intentionally disabled in this MVP.")
        }
        dirty = false
        loadedModificationDate = Self.modificationDate(for: url)
    }

    /// Writes the current table contents to a new location/format without mutating
    /// this document. Used by "Save As". The caller is expected to reload the written
    /// file to obtain a fresh document pointed at the new URL.
    ///
    /// Designed as the single export entry point so it can later be backed by a
    /// streaming DuckDB `COPY` for very large datasets instead of the in-memory rows.
    public func write(to targetURL: URL, as targetFormat: TableFileFormat) throws {
        let encoding = openInfo.encoding ?? .utf8
        let lineEnding = openInfo.lineEnding ?? .lf
        switch targetFormat {
        case .csv:
            try DelimitedTextParser.write(url: targetURL, headers: headers, rows: rows, delimiter: ",", encoding: encoding, lineEnding: lineEnding)
        case .tsv:
            try DelimitedTextParser.write(url: targetURL, headers: headers, rows: rows, delimiter: "\t", encoding: encoding, lineEnding: lineEnding)
        case .json:
            try JSONTableParser.writeJSON(url: targetURL, headers: headers, rows: rows, encoding: encoding, lineEnding: lineEnding)
        case .jsonl:
            try JSONTableParser.writeJSONLines(url: targetURL, headers: headers, rows: rows, encoding: encoding, lineEnding: lineEnding)
        case .xlsx, .parquet:
            throw TableDocumentError.saveUnsupported("Exporting to \(targetFormat.displayName) is not supported yet.")
        }
    }

    private func ensureFileWasNotChangedExternally() throws {
        guard let loadedModificationDate,
              let currentModificationDate = Self.modificationDate(for: url) else {
            return
        }
        if abs(currentModificationDate.timeIntervalSince(loadedModificationDate)) > 0.5 {
            throw TableDocumentError.fileChangedExternally(url)
        }
    }

    private static func modificationDate(for url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}

struct ParsedTable {
    var headers: [String]
    var rows: [[String]]
    var sheetName: String?
    var openInfo = FileOpenInfo(encoding: nil, lineEnding: nil, delimiter: .none, readOnlyReason: nil)
}
