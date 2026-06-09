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
            // Cap worker threads low: by default DuckDB uses every core, and a heavy
            // scan (e.g. a deep page on a single-row-group file) then saturates the CPU
            // and starves the main thread, randomly freezing the UI (beach ball) for
            // the query's duration. Consistent latency is fine; unpredictable UI
            // freezes are not — so keep most cores free for the UI even if queries run
            // a bit slower.
            // Keep most cores free for the UI so background scans don't starve it.
            let cores = ProcessInfo.processInfo.activeProcessorCount
            _ = try connection.query("SET threads=\(max(1, cores / 4))")

            // file_row_number exposes each row's position in the file (0-based,
            // contiguous). DuckDB pushes a range predicate on it into the Parquet
            // reader and skips row groups via metadata, so paging by row-number
            // range is ~O(1) at any depth — unlike LIMIT/OFFSET which rescans from
            // the start. The schema probe must NOT request it (it's not a data column).
            let relation = "read_parquet(\(Self.sqlStringLiteral(url.path)), file_row_number=true)"
            let schemaResult = try connection.query("SELECT * FROM read_parquet(\(Self.sqlStringLiteral(url.path))) LIMIT 0")
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
            self.baseSubquery = "(SELECT \(innerSelect), file_row_number AS \(Self.rowNumberAlias) FROM \(relation)) AS t"
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

    /// Number of rows matching the given query. For the unfiltered case the count is
    /// read from the Parquet footer (instant, no scan) — critical on huge files where
    /// count(*) over the projected/file_row_number subquery would scan the whole file.
    public func rowCount(matching spec: TableQuerySpec) throws -> Int {
        let sql: String
        if spec.isIdentity {
            sql = "SELECT CAST(sum(num_rows) AS VARCHAR) FROM parquet_file_metadata(\(Self.sqlStringLiteral(url.path)))"
        } else {
            sql = "SELECT CAST(count(*) AS VARCHAR) FROM \(baseSubquery)\(whereClause(for: spec))"
        }
        let result = try connection.query(sql)
        guard result.rowCount > 0 else { return 0 }
        let column = result[0].cast(to: String.self)
        return Int(column[0] ?? "0") ?? 0
    }

    /// Fetches only the requested columns for a page of rows (as display strings;
    /// NULL becomes ""). Fetching just the visible columns is essential for wide
    /// tables: each extra column means decompressing another column chunk, which on
    /// a single-row-group file costs ~hundreds of ms.
    ///
    /// Returns a map of column index -> values, plus the number of rows actually
    /// returned (the last page may be short).
    public func columns(_ columnIndexes: [Int], matching spec: TableQuerySpec, offset: Int, limit: Int) throws -> (data: [Int: [String]], rowCount: Int) {
        let wanted = columnIndexes.filter { headers.indices.contains($0) }
        guard limit > 0, !wanted.isEmpty else { return ([:], 0) }
        let start = max(0, offset)
        let selectList = wanted.map { Self.varcharRef($0) }.joined(separator: ", ")
        let sql: String
        if spec.isIdentity {
            // Fast path: range scan on the pushed-down file row number. On files with
            // many small row groups this is constant-time at any depth; on a single
            // huge row group it still must scan, but only over the wanted columns.
            sql = "SELECT \(selectList) FROM \(baseSubquery)"
                + " WHERE \(Self.rowNumberAlias) >= \(start) AND \(Self.rowNumberAlias) < \(start + limit)"
                + " ORDER BY \(Self.rowNumberAlias)"
        } else {
            // Filtered/sorted views can't use the row-number range; fall back to
            // LIMIT/OFFSET (deep pages here are slower).
            sql = "SELECT \(selectList) FROM \(baseSubquery)"
                + whereClause(for: spec)
                + orderClause(for: spec)
                + " LIMIT \(limit) OFFSET \(start)"
        }
        let result = try connection.query(sql)
        let rows = Int(result.rowCount)
        var data: [Int: [String]] = [:]
        for (position, columnIndex) in wanted.enumerated() {
            let column = result[DBInt(position)].cast(to: String.self)
            data[columnIndex] = (0..<rows).map { column[DBInt($0)] ?? "" }
        }
        return (data, rows)
    }

    /// Convenience: fetches a full page of all columns as row-major strings.
    public func page(matching spec: TableQuerySpec, offset: Int, limit: Int) throws -> [[String]] {
        let all = Array(0..<headers.count)
        let (data, rows) = try columns(all, matching: spec, offset: offset, limit: limit)
        guard rows > 0 else { return [] }
        return (0..<rows).map { rowIndex in
            all.map { data[$0]?[rowIndex] ?? "" }
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

    private static let rowNumberAlias = "\"__frn\""

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
