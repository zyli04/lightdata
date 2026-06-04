import XCTest
@testable import LightDataCore

final class PageCacheTests: XCTestCase {
    private func page(_ values: [String]) -> [[String]] { values.map { [$0] } }

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
        cache.insert(page: 1, rows: page(["a", "b"])) // rows 2,3
        XCTAssertEqual(cache.value(row: 2, column: 0), "a")
        XCTAssertEqual(cache.value(row: 3, column: 0), "b")
    }

    func testLRUEviction() {
        var cache = PageCache(pageSize: 1, capacity: 2)
        cache.insert(page: 0, rows: page(["0"]))
        cache.insert(page: 1, rows: page(["1"]))
        _ = cache.value(row: 0, column: 0)          // touch page 0 → page 1 now LRU
        cache.insert(page: 2, rows: page(["2"]))    // evicts page 1
        XCTAssertTrue(cache.contains(page: 0))
        XCTAssertFalse(cache.contains(page: 1))
        XCTAssertTrue(cache.contains(page: 2))
    }

    func testRemoveAll() {
        var cache = PageCache(pageSize: 2, capacity: 3)
        cache.insert(page: 0, rows: page(["a", "b"]))
        cache.removeAll()
        XCTAssertFalse(cache.contains(page: 0))
        XCTAssertNil(cache.value(row: 0, column: 0))
    }
}
