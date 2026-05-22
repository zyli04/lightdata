import Foundation

enum ColumnType: String, Codable, CaseIterable {
    case text
    case number
    case date
    case checkbox
    case url
    case select
    case multiSelect
    case status

    var displayName: String {
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

struct SelectOption: Codable, Equatable {
    var name: String
    var color: String
}

struct ColumnSchema: Codable, Equatable {
    var type: ColumnType
    var options: [SelectOption] = []
    var multiSelectSeparator: String = ","
    var trueValues: [String] = ["true", "yes", "1", "y"]
    var falseValues: [String] = ["false", "no", "0", "n"]
}

struct TableSchema: Codable, Equatable {
    var columns: [String: ColumnSchema] = [:]

    func schema(for header: String) -> ColumnSchema {
        columns[header] ?? ColumnSchema(type: .text)
    }

    mutating func setType(_ type: ColumnType, for header: String, sampleValues: [String]) {
        var schema = columns[header] ?? ColumnSchema(type: type)
        schema.type = type
        if type == .select || type == .multiSelect || type == .status {
            schema.options = inferOptions(from: sampleValues, type: type, separator: schema.multiSelectSeparator)
        }
        columns[header] = schema
    }

    mutating func removeMissingColumns(validHeaders: [String]) {
        let valid = Set(validHeaders)
        columns = columns.filter { valid.contains($0.key) }
    }

    static func inferred(headers: [String], rows: [[String]]) -> TableSchema {
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
