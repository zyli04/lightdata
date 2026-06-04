import Foundation

/// Drives a lazy, paged, read-only table view over a `DuckDBTableSource`.
///
/// All DuckDB access is confined to one serial queue (the connection is not
/// thread-safe). The UI asks for cell values synchronously via `value(row:column:)`;
/// a cache hit returns immediately, a miss returns nil (show a placeholder) and
/// schedules a background page fetch. Results are delivered on the main queue via
/// `onRowsLoaded` / `onRowCountChanged`. A generation token invalidates in-flight
/// work whenever the query changes, so stale pages never overwrite fresh state.
public final class LazyTableController {
    private let source: DuckDBTableSource
    private let queue = DispatchQueue(label: "com.zyli.LightData.lazytable")

    private var cache: PageCache
    private var spec = TableQuerySpec()
    /// Bumped on every query change; fetches tagged with an old value are dropped.
    private var generation = 0
    /// Pages currently being fetched (per generation), to coalesce duplicate requests.
    private var inFlight: Set<Int> = []

    public private(set) var rowCount = 0

    /// Called on the main queue when a fetched page's rows become available.
    public var onRowsLoaded: ((IndexSet) -> Void)?
    /// Called on the main queue when the matching row count changes.
    public var onRowCountChanged: ((Int) -> Void)?

    public var headers: [String] { source.headers }
    public var pageSize: Int { cache.pageSize }

    public init(source: DuckDBTableSource, pageSize: Int = 500, cachePages: Int = 40) {
        self.source = source
        self.cache = PageCache(pageSize: pageSize, capacity: cachePages)
    }

    /// Kicks off the initial row-count query. Call once after construction.
    public func start() {
        refreshCount()
    }

    /// Returns a cell's display string if its page is cached, else nil and schedules
    /// a fetch. Safe to call rapidly from the main thread during scrolling.
    public func value(row: Int, column: Int) -> String? {
        if let cached = cache.value(row: row, column: column) {
            return cached
        }
        requestPage(containing: row)
        return nil
    }

    /// Replaces the active query (search/filter/sort), clearing cached pages and
    /// recomputing the row count. No-op if the spec is unchanged.
    public func setQuery(_ newSpec: TableQuerySpec) {
        guard newSpec != spec else { return }
        spec = newSpec
        invalidate()
        refreshCount()
    }

    // MARK: - Internals

    private func invalidate() {
        generation += 1
        cache.removeAll()
        inFlight.removeAll()
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
            }
        }
    }

    private func requestPage(containing row: Int) {
        guard row >= 0 else { return }
        let page = cache.pageIndex(forRow: row)
        guard !cache.contains(page: page), !inFlight.contains(page) else { return }
        inFlight.insert(page)

        let gen = generation
        let spec = self.spec
        let offset = cache.offset(ofPage: page)
        let limit = cache.pageSize
        queue.async { [weak self] in
            guard let self else { return }
            let rows = (try? self.source.page(matching: spec, offset: offset, limit: limit)) ?? []
            DispatchQueue.main.async {
                self.inFlight.remove(page)
                guard gen == self.generation, !rows.isEmpty else { return }
                self.cache.insert(page: page, rows: rows)
                let range = offset..<(offset + rows.count)
                self.onRowsLoaded?(IndexSet(integersIn: range))
            }
        }
    }
}
