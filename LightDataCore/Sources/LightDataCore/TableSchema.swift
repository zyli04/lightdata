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

    public func schema(for header: String) -> ColumnSchema {
        columns[header] ?? ColumnSchema(type: .text)
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

    public static func inferred(headers: [String], rows: [[String]]) -> TableSchema {
        var schema = TableSchema()
        for (index, header) in headers.enumerated() {
            let sample = rows.prefix(200).compactMap { row in
                index < row.count ? row[index].trimmingCharacters(in: .whitespacesAndNewlines) : nil
            }.filter { !$0.isEmpty }
            let type = inferType(from: sample)
            schema.setType(type, for: header, sampleValues: sample)
        }
        return schema
    }

    private static func inferType(from values: [String]) -> ColumnType {
        guard !values.isEmpty else { return .text }
        if values.allSatisfy({ URL(string: $0)?.scheme?.hasPrefix("http") == true }) {
            return .url
        }
        if values.allSatisfy({ Double($0) != nil }) {
            return .number
        }
        return .text
    }
}

private func inferOptions(from values: [String], type: ColumnType, separator: String) -> [SelectOption] {
    let names: [String]
    if type == .multiSelect {
        names = values.flatMap { $0.split(separator: Character(separator)).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
    } else {
        names = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    let palette = ["gray", "blue", "green", "yellow", "red", "purple", "pink", "orange"]
    return Array(Set(names.filter { !$0.isEmpty })).sorted().enumerated().map { index, name in
        SelectOption(name: name, color: palette[index % palette.count])
    }
}
