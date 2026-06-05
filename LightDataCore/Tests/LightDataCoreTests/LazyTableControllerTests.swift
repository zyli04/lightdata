import XCTest
import DuckDB
@testable import LightDataCore

final class LazyTableControllerTests: XCTestCase {
    /// 100-row Parquet: id 0..99, grp = i % 3.
    private func makeParquet() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightdata-lazy-\(UUID().uuidString).parquet")
        let database = try Database(store: .inMemory)
        let connection = try database.connect()
        let path = url.path.replacingOccurrences(of: "'", with: "''")
        _ = try connection.query(
            "COPY (SELECT i AS id, (i % 3) AS grp FROM range(0, 100) t(i)) "
            + "TO '\(path)' (FORMAT PARQUET)"
        )
        return url
    }

    func testCountAndLazyLoad() throws {
        let url = try makeParquet()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try DuckDBTableSource(parquetURL: url)
        let controller = LazyTableController(source: source, pageSize: 10, cachePages: 5)

        let countExpectation = expectation(description: "count")
        controller.onRowCountChanged = { count in
            XCTAssertEqual(count, 100)
            countExpectation.fulfill()
        }
        controller.start()
        wait(for: [countExpectation], timeout: 5)
        XCTAssertEqual(controller.rowCount, 100)

        // Initially a miss (nil); reporting the viewport schedules a coherent fetch.
        XCTAssertNil(controller.value(row: 25, column: 0))
        let loadExpectation = expectation(description: "block loaded")
        controller.onRowsLoaded = { rows in
            if rows.contains(25) { loadExpectation.fulfill() }
        }
        controller.updateViewport(rows: 20..<30, columns: [0, 1])
        wait(for: [loadExpectation], timeout: 5)

        // After load it's a synchronous hit with the right value.
        XCTAssertEqual(controller.value(row: 25, column: 0), "25")
        XCTAssertEqual(controller.value(row: 25, column: 1), "1") // 25 % 3
    }

    func testSetQueryInvalidatesAndRecounts() throws {
        let url = try makeParquet()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try DuckDBTableSource(parquetURL: url)
        let controller = LazyTableController(source: source, pageSize: 10, cachePages: 5)

        let initial = expectation(description: "initial count")
        controller.onRowCountChanged = { _ in initial.fulfill() }
        controller.start()
        wait(for: [initial], timeout: 5)

        let filtered = expectation(description: "filtered count")
        controller.onRowCountChanged = { count in
            XCTAssertEqual(count, 34) // i % 3 == 0 for i in 0..99 → 34
            filtered.fulfill()
        }
        controller.setQuery(TableQuerySpec(filter: TableFilter(columnIndex: 1, operation: .equals, value: "0")))
        wait(for: [filtered], timeout: 5)
        XCTAssertEqual(controller.rowCount, 34)
    }
}
