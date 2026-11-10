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

    // MARK: - row permutation

    func testPermuteRowsAndInverseRoundTrip() {
        var doc = makeDocument(headers: ["id", "name"], rows: [["2", "Beta"], ["1", "Alpha"], ["3", "Gamma"]])
        let order = [1, 0, 2]
        doc.permuteRows(order)
        XCTAssertEqual(doc.rows.map { $0[0] }, ["1", "2", "3"])
        XCTAssertTrue(doc.dirty)
        doc.permuteRows(TableDocument.inversePermutation(order))
        XCTAssertEqual(doc.rows.map { $0[0] }, ["2", "1", "3"])
    }

    func testPermuteRowsRejectsNonPermutation() {
        let rows = [["a"], ["b"], ["c"]]
        var doc = makeDocument(headers: ["x"], rows: rows)
        doc.permuteRows([0, 0, 2])
        doc.permuteRows([0, 1])
        XCTAssertEqual(doc.rows, rows)
        XCTAssertFalse(doc.dirty)
        var readOnly = makeDocument(headers: ["x"], rows: rows, readOnly: true)
        readOnly.permuteRows([2, 1, 0])
        XCTAssertEqual(readOnly.rows, rows)
    }

    func testInversePermutation() {
        XCTAssertEqual(TableDocument.inversePermutation([2, 0, 1]), [1, 2, 0])
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
