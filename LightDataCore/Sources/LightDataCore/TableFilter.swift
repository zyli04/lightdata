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
            indexes = sorted(indexes, by: columnIndex, ascending: sortDescriptor.ascending, in: document)
        }

        return indexes
    }

    /// Sorts row indices by one column with a stable, transitive ordering.
    ///
    /// The whole column commits to a SINGLE comparison domain — numeric only if every
    /// non-empty value parses as a finite Double, otherwise string — so the order is a
    /// proper strict-weak-ordering (mixing per-pair numeric/string comparisons produces
    /// cycles). Keys are precomputed once per row instead of parsed on every compare.
    private static func sorted(_ indexes: [Int], by columnIndex: Int, ascending: Bool, in document: TableDocument) -> [Int] {
        let values = indexes.map { value(at: columnIndex, row: document.rows[$0]) }
        let trimmed = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        let numeric = trimmed.allSatisfy { $0.isEmpty || Double($0).map { $0.isFinite } == true }
        // Precompute a sort key per row index (parse/normalize once, not per comparison).
        var keys: [Int: (empty: Bool, number: Double, text: String)] = [:]
        keys.reserveCapacity(indexes.count)
        for (position, rowIndex) in indexes.enumerated() {
            let t = trimmed[position]
            keys[rowIndex] = (t.isEmpty, numeric ? (Double(t) ?? 0) : 0, values[position])
        }

        return indexes.sorted { lhs, rhs in
            let a = keys[lhs]!
            let b = keys[rhs]!
            // Empty cells always sink to the bottom, regardless of direction.
            if a.empty != b.empty { return b.empty }
            if a.empty && b.empty { return lhs < rhs }   // stable tie-break
            let result: ComparisonResult
            if numeric {
                result = a.number < b.number ? .orderedAscending
                    : a.number > b.number ? .orderedDescending : .orderedSame
            } else {
                result = a.text.localizedStandardCompare(b.text)
            }
            if result == .orderedSame { return lhs < rhs }  // stable tie-break
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private static func value(at columnIndex: Int, row: [String]) -> String {
        columnIndex < row.count ? row[columnIndex] : ""
    }
}
