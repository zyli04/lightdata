import Foundation

public enum DelimitedTextParser {
    static func readAuto(url: URL, firstRowIsHeader: Bool = true) throws -> ParsedTable {
        let decoded = try FileTextDecoder.decode(url: url)
        let delimiter = detectDelimiter(in: decoded.text)
        return try table(from: parse(decoded.text, delimiter: delimiter), decoded: decoded, delimiter: delimiter, firstRowIsHeader: firstRowIsHeader)
    }

    static func read(url: URL, delimiter: Character, firstRowIsHeader: Bool = true) throws -> ParsedTable {
        let decoded = try FileTextDecoder.decode(url: url)
        return try table(from: parse(decoded.text, delimiter: delimiter), decoded: decoded, delimiter: delimiter, firstRowIsHeader: firstRowIsHeader)
    }

    private static func table(from records: [[String]], decoded: DecodedText, delimiter: Character, firstRowIsHeader: Bool) throws -> ParsedTable {
        guard !records.isEmpty else { throw TableDocumentError.emptyFile }

        let headers: [String]
        let dataRecords: ArraySlice<[String]>
        if firstRowIsHeader {
            var names = records[0].map { uniqueHeaderName($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if names.allSatisfy({ $0.isEmpty }) {
                names = (0..<records[0].count).map { "Column \($0 + 1)" }
            }
            headers = makeUnique(names)
            dataRecords = records.dropFirst()
        } else {
            // Headerless: every record is data; synthesize placeholder column names
            // sized to the widest record so nothing is truncated.
            let columnCount = records.map(\.count).max() ?? 0
            headers = (0..<columnCount).map { "Column \($0 + 1)" }
            dataRecords = records[...]
        }

        let rows = dataRecords.map { row in
            normalized(row, width: headers.count)
        }
        return ParsedTable(
            headers: headers,
            rows: rows,
            openInfo: FileOpenInfo(
                encoding: decoded.encoding,
                lineEnding: decoded.lineEnding,
                delimiter: DelimiterKind(character: delimiter),
                readOnlyReason: nil
            )
        )
    }

    static func write(url: URL, headers: [String], rows: [[String]], delimiter: Character, encoding: TextEncodingKind, lineEnding: LineEnding, includeHeader: Bool = true) throws {
        let dataRows = rows.map { normalized($0, width: headers.count) }
        let allRows = includeHeader ? [headers] + dataRows : dataRows
        let output = allRows.map { record in
            record.map { escape($0, delimiter: delimiter) }.joined(separator: String(delimiter))
        }.joined(separator: lineEnding.stringValue) + lineEnding.stringValue
        try AtomicFileWriter.write(FileTextDecoder.encode(output, encoding: encoding), to: url)
    }

    public static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let characters = Array(normalizedText)
        var index = 0
        var inQuotes = false

        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                if character == "\"" && field.isEmpty {
                    inQuotes = true
                } else if character == delimiter {
                    record.append(field)
                    field.removeAll(keepingCapacity: true)
                } else if character == "\n" {
                    record.append(field)
                    field.removeAll(keepingCapacity: true)
                    records.append(record)
                    record.removeAll(keepingCapacity: true)
                } else {
                    field.append(character)
                }
            }
            index += 1
        }

        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }

        return records.filter { !$0.allSatisfy(\.isEmpty) }
    }

    private static func escape(_ value: String, delimiter: Character) -> String {
        let needsQuotes = value.contains(delimiter) || value.contains("\n") || value.contains("\r") || value.contains("\"")
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func detectDelimiter(in text: String) -> Character {
        let candidates: [Character] = [",", "\t", ";", "|"]
        let sample = String(text.prefix(16_384))
        var best: (delimiter: Character, score: Int) = (",", -1)

        for candidate in candidates {
            let rows = parse(sample, delimiter: candidate).prefix(20).filter { !$0.isEmpty }
            let columnCounts = rows.map(\.count).filter { $0 > 1 }
            guard !columnCounts.isEmpty else { continue }
            let mostCommonCount = columnCounts.reduce(into: [:]) { counts, value in
                counts[value, default: 0] += 1
            }.max { $0.value < $1.value }?.value ?? 0
            let score = mostCommonCount * 100 + (columnCounts.max() ?? 0)
            if score > best.score {
                best = (candidate, score)
            }
        }

        return best.delimiter
    }
}

func normalized(_ row: [String], width: Int) -> [String] {
    if row.count == width { return row }
    if row.count > width { return Array(row.prefix(width)) }
    return row + Array(repeating: "", count: width - row.count)
}

func makeUnique(_ headers: [String]) -> [String] {
    var counts: [String: Int] = [:]
    return headers.enumerated().map { index, raw in
        let base = raw.isEmpty ? "Column \(index + 1)" : raw
        let count = counts[base, default: 0]
        counts[base] = count + 1
        return count == 0 ? base : "\(base) \(count + 1)"
    }
}

private func uniqueHeaderName(_ value: String) -> String {
    value.isEmpty ? "" : value
}
