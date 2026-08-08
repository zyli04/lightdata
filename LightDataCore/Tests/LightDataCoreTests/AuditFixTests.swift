import XCTest
@testable import LightDataCore

/// Tests for the 2026-07 audit fixes in the core layer: ragged/empty-row load
/// fidelity, rename collision isolation, lazy-shell export refusal, sort ordering,
/// and metadata identity surviving a save.
final class AuditFixTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightdata-audit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - DelimitedTextParser: ragged rows are not truncated

    func testRowsWiderThanHeaderWidenTheTable() throws {
        let url = tempDir.appendingPathComponent("ragged.csv")
        try Data("a,b,c\n1,2,3,4,5\n6,7,8\n".utf8).write(to: url)
        let doc = try TableDocument.load(url: url)
        XCTAssertEqual(doc.headers, ["a", "b", "c", "Column 4", "Column 5"])
        XCTAssertEqual(doc.rows[0], ["1", "2", "3", "4", "5"], "wide row must not be truncated")
        XCTAssertEqual(doc.rows[1], ["6", "7", "8", "", ""])
    }

    // MARK: - DelimitedTextParser: all-empty rows survive, blank lines are skipped

    func testAllEmptyRowSurvivesRoundTripButBlankLineIsSkipped() throws {
        let url = tempDir.appendingPathComponent("empties.csv")
        try Data("a,b,c\n,,\n\n1,2,3\n".utf8).write(to: url)
        var doc = try TableDocument.load(url: url)
        XCTAssertEqual(doc.rows.count, 2, "',,' row kept; blank line dropped")
        XCTAssertEqual(doc.rows[0], ["", "", ""])
        XCTAssertEqual(doc.rows[1], ["1", "2", "3"])

        try doc.save()
        let reloaded = try TableDocument.load(url: url)
        XCTAssertEqual(reloaded.rows, doc.rows, "empty row must survive save/reload")
    }

    // MARK: - renameColumn: collision only affects the renamed column

    func testRenameCollisionDoesNotRenameOtherColumn() throws {
        let url = tempDir.appendingPathComponent("rename.csv")
        try Data("Age,Name\n1,x\n".utf8).write(to: url)
        var doc = try TableDocument.load(url: url)
        doc.renameColumn(at: 0, to: "Name")
        XCTAssertEqual(doc.headers[1], "Name", "existing column must keep its name")
        XCTAssertEqual(doc.headers[0], "Name 2", "renamed column takes the suffix")
    }

    func testRenameToItselfIsStable() throws {
        let url = tempDir.appendingPathComponent("rename2.csv")
        try Data("a,b\n1,2\n".utf8).write(to: url)
        var doc = try TableDocument.load(url: url)
        doc.renameColumn(at: 0, to: "a")
        XCTAssertEqual(doc.headers, ["a", "b"], "renaming a column to its own name is a no-op")
    }

    // MARK: - write(to:): lazy header-only shell must refuse to export

    func testLazyShellExportThrowsInsteadOfWritingEmptyFile() {
        let doc = TableDocument.lazyHeaderOnly(
            url: tempDir.appendingPathComponent("big.parquet"),
            format: .parquet,
            headers: ["a", "b"],
            readOnlyReason: "test"
        )
        let target = tempDir.appendingPathComponent("out.csv")
        XCTAssertThrowsError(try doc.write(to: target, as: .csv))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "no empty file may be left behind")
    }

    // MARK: - Sort: single comparison domain, transitive, empties last, stable

    private func makeDoc(column: [String]) throws -> TableDocument {
        let url = tempDir.appendingPathComponent("sort-\(UUID().uuidString).csv")
        let body = column.map { $0.isEmpty ? "" : $0 }.joined(separator: "\n")
        try Data(("v\n" + body + "\n").utf8).write(to: url)
        return try TableDocument.load(url: url)
    }

    private func sortedValues(_ values: [String], ascending: Bool) throws -> [String] {
        let doc = try makeDoc(column: values)
        let indexes = TableQueryEngine.visibleRows(
            in: doc, search: "", filter: nil,
            sortDescriptor: NSSortDescriptor(key: "0", ascending: ascending)
        )
        return indexes.map { doc.rows[$0][0] }
    }

    func testMixedColumnSortsInOneStringDomain() throws {
        // The old per-pair comparator had cycles here ("1e3" < "5x" < "20" < "1e3"
        // via numeric pairs). A mixed column must use string ordering for ALL values;
        // localizedStandardCompare is Finder-style (embedded numbers compare
        // numerically: 1 < 5 < 20) and is a single transitive domain.
        let sorted = try sortedValues(["5x", "1e3", "20"], ascending: true)
        XCTAssertEqual(sorted, ["1e3", "5x", "20"], "one consistent string domain for a mixed column")
    }

    func testAllNumericColumnSortsNumerically() throws {
        let sorted = try sortedValues(["10", "9", "1e3", "-2"], ascending: true)
        XCTAssertEqual(sorted, ["-2", "9", "10", "1e3"], "numeric domain: 1e3 sorts as 1000")
    }

    func testEmptiesSinkToBottomInBothDirections() throws {
        // Two columns: in 1-column CSV an empty row IS a blank line (and is skipped);
        // here the sort column is empty while the id column keeps the row alive.
        let url = tempDir.appendingPathComponent("sort-empty.csv")
        try Data("v,id\nb,1\n,2\na,3\n".utf8).write(to: url)
        let doc = try TableDocument.load(url: url)
        for ascending in [true, false] {
            let indexes = TableQueryEngine.visibleRows(
                in: doc, search: "", filter: nil,
                sortDescriptor: NSSortDescriptor(key: "0", ascending: ascending)
            )
            let sorted = indexes.map { doc.rows[$0][0] }
            XCTAssertEqual(sorted.last, "", "empty sinks to bottom (ascending=\(ascending))")
            XCTAssertEqual(sorted.dropLast(), ascending ? ["a", "b"] : ["b", "a"])
        }
    }

    func testNaNValueDoesNotPoisonNumericDomain() throws {
        // "nan" parses as Double.nan (not finite) → column must use the string domain,
        // avoiding NaN's non-transitive numeric comparisons. Finder-style compare puts
        // "2" before "10" (embedded numbers), then "nan".
        let sorted = try sortedValues(["nan", "2", "10"], ascending: true)
        XCTAssertEqual(sorted, ["2", "10", "nan"], "string domain because of nan")
    }

    // MARK: - Save preserves metadata identity (path-keyed, inode-agnostic)

    func testViewMetadataSurvivesSave() throws {
        let url = tempDir.appendingPathComponent("meta.csv")
        try Data("a,b\n1,2\n".utf8).write(to: url)

        var metadata = ViewMetadata()
        metadata.columnWidths = ["a": 321]
        ViewMetadataStore.save(metadata, for: url)
        XCTAssertEqual(ViewMetadataStore.load(for: url).columnWidths["a"], 321)

        // Save rewrites the file (new inode on APFS). Metadata must still resolve.
        var doc = try TableDocument.load(url: url)
        doc.setValue("9", row: 0, column: 0)
        try doc.save()

        XCTAssertEqual(
            ViewMetadataStore.load(for: url).columnWidths["a"], 321,
            "view metadata must survive an in-place save (path-keyed identity)"
        )
    }

    // MARK: - Encoding: unrepresentable text throws instead of silent UTF-8 rewrite

    func testLatin1UnrepresentableCharacterThrowsOnSave() throws {
        let url = tempDir.appendingPathComponent("latin1.csv")
        // é in Latin-1 (0xE9) after invalid-UTF-8 lead: forces the Latin-1 branch.
        try Data([UInt8]("a,b\nx,".utf8) + [0xE9] + [UInt8]("\n".utf8)).write(to: url)
        var doc = try TableDocument.load(url: url)
        XCTAssertEqual(doc.openInfo.encoding, .latin1)
        XCTAssertFalse(doc.readOnly)

        let original = try Data(contentsOf: url)
        doc.setValue("→", row: 0, column: 0)   // not representable in Latin-1
        XCTAssertThrowsError(try doc.save()) { error in
            XCTAssertTrue(error is EncodingUnrepresentableError)
        }
        XCTAssertEqual(try Data(contentsOf: url), original, "file must be untouched after a failed save")
    }

    // MARK: - UTF-16 detection: decodes for viewing, opens read-only

    func testUTF16LEWithBOMDecodesReadOnly() throws {
        let url = tempDir.appendingPathComponent("utf16.csv")
        let text = "a,b\n1,héllo\n"
        var data = Data([0xFF, 0xFE])
        data.append(contentsOf: text.data(using: .utf16LittleEndian)!)
        try data.write(to: url)

        let doc = try TableDocument.load(url: url)
        XCTAssertTrue(doc.readOnly, "UTF-16 must open read-only (writer can't emit it)")
        XCTAssertEqual(doc.headers, ["a", "b"])
        XCTAssertEqual(doc.rows, [["1", "héllo"]], "content decodes correctly, not as NUL mojibake")
    }

    func testBOMlessUTF16IsDetectedNotMojibake() throws {
        let url = tempDir.appendingPathComponent("utf16-nobom.tsv")
        let text = "name\tvalue\nalpha\t1\nbeta\t2\n"
        try text.data(using: .utf16LittleEndian)!.write(to: url)

        let doc = try TableDocument.load(url: url)
        XCTAssertTrue(doc.readOnly)
        XCTAssertEqual(doc.headers, ["name", "value"])
        XCTAssertEqual(doc.rows.first, ["alpha", "1"])
    }

    // MARK: - JSON: lossy content opens read-only; flat string JSON stays editable

    func testJSONWithNumbersOpensReadOnly() throws {
        let url = tempDir.appendingPathComponent("typed.json")
        try Data(#"[{"a": {"b": 1}, "n": null}]"#.utf8).write(to: url)
        let doc = try TableDocument.load(url: url)
        XCTAssertTrue(doc.readOnly, "nested/numeric/null JSON must open read-only")
        XCTAssertNotNil(doc.openInfo.readOnlyReason)
    }

    func testFlatStringJSONStaysEditable() throws {
        let url = tempDir.appendingPathComponent("flat.json")
        try Data(#"[{"a": "1", "b": "x"}, {"a": "2", "b": "y"}]"#.utf8).write(to: url)
        var doc = try TableDocument.load(url: url)
        XCTAssertFalse(doc.readOnly, "flat all-string JSON round-trips faithfully; stays editable")
        doc.setValue("3", row: 0, column: 0)
        try doc.save()
        let reloaded = try TableDocument.load(url: url)
        XCTAssertEqual(reloaded.rows[0][0], "3")
    }

    func testJSONLWithBooleanOpensReadOnly() throws {
        let url = tempDir.appendingPathComponent("typed.jsonl")
        try Data("{\"a\": \"x\"}\n{\"a\": true}\n".utf8).write(to: url)
        let doc = try TableDocument.load(url: url)
        XCTAssertTrue(doc.readOnly)
    }

    func testDeepJSONNestingIsCappedNotRecursedInto() throws {
        // JSONSerialization itself rejects ~512+ nesting levels, so parsing can't
        // stack-overflow; this covers flatten's own cap (64): levels beyond it must be
        // stringified into one cell, not recursed into.
        let depth = 300
        let json = "[{" + String(repeating: "\"a\":{", count: depth) + "\"v\":\"x\"" + String(repeating: "}", count: depth) + "}]"
        let url = tempDir.appendingPathComponent("deep.json")
        try Data(json.utf8).write(to: url)
        let doc = try TableDocument.load(url: url)
        XCTAssertEqual(doc.rows.count, 1)
        XCTAssertEqual(doc.headers.count, 1, "capped: one dot-path column, remainder stringified")
        XCTAssertTrue(doc.readOnly, "nested JSON is lossy → read-only")
    }
}
