import Foundation

enum TableFileFormat: Equatable {
    case csv
    case tsv
    case json
    case jsonl
    case xlsx

    var displayName: String {
        switch self {
        case .csv: "CSV"
        case .tsv: "TSV"
        case .json: "JSON"
        case .jsonl: "JSONL"
        case .xlsx: "XLSX"
        }
    }

    var delimiter: Character? {
        switch self {
        case .csv: ","
        case .tsv: "\t"
        default: nil
        }
    }
}

enum DelimiterKind: Codable, Equatable {
    case comma
    case tab
    case semicolon
    case pipe
    case custom(String)
    case none

    init(character: Character?) {
        switch character {
        case ",": self = .comma
        case "\t": self = .tab
        case ";": self = .semicolon
        case "|": self = .pipe
        case let character?: self = .custom(String(character))
        case nil: self = .none
        }
    }

    var character: Character? {
        switch self {
        case .comma: ","
        case .tab: "\t"
        case .semicolon: ";"
        case .pipe: "|"
        case .custom(let value): value.first
        case .none: nil
        }
    }

    var displayName: String {
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

struct FileOpenInfo: Codable, Equatable {
    var encoding: TextEncodingKind?
    var lineEnding: LineEnding?
    var delimiter: DelimiterKind
    var readOnlyReason: String?

    var displaySummary: String {
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

enum TableDocumentError: LocalizedError {
    case unsupportedFile(URL)
    case emptyFile
    case saveUnsupported(String)
    case invalidJSON
    case fileChangedExternally(URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let url):
            "Unsupported file type: \(url.lastPathComponent)"
        case .emptyFile:
            "The file does not contain table data."
        case .saveUnsupported(let reason):
            reason
        case .invalidJSON:
            "JSON must be an array of objects or JSON Lines object records."
        case .fileChangedExternally(let url):
            "\(url.lastPathComponent) was modified outside LightData after it was opened. Reopen the file before saving to avoid overwriting newer changes."
        }
    }
}

struct TableDocument {
    let url: URL
    let format: TableFileFormat
    var headers: [String]
    var rows: [[String]]
    var readOnly: Bool
    var dirty: Bool = false
    var sheetName: String?
    var openInfo: FileOpenInfo
    var loadedModificationDate: Date?

    var rowCount: Int { rows.count }
    var columnCount: Int { headers.count }
    var canEditFormat: Bool { !readOnly }

    static func load(url: URL, delimiterOverride: Character? = nil) throws -> TableDocument {
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
        default:
            throw TableDocumentError.unsupportedFile(url)
        }
    }

    mutating func setValue(_ value: String, row: Int, column: Int) {
        guard !readOnly, rows.indices.contains(row), headers.indices.contains(column) else { return }
        while rows[row].count < headers.count {
            rows[row].append("")
        }
        if rows[row][column] != value {
            rows[row][column] = value
            dirty = true
        }
    }

    mutating func addRow(after row: Int? = nil) {
        guard !readOnly else { return }
        let newRow = Array(repeating: "", count: headers.count)
        if let row, rows.indices.contains(row) {
            rows.insert(newRow, at: row + 1)
        } else {
            rows.append(newRow)
        }
        dirty = true
    }

    mutating func deleteRows(_ indexes: IndexSet) {
        guard !readOnly else { return }
        for index in indexes.sorted(by: >) where rows.indices.contains(index) {
            rows.remove(at: index)
        }
        dirty = true
    }

    mutating func renameColumn(at index: Int, to newName: String) {
        guard !readOnly, headers.indices.contains(index) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        headers[index] = trimmed.isEmpty ? "Column \(index + 1)" : trimmed
        headers = makeUnique(headers)
        dirty = true
    }

    mutating func deleteColumn(at index: Int) {
        guard !readOnly, headers.indices.contains(index), headers.count > 1 else { return }
        headers.remove(at: index)
        for rowIndex in rows.indices where rows[rowIndex].indices.contains(index) {
            rows[rowIndex].remove(at: index)
        }
        dirty = true
    }

    mutating func pasteRows(_ pastedRows: [[String]], startingAt startRow: Int, column startColumn: Int) {
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

    mutating func save() throws {
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
        }
        dirty = false
        loadedModificationDate = Self.modificationDate(for: url)
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
