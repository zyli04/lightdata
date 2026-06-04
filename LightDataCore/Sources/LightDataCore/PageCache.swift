import Foundation

/// A fixed-capacity LRU cache of row pages, keyed by page index. Pure value logic
/// (no threading) so it can be unit-tested in isolation; the owning controller is
/// responsible for confining access to a single queue.
struct PageCache {
    let pageSize: Int
    let capacity: Int

    private var pages: [Int: [[String]]] = [:]
    /// Most-recently-used page indices last.
    private var usage: [Int] = []

    init(pageSize: Int, capacity: Int) {
        self.pageSize = max(1, pageSize)
        self.capacity = max(1, capacity)
    }

    /// The page index that contains the given display row.
    func pageIndex(forRow row: Int) -> Int { row / pageSize }

    /// Offset of a page's first row in the overall result.
    func offset(ofPage page: Int) -> Int { page * pageSize }

    mutating func value(row: Int, column: Int) -> String? {
        let page = pageIndex(forRow: row)
        guard let rows = pages[page] else { return nil }
        touch(page)
        let local = row - offset(ofPage: page)
        guard rows.indices.contains(local), rows[local].indices.contains(column) else { return nil }
        return rows[local][column]
    }

    func contains(page: Int) -> Bool { pages[page] != nil }

    mutating func insert(page: Int, rows: [[String]]) {
        pages[page] = rows
        touch(page)
        evictIfNeeded()
    }

    mutating func removeAll() {
        pages.removeAll()
        usage.removeAll()
    }

    private mutating func touch(_ page: Int) {
        if let index = usage.firstIndex(of: page) {
            usage.remove(at: index)
        }
        usage.append(page)
    }

    private mutating func evictIfNeeded() {
        while pages.count > capacity, let oldest = usage.first {
            usage.removeFirst()
            pages.removeValue(forKey: oldest)
        }
    }
}
