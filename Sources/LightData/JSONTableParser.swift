import Foundation

enum JSONTableParser {
    static func readJSON(url: URL) throws -> ParsedTable {
        let decoded = try FileTextDecoder.decode(url: url)
        let data = Data(decoded.text.utf8)
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let array = value as? [Any] else { throw TableDocumentError.invalidJSON }
        var parsed = try table(from: array)
        parsed.openInfo = FileOpenInfo(encoding: decoded.encoding, lineEnding: decoded.lineEnding, delimiter: .none, readOnlyReason: nil)
        return parsed
    }

    static func readJSONLines(url: URL) throws -> ParsedTable {
        let decoded = try FileTextDecoder.decode(url: url)
        let records = try decoded.text
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { line -> Any in
                let data = Data(String(line).utf8)
                return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            }
        var parsed = try table(from: records)
        parsed.openInfo = FileOpenInfo(encoding: decoded.encoding, lineEnding: decoded.lineEnding, delimiter: .none, readOnlyReason: nil)
        return parsed
    }

    static func writeJSON(url: URL, headers: [String], rows: [[String]], encoding: TextEncodingKind, lineEnding: LineEnding) throws {
        let objects = objectsFromRows(headers: headers, rows: rows)
        let data = try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
        let text = String(data: data, encoding: .utf8) ?? "[]"
        try AtomicFileWriter.write(FileTextDecoder.encode(normalizeLineEndings(text, to: lineEnding), encoding: encoding), to: url)
    }

    static func writeJSONLines(url: URL, headers: [String], rows: [[String]], encoding: TextEncodingKind, lineEnding: LineEnding) throws {
        let objects = objectsFromRows(headers: headers, rows: rows)
        let lines = try objects.map { object -> String in
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return String(data: data, encoding: .utf8) ?? "{}"
        }.joined(separator: lineEnding.stringValue) + lineEnding.stringValue
        try AtomicFileWriter.write(FileTextDecoder.encode(lines, encoding: encoding), to: url)
    }

    private static func table(from array: [Any]) throws -> ParsedTable {
        let flattened = array.compactMap { value -> [String: String]? in
            guard let object = value as? [String: Any] else { return nil }
            return flatten(object)
        }
        guard flattened.count == array.count else { throw TableDocumentError.invalidJSON }
        guard !flattened.isEmpty else { throw TableDocumentError.emptyFile }

        var orderedHeaders: [String] = []
        var seen = Set<String>()
        for object in flattened {
            for key in object.keys.sorted() where !seen.contains(key) {
                orderedHeaders.append(key)
                seen.insert(key)
            }
        }
        let rows = flattened.map { object in
            orderedHeaders.map { object[$0] ?? "" }
        }
        return ParsedTable(headers: orderedHeaders, rows: rows)
    }

    private static func flatten(_ object: [String: Any], prefix: String = "") -> [String: String] {
        var result: [String: String] = [:]
        for key in object.keys.sorted() {
            let value = object[key] ?? NSNull()
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let nested = value as? [String: Any] {
                result.merge(flatten(nested, prefix: path), uniquingKeysWith: { _, new in new })
            } else {
                result[path] = stringify(value)
            }
        }
        return result
    }

    private static func stringify(_ value: Any) -> String {
        switch value {
        case is NSNull:
            return ""
        case let string as String:
            return string
        case let bool as Bool:
            return bool ? "true" : "false"
        case let number as NSNumber:
            return number.stringValue
        default:
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
               let string = String(data: data, encoding: .utf8) {
                return string
            }
            return String(describing: value)
        }
    }

    private static func objectsFromRows(headers: [String], rows: [[String]]) -> [[String: String]] {
        rows.map { row in
            var object: [String: String] = [:]
            for (index, header) in headers.enumerated() {
                object[header] = index < row.count ? row[index] : ""
            }
            return object
        }
    }

    private static func normalizeLineEndings(_ text: String, to lineEnding: LineEnding) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.replacingOccurrences(of: "\n", with: lineEnding.stringValue)
    }
}
