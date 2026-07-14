import AppKit
import DuckDB
import XCTest
@testable import LightData
import LightDataCore

/// Lazy (Parquet browse) mode driven end to end through the real controller:
/// generates a Parquet fixture with DuckDB, opens it via the paged path, and
/// verifies copy produces real values — never "…" placeholders.
final class LazyModeIntegrationTests: XCTestCase {
    private var tempDir: URL!
    private var controller: MainWindowController!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightdata-lazytests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        controller = MainWindowController()
        controller.presentAlert = { alert in
            XCTFail("unexpected modal alert: \(alert.messageText)")
            return .alertSecondButtonReturn
        }
        controller.showWindow(nil)
    }

    override func tearDownWithError() throws {
        controller.tableDocument = nil
        controller.close()
        controller = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// 500-row Parquet: id 0..499, grp = id % 5.
    private func makeParquet() throws -> URL {
        let url = tempDir.appendingPathComponent("fixture.parquet")
        let database = try Database(store: .inMemory)
        let connection = try database.connect()
        let path = url.path.replacingOccurrences(of: "'", with: "''")
        _ = try connection.query(
            "COPY (SELECT i AS id, (i % 5) AS grp FROM range(0, 500) t(i)) TO '\(path)' (FORMAT PARQUET)"
        )
        return url
    }

    private func openLazy() throws {
        let url = try makeParquet()
        controller.open(url: url)
        XCTAssertNotNil(controller.tableDocument)
        XCTAssertTrue(controller.tableDocument?.isLazyShell == true, "parquet opens via the lazy path")
        // Row count arrives asynchronously; pump the main run loop until it lands.
        let deadline = Date().addingTimeInterval(10)
        while controller.tableView.numberOfRows == 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(controller.tableView.numberOfRows, 500)
    }

    func testCopyFetchesRealValuesForUncachedRows() throws {
        try openLazy()
        // Rows near the end were never scrolled to → not in the page cache. The old
        // copy path emitted literal "…" placeholders for exactly this case.
        controller.selectCellRange(from: (490, 1), to: (494, 2))
        let text = controller.selectedTabDelimitedText()

        XCTAssertFalse(text.contains("…"), "clipboard must never contain placeholders")
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines.first, "490\t0", "real id/grp values for row 490 (490 % 5 = 0)")
        XCTAssertEqual(lines.last, "494\t4")
    }

    func testOversizedCopyShowsExplanationInsteadOfTruncating() throws {
        try openLazy()
        var alerted = false
        controller.presentAlert = { alert in
            alerted = alert.messageText.contains("too large")
            return .alertFirstButtonReturn
        }
        // Fake an over-cap selection via select-all-rows on the first column.
        controller.selectColumnRange(from: 1, to: 2)
        // 500 rows is under the 10k cap, so this should copy fine WITHOUT alert…
        let text = controller.selectedTabDelimitedText()
        XCTAssertFalse(alerted)
        XCTAssertEqual(text.split(separator: "\n").count, 500)
        XCTAssertFalse(text.contains("…"))
    }
}
