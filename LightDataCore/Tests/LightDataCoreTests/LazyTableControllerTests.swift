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

    func testFetchBlockReturnsRealValuesForUncachedRows() throws {
        let url = try makeParquet()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try DuckDBTableSource(parquetURL: url)
        let controller = LazyTableController(source: source, pageSize: 10, cachePages: 5)

        let counted = expectation(description: "count")
        controller.onRowCountChanged = { _ in counted.fulfill() }
        controller.start()
        wait(for: [counted], timeout: 5)

        // Rows 90..95 were never viewported → not in cache (value() is nil), which is
        // exactly the copy scenario that used to emit "…" placeholders.
        XCTAssertNil(controller.value(row: 92, column: 0))
        let block = controller.fetchBlock(rows: 90..<95, columns: [1, 0])
        XCTAssertEqual(block?.count, 5)
        XCTAssertEqual(block?[2], ["2", "92"], "row 92 in requested column order (grp, id)")
    }

    func testFetchBlockClampsInvalidColumnsAndEmptyRange() throws {
        let url = try makeParquet()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try DuckDBTableSource(parquetURL: url)
        let controller = LazyTableController(source: source, pageSize: 10, cachePages: 5)

        XCTAssertEqual(controller.fetchBlock(rows: 0..<0, columns: [0]), [])
        XCTAssertEqual(controller.fetchBlock(rows: 0..<5, columns: [99]), [])
    }

    func testQueryFailureSurfacesOnErrorAndStopsRetrying() throws {
        let url = try makeParquet()
        let source = try DuckDBTableSource(parquetURL: url)
        let controller = LazyTableController(source: source, pageSize: 10, cachePages: 5)

        let counted = expectation(description: "count")
        controller.onRowCountChanged = { _ in counted.fulfill() }
        controller.start()
        wait(for: [counted], timeout: 5)

        // Deleting the file mid-session makes every subsequent scan fail — the shape
        // of "file replaced/truncated during the watcher debounce".
        try FileManager.default.removeItem(at: url)

        let errored = expectation(description: "error surfaced")
        errored.assertForOverFulfill = false
        controller.onError = { _ in errored.fulfill() }
        var loads = 0
        controller.onRowsLoaded = { _ in loads += 1 }
        controller.updateViewport(rows: 0..<10, columns: [0, 1])
        wait(for: [errored], timeout: 5)
        XCTAssertEqual(loads, 0)

        // Further viewport reports for the same (failed) query must not refetch: the
        // failed-generation latch suppresses the per-scroll retry storm.
        var subsequentErrors = 0
        controller.onError = { _ in subsequentErrors += 1 }
        controller.updateViewport(rows: 10..<20, columns: [0, 1])
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settle.fulfill() }
        wait(for: [settle], timeout: 5)
        XCTAssertEqual(subsequentErrors, 0, "failed query must not be re-issued per viewport tick")
    }
}
