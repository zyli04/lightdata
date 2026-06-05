import Foundation

/// A fixed-capacity LRU cache of row pages. Each page stores data per column so
/// only the columns the UI actually shows need to be fetched/held — important for
/// wide tables where fetching every column is expensive. Pure value logic (no
/// threading); the owning controller confines access to a single queue.
struct PageCache {
    let pageSize: Int
    let capacity: Int

    private struct Entry {
        /// column index -> values for the rows in this page (length == rowCount)
        var columns: [Int: [String]] = [:]
        var rowCount: Int = 0
    }

    private var pages: [Int: Entry] = [:]
    /// Most-recently-used page indices last.
    private var usage: [Int] = []

    init(pageSize: Int, capacity: Int) {
        self.pageSize = max(1, pageSize)
        self.capacity = max(1, capacity)
    }

    func pageIndex(forRow row: Int) -> Int { row / pageSize }
    func offset(ofPage page: Int) -> Int { page * pageSize }

    mutating func value(row: Int, column: Int) -> String? {
        let page = pageIndex(forRow: row)
        guard let entry = pages[page], let values = entry.columns[column] else { return nil }
        touch(page)
        let local = row - offset(ofPage: page)
        guard values.indices.contains(local) else { return nil }
        return values[local]
    }

    /// True when the page already has all the requested columns cached.
    func hasColumns(_ columns: [Int], page: Int) -> Bool {
        guard let entry = pages[page] else { return false }
        return columns.allSatisfy { entry.columns[$0] != nil }
    }

    func contains(page: Int) -> Bool { pages[page] != nil }

    /// Merges fetched column data into a page (keeping any columns already cached).
    mutating func insert(page: Int, columns: [Int: [String]], rowCount: Int) {
        var entry = pages[page] ?? Entry()
        for (column, values) in columns {
            entry.columns[column] = values
        }
        entry.rowCount = max(entry.rowCount, rowCount)
        pages[page] = entry
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
