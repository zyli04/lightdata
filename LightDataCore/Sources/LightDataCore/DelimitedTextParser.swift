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
            // Size headers to the widest record so data rows wider than the header row
            // aren't truncated (and silently lost on the next save); synthesize names
            // for the extra columns.
            let widest = records.map(\.count).max() ?? names.count
            if widest > names.count {
                names += (names.count..<widest).map { "Column \($0 + 1)" }
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
                readOnlyReason: decoded.readOnlyReason
            )
        )
    }

    static func write(url: URL, headers: [String], rows: [[String]], delimiter: Character, encoding: TextEncodingKind, lineEnding: LineEnding, includeHeader: Bool = true) throws {
        let dataRows = rows.map { normalized($0, width: headers.count) }
        let allRows = includeHeader ? [headers] + dataRows : dataRows
        let output = allRows.map { record in
            record.map { escape($0, delimiter: delimiter) }.joined(separator: String(delimiter))
        }.joined(separator: lineEnding.stringValue) + lineEnding.stringValue
        try AtomicFileWriter.write(try FileTextDecoder.encode(output, encoding: encoding), to: url)
    }

    public static func parse(_ text: String, delimiter: Character) -> [[String]] {
        // Single-pass byte scan. The previous implementation materialized three full
        // copies of the input (two replacingOccurrences passes for CR/CRLF plus an
        // Array(Character) grapheme array), which took ~1.2s and ~500MB peak for a
        // 23MB file; CSV syntax is pure ASCII (",\"\r\n), so we scan UTF-8 bytes and
        // slice field text out losslessly, normalizing line endings in-state.
        let bytes = Array(text.utf8)
        let delimiterBytes = Array(String(delimiter).utf8)
        // Multi-byte delimiters (exotic) fall back on the slow path below.
        guard delimiterBytes.count == 1 else {
            return parseCharacterwise(text, delimiter: delimiter)
        }
        let delimiterByte = delimiterBytes[0]
        let quote: UInt8 = 0x22, cr: UInt8 = 0x0D, lf: UInt8 = 0x0A

        var records: [[String]] = []
        var record: [String] = []
        // The current field accumulates as raw bytes; converted once per field.
        var field: [UInt8] = []
        field.reserveCapacity(256)
        var index = 0
        var inQuotes = false

        func endField() {
            field.withUnsafeBufferPointer { buffer in
                record.append(String(decoding: buffer, as: UTF8.self))
            }
            field.removeAll(keepingCapacity: true)
        }
        func endRecord() {
            endField()
            records.append(record)
            record.removeAll(keepingCapacity: true)
        }

        while index < bytes.count {
            let byte = bytes[index]
            if inQuotes {
                if byte == quote {
                    if index + 1 < bytes.count, bytes[index + 1] == quote {
                        field.append(quote)
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else if byte == cr {
                    // Normalize CR / CRLF inside quoted fields to LF.
                    field.append(lf)
                    if index + 1 < bytes.count, bytes[index + 1] == lf { index += 1 }
                } else {
                    field.append(byte)
                }
            } else {
                if byte == quote && field.isEmpty {
                    inQuotes = true
                } else if byte == delimiterByte {
                    endField()
                } else if byte == lf {
                    endRecord()
                } else if byte == cr {
                    endRecord()
                    if index + 1 < bytes.count, bytes[index + 1] == lf { index += 1 }
                } else {
                    field.append(byte)
                }
            }
            index += 1
        }

        if !field.isEmpty || !record.isEmpty {
            endRecord()
        }

        // Drop only blank *lines* (a single empty field, i.e. no delimiter was seen),
        // not legitimate all-empty rows like ",,," which carry real (empty) columns and
        // must survive a load/save round-trip.
        return records.filter { $0.count > 1 || $0.first?.isEmpty == false }
    }

    /// Character-based fallback for multi-scalar delimiters; same semantics.
    private static func parseCharacterwise(_ text: String, delimiter: Character) -> [[String]] {
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

        return records.filter { $0.count > 1 || $0.first?.isEmpty == false }
    }

    private static func escape(_ value: String, delimiter: Character) -> String {
        let needsQuotes = value.contains(delimiter) || value.contains("\n") || value.contains("\r") || value.contains("\"")
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Picks the most plausible delimiter. `preferred` is the file-extension default
    /// (comma for .csv — the "C" in the name, matching Excel): it wins any ambiguity,
    /// and a challenger must be DECISIVELY better (>1.5× score) to override it. That
    /// conservatism kills a whole class of misdetections where content inside fields
    /// (joined lists, prose) happens to split "nicely" by another character.
    private static func detectDelimiter(in text: String, preferred: Character = ",") -> Character {
        let candidates: [Character] = [",", "\t", ";", "|"]
        // Sample by RECORDS, not bytes: a single huge quoted field (e.g. a social-media
        // post body with embedded newlines) can exceed a byte window entirely, starving
        // the correct delimiter of sample rows while a stray delimiter char inside that
        // text produces many spurious fragments for a wrong one. We parse enough of the
        // text to yield a stable number of records for each candidate.
        let sample = String(text.prefix(256 * 1024))
        var scores: [Character: Double] = [:]

        for candidate in candidates {
            let rows = parse(sample, delimiter: candidate).prefix(50)
            let columnCounts = rows.map(\.count)
            guard let anchor = columnCounts.first, anchor > 1 else { continue }

            // The real delimiter must split EVERY record — anchored on the first one
            // (the header). Score = first-record column count × the fraction of rows
            // agreeing with it. This rejects both failure modes we've hit:
            // a stray char inside one huge text field (splits fragments, but not the
            // first record), and a ";"-joined list column (splits data rows ~28 wide
            // very consistently, but the header row not at all).
            let agreeing = columnCounts.filter { $0 == anchor }.count
            scores[candidate] = Double(anchor) * (Double(agreeing) / Double(columnCounts.count))
        }

        guard let bestChallenger = scores.filter({ $0.key != preferred }).max(by: { $0.value < $1.value }) else {
            return preferred
        }
        let preferredScore = scores[preferred] ?? 0
        if preferredScore > 0 {
            return bestChallenger.value > preferredScore * 1.5 ? bestChallenger.key : preferred
        }
        return bestChallenger.key
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
