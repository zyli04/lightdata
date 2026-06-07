import Foundation

enum XLSXReaderError: LocalizedError {
    case extractionFailed
    case missingWorksheet

    var errorDescription: String? {
        switch self {
        case .extractionFailed:
            "Could not extract the XLSX workbook."
        case .missingWorksheet:
            "Could not find a worksheet in the XLSX workbook."
        }
    }
}

enum XLSXReader {
    static func readFirstSheet(url: URL, firstRowIsHeader: Bool = true) throws -> ParsedTable {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("LightData-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try extractZip(url, to: tempRoot)

        let sharedStrings = parseSharedStrings(at: tempRoot.appendingPathComponent("xl/sharedStrings.xml"))
        let sheetName = parseFirstSheetName(at: tempRoot.appendingPathComponent("xl/workbook.xml"))
        let sheetURL = findFirstWorksheet(in: tempRoot)
        guard let sheetURL else { throw XLSXReaderError.missingWorksheet }

        let sheet = try parseWorksheet(at: sheetURL, sharedStrings: sharedStrings)
        guard !sheet.isEmpty else { throw TableDocumentError.emptyFile }

        let maxColumn = sheet.values.flatMap(\.keys).max() ?? 0
        let firstRowIndex = sheet.keys.min() ?? 1
        let headers: [String]
        let dataRowKeys: [Int]
        if firstRowIsHeader {
            let headerCells = sheet[firstRowIndex] ?? [:]
            let names = (0...maxColumn).map { index in
                let value = headerCells[index]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return value.isEmpty ? "Column \(index + 1)" : value
            }
            headers = makeUnique(names)
            dataRowKeys = sheet.keys.sorted().filter { $0 != firstRowIndex }
        } else {
            headers = (0...maxColumn).map { "Column \($0 + 1)" }
            dataRowKeys = sheet.keys.sorted()
        }

        let rows = dataRowKeys.map { rowIndex in
            let row = sheet[rowIndex] ?? [:]
            return (0..<headers.count).map { row[$0] ?? "" }
        }

        return ParsedTable(
            headers: headers,
            rows: rows,
            sheetName: sheetName,
            openInfo: FileOpenInfo(
                encoding: nil,
                lineEnding: nil,
                delimiter: .none,
                readOnlyReason: "XLSX read-only"
            )
        )
    }

    private static func extractZip(_ url: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", url.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XLSXReaderError.extractionFailed }
    }

    private static func findFirstWorksheet(in root: URL) -> URL? {
        let worksheets = root.appendingPathComponent("xl/worksheets")
        let sheet1 = worksheets.appendingPathComponent("sheet1.xml")
        if FileManager.default.fileExists(atPath: sheet1.path) {
            return sheet1
        }
        return try? FileManager.default
            .contentsOfDirectory(at: worksheets, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    private static func parseSharedStrings(at url: URL) -> [String] {
        guard FileManager.default.fileExists(atPath: url.path),
              let parser = XMLParser(contentsOf: url) else {
            return []
        }
        let delegate = SharedStringsDelegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    private static func parseFirstSheetName(at url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path),
              let parser = XMLParser(contentsOf: url) else {
            return nil
        }
        let delegate = WorkbookDelegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.firstSheetName
    }

    private static func parseWorksheet(at url: URL, sharedStrings: [String]) throws -> [Int: [Int: String]] {
        guard let parser = XMLParser(contentsOf: url) else { throw XLSXReaderError.missingWorksheet }
        let delegate = WorksheetDelegate(sharedStrings: sharedStrings)
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? XLSXReaderError.missingWorksheet
        }
        return delegate.rows
    }
}

private final class SharedStringsDelegate: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var current = ""
    private var insideStringItem = false
    private var insideText = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "si" {
            insideStringItem = true
            current = ""
        } else if elementName == "t", insideStringItem {
            insideText = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideText {
            current += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t" {
            insideText = false
        } else if elementName == "si" {
            strings.append(current)
            insideStringItem = false
        }
    }
}

private final class WorkbookDelegate: NSObject, XMLParserDelegate {
    var firstSheetName: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "sheet", firstSheetName == nil {
            firstSheetName = attributeDict["name"]
        }
    }
}

private final class WorksheetDelegate: NSObject, XMLParserDelegate {
    let sharedStrings: [String]
    var rows: [Int: [Int: String]] = [:]

    private var currentCellReference: String?
    private var currentCellType: String?
    private var currentValue = ""
    private var insideValue = false
    private var insideInlineText = false

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "c" {
            currentCellReference = attributeDict["r"]
            currentCellType = attributeDict["t"]
            currentValue = ""
        } else if elementName == "v" {
            insideValue = true
        } else if elementName == "t", currentCellType == "inlineStr" {
            insideInlineText = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideValue || insideInlineText {
            currentValue += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "v" {
            insideValue = false
        } else if elementName == "t" {
            insideInlineText = false
        } else if elementName == "c" {
            commitCurrentCell()
            currentCellReference = nil
            currentCellType = nil
            currentValue = ""
        }
    }

    private func commitCurrentCell() {
        guard let reference = currentCellReference,
              let position = cellPosition(from: reference) else {
            return
        }

        var value = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentCellType == "s",
           let index = Int(value),
           sharedStrings.indices.contains(index) {
            value = sharedStrings[index]
        } else if currentCellType == "b" {
            value = value == "1" ? "true" : "false"
        }

        rows[position.row, default: [:]][position.column] = value
    }

    private func cellPosition(from reference: String) -> (row: Int, column: Int)? {
        let letters = reference.prefix { $0.isLetter }
        let digits = reference.drop { $0.isLetter }.prefix { $0.isNumber }
        guard let row = Int(digits), !letters.isEmpty else { return nil }

        var column = 0
        for scalar in String(letters).uppercased().unicodeScalars {
            let value = Int(scalar.value) - Int(UnicodeScalar("A").value) + 1
            column = column * 26 + value
        }
        return (row: row, column: column - 1)
    }
}
