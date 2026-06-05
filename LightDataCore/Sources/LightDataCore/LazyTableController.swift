import Foundation

/// Drives a lazy, paged, read-only table view over a `DuckDBTableSource`.
///
/// Loading is **viewport-driven**: the UI reports the visible block (row range +
/// visible columns) via `updateViewport`, and the controller fetches that whole
/// block in a single query (plus a small prefetch margin), then fills it atomically.
/// This keeps the visible area coherent — you never see a half-loaded viewport with
/// some rows/columns filled and others not.
///
/// All DuckDB access is confined to one serial, lowered-priority queue (the
/// connection is not thread-safe, and we don't want scans starving the UI). A
/// generation token invalidates in-flight work when the query changes; a viewport
/// token supersedes an outdated scroll position.
public final class LazyTableController {
    private let source: DuckDBTableSource
    // .utility QoS keeps result marshalling below the UI's user-interactive priority.
    private let queue = DispatchQueue(label: "com.zyli.LightData.lazytable", qos: .utility)

    private var cache: PageCache
    private var spec = TableQuerySpec()
    /// Bumped on every query change; fetches tagged with an old value are dropped.
    private var generation = 0
    /// Bumped on every viewport change; an in-flight block fetch for an older value
    /// still fills the cache (useful) but triggers a follow-up for the latest view.
    private var viewportToken = 0
    private var isFetching = false
    private var visibleColumns: [Int]
    /// Latest requested viewport, refetched once the current fetch finishes.
    private var pendingRowRange: Range<Int>?
    /// Extra pages fetched above/below the viewport for smoother scrolling.
    private let prefetchMargin = 1

    public private(set) var rowCount = 0

    /// Called on the main queue when fetched rows become available.
    public var onRowsLoaded: ((IndexSet) -> Void)?
    /// Called on the main queue when the matching row count changes.
    public var onRowCountChanged: ((Int) -> Void)?

    public var headers: [String] { source.headers }
    public var pageSize: Int { cache.pageSize }

    public init(source: DuckDBTableSource, pageSize: Int = 200, cachePages: Int = 80) {
        self.source = source
        self.cache = PageCache(pageSize: pageSize, capacity: cachePages)
        self.visibleColumns = Array(source.headers.indices)
    }

    /// Kicks off the initial row-count query. Call once after construction.
    public func start() {
        refreshCount()
    }

    /// Returns a cell's display string if cached, else nil (show a placeholder).
    /// Pure cache read — fetching is driven by `updateViewport`.
    public func value(row: Int, column: Int) -> String? {
        cache.value(row: row, column: column)
    }

    /// Reports the currently visible block. Fetches the covering pages (for these
    /// columns) in one query if any are missing. Cheap no-op when already cached.
    public func updateViewport(rows rowRange: Range<Int>, columns: [Int]) {
        let cols = normalized(columns)
        let columnsChanged = cols != visibleColumns
        visibleColumns = cols
        guard rowCount > 0, !rowRange.isEmpty else { return }

        viewportToken += 1
        pendingRowRange = rowRange
        if columnsChanged {
            // Newly-revealed columns may be missing on already-cached pages; the
            // coverage check below handles it, nothing else needed here.
        }
        fetchPendingIfNeeded()
    }

    /// Replaces the active query (search/filter/sort), clearing cached pages and
    /// recomputing the row count. No-op if the spec is unchanged.
    public func setQuery(_ newSpec: TableQuerySpec) {
        guard newSpec != spec else { return }
        spec = newSpec
        generation += 1
        cache.removeAll()
        refreshCount()
    }

    // MARK: - Internals

    private func normalized(_ columns: [Int]) -> [Int] {
        let filtered = columns.filter { source.headers.indices.contains($0) }
        return filtered.isEmpty ? Array(source.headers.indices) : filtered
    }

    private func refreshCount() {
        let gen = generation
        let spec = self.spec
        queue.async { [weak self] in
            guard let self else { return }
            let count = (try? self.source.rowCount(matching: spec)) ?? 0
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.rowCount = count
                self.onRowCountChanged?(count)
                self.fetchPendingIfNeeded()
            }
        }
    }

    private func lastPage() -> Int {
        rowCount > 0 ? (rowCount - 1) / cache.pageSize : 0
    }

    private func fetchPendingIfNeeded() {
        guard !isFetching, rowCount > 0, let rowRange = pendingRowRange else { return }
        let ps = cache.pageSize
        let firstPage = max(0, rowRange.lowerBound / ps)
        let visibleLast = min(lastPage(), max(0, rowRange.upperBound - 1) / ps)
        let startPage = max(0, firstPage - prefetchMargin)
        let endPage = min(lastPage(), visibleLast + prefetchMargin)
        guard startPage <= endPage else { return }

        // Pages that are missing at least one visible column.
        let needed = (startPage...endPage).filter { !cache.hasColumns(visibleColumns, page: $0) }
        guard let lo = needed.min(), let hi = needed.max() else {
            pendingRowRange = nil
            return
        }
        // Fetch ONLY the columns actually missing across those pages, not the whole
        // visible set. This keeps a one-column horizontal scroll (or scrolling back to
        // already-cached columns) from needlessly re-fetching columns we already have.
        let cols = visibleColumns.filter { column in
            needed.contains { !cache.hasColumns([column], page: $0) }
        }
        guard !cols.isEmpty else {
            pendingRowRange = nil
            return
        }

        isFetching = true
        let gen = generation
        let token = viewportToken
        let spec = self.spec
        let offset = lo * ps
        let limit = (hi - lo + 1) * ps
        queue.async { [weak self] in
            guard let self else { return }
            let fetched: (data: [Int: [String]], rowCount: Int)
            fetched = (try? self.source.columns(cols, matching: spec, offset: offset, limit: limit)) ?? (data: [:], rowCount: 0)
            DispatchQueue.main.async {
                self.isFetching = false
                if gen == self.generation, fetched.rowCount > 0 {
                    self.storeBlock(fetched.data, firstPage: lo, totalRows: fetched.rowCount)
                    self.onRowsLoaded?(IndexSet(integersIn: offset..<(offset + fetched.rowCount)))
                }
                // If the viewport moved while fetching, fetch the latest now.
                if token != self.viewportToken {
                    self.fetchPendingIfNeeded()
                } else {
                    self.pendingRowRange = nil
                }
            }
        }
    }

    /// Splits a multi-page fetch result into page-aligned cache entries.
    private func storeBlock(_ data: [Int: [String]], firstPage: Int, totalRows: Int) {
        let ps = cache.pageSize
        var page = firstPage
        var start = 0
        while start < totalRows {
            let end = min(start + ps, totalRows)
            var pageColumns: [Int: [String]] = [:]
            for (column, values) in data {
                pageColumns[column] = Array(values[start..<min(end, values.count)])
            }
            cache.insert(page: page, columns: pageColumns, rowCount: end - start)
            page += 1
            start += ps
        }
    }
}
