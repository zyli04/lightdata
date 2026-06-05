import XCTest
@testable import LightDataCore

final class PageCacheTests: XCTestCase {
    /// Builds a column dict from a single column 0's values.
    private func col0(_ values: [String]) -> [Int: [String]] { [0: values] }

    func testIndexingMath() {
        let cache = PageCache(pageSize: 10, capacity: 3)
        XCTAssertEqual(cache.pageIndex(forRow: 0), 0)
        XCTAssertEqual(cache.pageIndex(forRow: 9), 0)
        XCTAssertEqual(cache.pageIndex(forRow: 10), 1)
        XCTAssertEqual(cache.offset(ofPage: 2), 20)
    }

    func testMissThenHit() {
        var cache = PageCache(pageSize: 2, capacity: 3)
        XCTAssertNil(cache.value(row: 3, column: 0))
        cache.insert(page: 1, columns: col0(["a", "b"]), rowCount: 2) // rows 2,3
        XCTAssertEqual(cache.value(row: 2, column: 0), "a")
        XCTAssertEqual(cache.value(row: 3, column: 0), "b")
    }

    func testColumnAwareCaching() {
        var cache = PageCache(pageSize: 2, capacity: 3)
        cache.insert(page: 0, columns: [0: ["a", "b"]], rowCount: 2)
        XCTAssertTrue(cache.hasColumns([0], page: 0))
        XCTAssertFalse(cache.hasColumns([0, 1], page: 0))
        XCTAssertNil(cache.value(row: 0, column: 1))
        // Merging another column keeps the first.
        cache.insert(page: 0, columns: [1: ["x", "y"]], rowCount: 2)
        XCTAssertTrue(cache.hasColumns([0, 1], page: 0))
        XCTAssertEqual(cache.value(row: 0, column: 0), "a")
        XCTAssertEqual(cache.value(row: 1, column: 1), "y")
    }

    func testLRUEviction() {
        var cache = PageCache(pageSize: 1, capacity: 2)
        cache.insert(page: 0, columns: col0(["0"]), rowCount: 1)
        cache.insert(page: 1, columns: col0(["1"]), rowCount: 1)
        _ = cache.value(row: 0, column: 0)          // touch page 0 → page 1 now LRU
        cache.insert(page: 2, columns: col0(["2"]), rowCount: 1)    // evicts page 1
        XCTAssertTrue(cache.contains(page: 0))
        XCTAssertFalse(cache.contains(page: 1))
        XCTAssertTrue(cache.contains(page: 2))
    }

    func testRemoveAll() {
        var cache = PageCache(pageSize: 2, capacity: 3)
        cache.insert(page: 0, columns: col0(["a", "b"]), rowCount: 2)
        cache.removeAll()
        XCTAssertFalse(cache.contains(page: 0))
        XCTAssertNil(cache.value(row: 0, column: 0))
    }
}
