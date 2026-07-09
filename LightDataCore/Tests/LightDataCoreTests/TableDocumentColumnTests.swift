import XCTest
@testable import LightDataCore

final class TableDocumentColumnTests: XCTestCase {
    private func makeDocument(
        headers: [String],
        rows: [[String]],
        readOnly: Bool = false
    ) -> TableDocument {
        TableDocument(
            url: URL(fileURLWithPath: "/tmp/column-tests.csv"),
            format: .csv,
            headers: headers,
            rows: rows,
            readOnly: readOnly,
            openInfo: FileOpenInfo(encoding: nil, lineEnding: nil, delimiter: .comma, readOnlyReason: readOnly ? "test" : nil),
            loadedModificationDate: nil
        )
    }

    // MARK: - insertColumn

    func testInsertColumnInMiddle() {
        var doc = makeDocument(headers: ["a", "b"], rows: [["1", "2"], ["3", "4"]])
        doc.insertColumn(at: 1, named: "new")
        XCTAssertEqual(doc.headers, ["a", "new", "b"])
        XCTAssertEqual(doc.rows, [["1", "", "2"], ["3", "", "4"]])
        XCTAssertTrue(doc.dirty)
    }

    func testInsertColumnAtEndAndClampsIndex() {
        var doc = makeDocument(headers: ["a"], rows: [["1"]])
        doc.insertColumn(at: 99, named: "b")
        XCTAssertEqual(doc.headers, ["a", "b"])
        XCTAssertEqual(doc.rows, [["1", ""]])
    }

    func testInsertColumnWithValues() {
        var doc = makeDocument(headers: ["a"], rows: [["1"], ["2"], ["3"]])
        doc.insertColumn(at: 1, named: "b", values: ["x", "y"])
        XCTAssertEqual(doc.rows, [["1", "x"], ["2", "y"], ["3", ""]])
    }

    func testInsertColumnUniquesDuplicateName() {
        var doc = makeDocument(headers: ["a", "b"], rows: [])
        doc.insertColumn(at: 2, named: "a")
        XCTAssertEqual(doc.headers.count, 3)
        XCTAssertEqual(Set(doc.headers).count, 3, "headers should be unique: \(doc.headers)")
    }

    func testInsertColumnEmptyNameFallsBack() {
        var doc = makeDocument(headers: ["a"], rows: [])
        doc.insertColumn(at: 1, named: "   ")
        XCTAssertEqual(doc.headers, ["a", "Column 2"])
    }

    func testInsertColumnPadsRaggedRows() {
        var doc = makeDocument(headers: ["a", "b", "c"], rows: [["1"]])
        doc.insertColumn(at: 3, named: "d", values: ["z"])
        XCTAssertEqual(doc.rows, [["1", "", "", "z"]])
    }

    func testInsertColumnRefusedWhenReadOnly() {
        var doc = makeDocument(headers: ["a"], rows: [["1"]], readOnly: true)
        doc.insertColumn(at: 1, named: "b")
        XCTAssertEqual(doc.headers, ["a"])
        XCTAssertFalse(doc.dirty)
    }

    // MARK: - insert/delete round trip (the Add Column undo path)

    func testInsertThenDeleteRestoresOriginal() {
        var doc = makeDocument(headers: ["a", "b"], rows: [["1", "2"]])
        doc.insertColumn(at: 1, named: "new")
        doc.deleteColumn(at: 1)
        XCTAssertEqual(doc.headers, ["a", "b"])
        XCTAssertEqual(doc.rows, [["1", "2"]])
    }
}
