import DuckDB
import Foundation

/// A backing-agnostic description of what subset/ordering of a table the UI wants
/// to display: a global search string, an optional column filter, and an optional
/// sort. Used by lazy data sources to push the work down into the query engine.
public struct TableQuerySpec: Equatable {
    public var search: String
    public var filter: TableFilter?
    public var sortColumn: Int?
    public var sortAscending: Bool

    public init(search: String = "", filter: TableFilter? = nil, sortColumn: Int? = nil, sortAscending: Bool = true) {
        self.search = search
        self.filter = filter
        self.sortColumn = sortColumn
        self.sortAscending = sortAscending
    }

    public var isIdentity: Bool {
        search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && filter == nil && sortColumn == nil
    }
}

/// Lazy, paged, read-only view over a (potentially huge) Parquet file backed by
/// DuckDB. Nothing is materialised up front beyond the schema: row counts and row
/// pages are queried on demand, with filtering/sorting/search pushed into DuckDB.
///
/// Not thread-safe: a DuckDB connection must be used from a single thread. Callers
/// should confine all access to one serial queue.
public final class DuckDBTableSource {
    public let url: URL
    public let headers: [String]

    private let database: Database
    private let connection: Connection
    /// Wrapped subquery that renames every column to a stable synthetic alias
    /// (c0, c1, …) while preserving its original type. Display casts to VARCHAR;
    /// sorting uses the typed alias so numbers/dates order naturally.
    private let baseSubquery: String

    public init(parquetURL url: URL) throws {
        do {
            let database = try Database(store: .inMemory)
            let connection = try database.connect()
            // Make natural (unsorted) row order deterministic across LIMIT/OFFSET
            // queries; otherwise parallel scans can return rows in varying order
            // and pagination becomes inconsistent.
            _ = try connection.query("SET preserve_insertion_order=true")

            let relation = "read_parquet(\(Self.sqlStringLiteral(url.path)))"
            let schemaResult = try connection.query("SELECT * FROM \(relation) LIMIT 0")
            let rawNames = (0..<schemaResult.columnCount).map { schemaResult.columnName(at: $0) }
            let unique = makeUnique(rawNames)
            guard !unique.isEmpty else { throw TableDocumentError.emptyFile }

            let innerSelect = rawNames.enumerated().map { index, name in
                "\(Self.sqlIdentifier(name)) AS \(Self.columnAlias(index))"
            }.joined(separator: ", ")

            self.url = url
            self.headers = unique
            self.database = database
            self.connection = connection
            self.baseSubquery = "(SELECT \(innerSelect) FROM \(relation)) AS t"
        } catch let error as TableDocumentError {
            throw error
        } catch {
            throw TableDocumentError.invalidParquet(error.localizedDescription)
        }
    }

    /// Total number of rows in the file (ignores any query), read from Parquet
    /// metadata so it returns near-instantly even for very large files.
    public func totalRowCount() throws -> Int {
        try rowCount(matching: TableQuerySpec())
    }

    /// Number of rows matching the given query.
    public func rowCount(matching spec: TableQuerySpec) throws -> Int {
        let sql = "SELECT CAST(count(*) AS VARCHAR) FROM \(baseSubquery)\(whereClause(for: spec))"
        let result = try connection.query(sql)
        guard result.rowCount > 0 else { return 0 }
        let column = result[0].cast(to: String.self)
        return Int(column[0] ?? "0") ?? 0
    }

    /// Fetches a page of rows (as display strings; NULL becomes "") for the given
    /// query, ordered consistently so pages stitch together correctly.
    public func page(matching spec: TableQuerySpec, offset: Int, limit: Int) throws -> [[String]] {
        guard limit > 0 else { return [] }
        let selectList = (0..<headers.count).map { Self.varcharRef($0) }.joined(separator: ", ")
        let sql = "SELECT \(selectList) FROM \(baseSubquery)"
            + whereClause(for: spec)
            + orderClause(for: spec)
            + " LIMIT \(limit) OFFSET \(max(0, offset))"
        let result = try connection.query(sql)
        let columns = (0..<result.columnCount).map { result[$0].cast(to: String.self) }
        let rows = Int(result.rowCount)
        return (0..<rows).map { rowIndex in
            columns.map { $0[DBInt(rowIndex)] ?? "" }
        }
    }

    // MARK: - SQL building

    private func whereClause(for spec: TableQuerySpec) -> String {
        var clauses: [String] = []

        let search = spec.search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            let pattern = Self.likeLiteral(containing: search)
            let ors = (0..<headers.count).map { "\(Self.varcharRef($0)) ILIKE \(pattern) ESCAPE '\\'" }
            clauses.append("(" + ors.joined(separator: " OR ") + ")")
        }

        if let filter = spec.filter, headers.indices.contains(filter.columnIndex) {
            let typed = Self.columnAlias(filter.columnIndex)
            let text = Self.varcharRef(filter.columnIndex)
            switch filter.operation {
            case .contains:
                clauses.append("\(text) ILIKE \(Self.likeLiteral(containing: filter.value)) ESCAPE '\\'")
            case .equals:
                clauses.append("lower(\(text)) = lower(\(Self.sqlStringLiteral(filter.value)))")
            case .empty:
                clauses.append("(\(typed) IS NULL OR trim(\(text)) = '')")
            case .notEmpty:
                clauses.append("(\(typed) IS NOT NULL AND trim(\(text)) <> '')")
            }
        }

        return clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
    }

    private func orderClause(for spec: TableQuerySpec) -> String {
        guard let column = spec.sortColumn, headers.indices.contains(column) else { return "" }
        return " ORDER BY \(Self.columnAlias(column)) \(spec.sortAscending ? "ASC" : "DESC")"
    }

    // MARK: - SQL helpers

    private static func columnAlias(_ index: Int) -> String { "\"c\(index)\"" }

    private static func varcharRef(_ index: Int) -> String { "CAST(\(columnAlias(index)) AS VARCHAR)" }

    private static func sqlStringLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func sqlIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Builds a `'%escaped%'` literal for use with `ILIKE ... ESCAPE '\'`, escaping
    /// both LIKE metacharacters and the SQL string quote.
    private static func likeLiteral(containing value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "%", with: "\\%")
        escaped = escaped.replacingOccurrences(of: "_", with: "\\_")
        return sqlStringLiteral("%\(escaped)%")
    }
}
