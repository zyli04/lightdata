import XCTest
import DuckDB
@testable import LightDataCore

final class DuckDBTableSourceTests: XCTestCase {
    /// Writes a deterministic 100-row Parquet file: id 0..99, name "name<i>",
    /// grp = i % 3.
    private func makeParquet() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightdata-test-\(UUID().uuidString).parquet")
        let database = try Database(store: .inMemory)
        let connection = try database.connect()
        let path = url.path.replacingOccurrences(of: "'", with: "''")
        _ = try connection.query(
            "COPY (SELECT i AS id, 'name' || i AS name, (i % 3) AS grp FROM range(0, 100) t(i)) "
            + "TO '\(path)' (FORMAT PARQUET)"
        )
        return url
    }

    func testSchemaAndTotalCount() throws {
        let url = try makeParquet()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try DuckDBTableSource(parquetURL: url)
        XCTAssertEqual(source.headers, ["id", "name", "grp"])
        XCTAssertEqual(try source.totalRowCount(), 100)
    }

    func testNaturalOrderPaging() throws {
        let url = try makeParquet()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try DuckDBTableSource(parquetURL: url)
        let page = try source.page(matching: TableQuerySpec(), offset: 0, limit: 5)
        XCTAssertEqual(page.map { $0[0] }, ["0", "1", "2", "3", "4"])
        let page2 = try source.page(matching: TableQuerySpec(), offset: 98, limit: 10)
        XCTAssertEqual(page2.map { $0[0] }, ["98", "99"])
    }

    func testFilterEquals() throws {
        let url = try makeParquet()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try DuckDBTableSource(parquetURL: url)
        let spec = TableQuerySpec(filter: TableFilter(columnIndex: 2, operation: .equals, value: "1"))
        XCTAssertEqual(try source.rowCount(matching: spec), 33) // i%3==1 for i in 1..97
    }

    func testSearchAcrossColumns() throws {
        let url = try makeParquet()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try DuckDBTableSource(parquetURL: url)
        // "name1" matches name1 and name10..name19 → 11 rows.
        XCTAssertEqual(try source.rowCount(matching: TableQuerySpec(search: "name1")), 11)
    }

    func testNumericSortDescending() throws {
        let url = try makeParquet()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try DuckDBTableSource(parquetURL: url)
        // Sorting must be numeric (by typed column), not lexicographic on VARCHAR.
        let spec = TableQuerySpec(sortColumn: 0, sortAscending: false)
        let page = try source.page(matching: spec, offset: 0, limit: 3)
        XCTAssertEqual(page.map { $0[0] }, ["99", "98", "97"])
    }
}
