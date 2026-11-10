import Foundation

public enum ColumnType: String, Codable, CaseIterable {
    case text
    case number
    case date
    case checkbox
    case url
    case select
    case multiSelect
    case status

    public var displayName: String {
        switch self {
        case .text: "Text"
        case .number: "Number"
        case .date: "Date"
        case .checkbox: "Checkbox"
        case .url: "URL"
        case .select: "Select"
        case .multiSelect: "Multi-select"
        case .status: "Status"
        }
    }

    /// Format types have an objective per-value pass/fail test, so they participate in
    /// the gate: a column may only be declared as one if every (non-empty) value
    /// conforms. Intent types (select/multiSelect/status) are semantic user choices with
    /// no machine test — any text "is" a category — so they're excluded from the gate
    /// and never auto-inferred.
    public var isFormatType: Bool {
        switch self {
        case .number, .date, .url, .checkbox: true
        case .text, .select, .multiSelect, .status: false
        }
    }

    /// Types the UI offers. Intent types (select/multiSelect/status) are frozen: LightData
    /// is a data-file viewer, not a Notion-style authoring tool. Their code and any
    /// stored metadata stay, so unfreezing later restores them.
    public static let offeredCases: [ColumnType] = [.text, .number, .date, .checkbox, .url]

    public var isFrozen: Bool {
        !ColumnType.offeredCases.contains(self)
    }
}

/// Pure (Foundation-only) conformance tests for the format types. Shared by inference
/// and by the UI gate so both agree on what "conforms" means.
public enum ColumnTypeValidator {
    public static let defaultTrueValues: Set<String> = ["true", "yes", "1", "y"]
    public static let defaultFalseValues: Set<String> = ["false", "no", "0", "n"]

    /// Whether a single value conforms to a format type. Empty/whitespace values are
    /// universally compatible (treated as "no value"), so they never disqualify a column.
    public static func matches(_ value: String, type: ColumnType) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return true }
        switch type {
        case .number:
            return Double(v) != nil
        case .url:
            return URL(string: v)?.scheme?.hasPrefix("http") == true
        case .checkbox:
            let lower = v.lowercased()
            return defaultTrueValues.contains(lower) || defaultFalseValues.contains(lower)
        case .date:
            return isISO8601Date(v)
        default:
            return true
        }
    }

    /// The gate predicate: a column may be declared `type` only if every non-empty value
    /// conforms. Non-format (intent) types are never gated, so they always pass.
    public static func columnConforms(_ values: [String], to type: ColumnType) -> Bool {
        guard type.isFormatType else { return true }
        return values.allSatisfy { matches($0, type: type) }
    }

    /// The format types this column could legitimately be declared as.
    public static func conformingFormatTypes(for values: [String]) -> [ColumnType] {
        ColumnType.allCases.filter { $0.isFormatType && columnConforms(values, to: $0) }
    }

    // Date conformance is restricted to the unambiguous ISO 8601 family for v1. Locale-
    // dependent formats (e.g. 03/04/05) are intentionally excluded.
    private static let isoFormatters: [DateFormatter] = {
        ["yyyy-MM-dd", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = format
            formatter.isLenient = false
            return formatter
        }
    }()

    private static func isISO8601Date(_ value: String) -> Bool {
        isoFormatters.contains { $0.date(from: value) != nil }
    }
}

/// The tag color palette, stored as semantic names. The App layer resolves each name to
/// an appearance-adaptive system color (NSColor.system*), so no colors are hand-picked
/// and dark/light mode adaptation is free.
public enum TagPalette {
    public static let names = [
        "blue", "green", "yellow", "orange", "red",
        "pink", "purple", "indigo", "teal", "cyan", "mint", "brown", "gray"
    ]

    public static func color(at index: Int) -> String {
        names[index % names.count]
    }
}

public struct SelectOption: Codable, Equatable {
    public var name: String
    public var color: String

    public init(name: String, color: String) {
        self.name = name
        self.color = color
    }
}

public struct ColumnSchema: Codable, Equatable {
    public var type: ColumnType
    public var options: [SelectOption] = []
    public var multiSelectSeparator: String = ","
    public var trueValues: [String] = ["true", "yes", "1", "y"]
    public var falseValues: [String] = ["false", "no", "0", "n"]

    public init(
        type: ColumnType,
        options: [SelectOption] = [],
        multiSelectSeparator: String = ",",
        trueValues: [String] = ["true", "yes", "1", "y"],
        falseValues: [String] = ["false", "no", "0", "n"]
    ) {
        self.type = type
        self.options = options
        self.multiSelectSeparator = multiSelectSeparator
        self.trueValues = trueValues
        self.falseValues = falseValues
    }
}

public struct TableSchema: Codable, Equatable {
    public var columns: [String: ColumnSchema] = [:]

    public init(columns: [String: ColumnSchema] = [:]) {
        self.columns = columns
    }

    /// The effective schema for a column. A frozen (intent) type resolves as plain text;
    /// the stored entry in `columns` is left untouched.
    public func schema(for header: String) -> ColumnSchema {
        guard let stored = columns[header], !stored.type.isFrozen else {
            return ColumnSchema(type: .text)
        }
        return stored
    }

    public mutating func setType(_ type: ColumnType, for header: String, sampleValues: [String]) {
        var schema = columns[header] ?? ColumnSchema(type: type)
        schema.type = type
        if type == .select || type == .multiSelect || type == .status {
            schema.options = inferOptions(from: sampleValues, type: type, separator: schema.multiSelectSeparator)
        }
        columns[header] = schema
    }

    public mutating func removeMissingColumns(validHeaders: [String]) {
        let valid = Set(validHeaders)
        columns = columns.filter { valid.contains($0.key) }
    }

    /// Drops any format type that the column's data no longer conforms to (demotes that
    /// column to text). Called when re-enabling types so stale promises self-heal.
    public mutating func demoteNonConforming(headers: [String], rows: [[String]]) {
        for (index, header) in headers.enumerated() {
            guard let schema = columns[header], schema.type.isFormatType else { continue }
            let values = rows.compactMap { index < $0.count ? $0[index] : nil }
            if !ColumnTypeValidator.columnConforms(values, to: schema.type) {
                columns.removeValue(forKey: header)
            }
        }
    }

    public static func inferred(headers: [String], rows: [[String]]) -> TableSchema {
        var schema = TableSchema()
        for (index, header) in headers.enumerated() {
            let sample = rows.prefix(200).compactMap { row in
                index < row.count ? row[index].trimmingCharacters(in: .whitespacesAndNewlines) : nil
            }.filter { !$0.isEmpty }
            let type = inferType(from: sample)
            if type != .text {
                schema.setType(type, for: header, sampleValues: sample)
            }
        }
        return schema
    }

    /// Auto-assigns a format type only when the column unambiguously matches exactly one
    /// (e.g. all ISO dates → date). Ambiguous columns (e.g. all 0/1, which are both
    /// number and checkbox) stay text for the user to choose. Intent types are never
    /// inferred.
    private static func inferType(from values: [String]) -> ColumnType {
        guard !values.isEmpty else { return .text }
        let matching = ColumnTypeValidator.conformingFormatTypes(for: values)
        return matching.count == 1 ? matching[0] : .text
    }
}

private func inferOptions(from values: [String], type: ColumnType, separator: String) -> [SelectOption] {
    let names: [String]
    if type == .multiSelect {
        names = values.flatMap { $0.split(separator: Character(separator)).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
    } else {
        names = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    return Array(Set(names.filter { !$0.isEmpty })).sorted().enumerated().map { index, name in
        SelectOption(name: name, color: TagPalette.color(at: index))
    }
}
