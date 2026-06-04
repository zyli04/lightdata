import Foundation

public enum FilterOperator: String, CaseIterable, Equatable {
    case contains = "contains"
    case equals = "equals"
    case empty = "is empty"
    case notEmpty = "not empty"
}

public struct TableFilter: Equatable {
    public var columnIndex: Int
    public var operation: FilterOperator
    public var value: String

    public init(columnIndex: Int, operation: FilterOperator, value: String) {
        self.columnIndex = columnIndex
        self.operation = operation
        self.value = value
    }

    public func matches(row: [String]) -> Bool {
        let cell = columnIndex < row.count ? row[columnIndex] : ""
        switch operation {
        case .contains:
            return cell.range(of: value, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        case .equals:
            return cell.compare(value, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        case .empty:
            return cell.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .notEmpty:
            return !cell.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

public enum TableQueryEngine {
    public static func visibleRows(
        in document: TableDocument?,
        search: String,
        filter: TableFilter?,
        sortDescriptor: NSSortDescriptor?
    ) -> [Int] {
        guard let document else { return [] }
        let trimmedSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)

        var indexes = document.rows.indices.filter { index in
            let row = document.rows[index]
            if !trimmedSearch.isEmpty {
                let hasMatch = row.contains {
                    $0.range(of: trimmedSearch, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
                if !hasMatch { return false }
            }
            if let filter, !filter.matches(row: row) {
                return false
            }
            return true
        }

        if let sortDescriptor,
           let key = sortDescriptor.key,
           let columnIndex = Int(key) {
            indexes.sort { left, right in
                let lhs = value(at: columnIndex, row: document.rows[left])
                let rhs = value(at: columnIndex, row: document.rows[right])
                let result = compare(lhs, rhs)
                return sortDescriptor.ascending ? result == .orderedAscending : result == .orderedDescending
            }
        }

        return indexes
    }

    private static func value(at columnIndex: Int, row: [String]) -> String {
        columnIndex < row.count ? row[columnIndex] : ""
    }

    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if let leftNumber = Double(lhs), let rightNumber = Double(rhs) {
            if leftNumber < rightNumber { return .orderedAscending }
            if leftNumber > rightNumber { return .orderedDescending }
            return .orderedSame
        }
        return lhs.localizedStandardCompare(rhs)
    }
}
