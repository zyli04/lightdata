import XCTest
@testable import LightDataCore

/// Regression tests for CSV delimiter auto-detection. Real-world Twitter/Reddit
/// export CSVs have very long first records (post bodies with embedded newlines and
/// occasional '|' characters), which fooled the byte-window sampler into choosing
/// '|' over ',' — shattering the whole table into one column of raw text.
final class DelimiterDetectionTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightdata-delimiter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A comma CSV whose first data row is a huge quoted field containing many newlines
    /// and a few '|' characters. The byte-window sampler used to see mostly one broken
    /// record for ',' but many 2-column fragments for '|', and picked '|'. The field is
    /// deliberately larger than the 16 KB detection window to reproduce the real file.
    func testLongFirstFieldDoesNotDefeatCommaDetection() throws {
        let hugeBody = (0..<800).map { "line \($0) of the post | with a pipe char" }.joined(separator: "\n")
        XCTAssertGreaterThan(hugeBody.utf8.count, 20_000, "first field must exceed the detection window")
        var csv = "id,author,text,likes\n"
        csv += "1,alice,\"\(hugeBody)\",42\n"
        for i in 2...30 {
            csv += "\(i),user\(i),\"short post \(i)\",\(i)\n"
        }
        let url = tempDir.appendingPathComponent("twitter.csv")
        try Data(csv.utf8).write(to: url)

        let doc = try TableDocument.load(url: url)
        XCTAssertEqual(doc.headers, ["id", "author", "text", "likes"],
                       "must parse as 4 comma-separated columns, not one pipe 'column'")
        XCTAssertEqual(doc.rows.count, 30)
        XCTAssertTrue(doc.rows[0][2].contains("line 799"), "the long body stays in one cell")
        XCTAssertEqual(doc.rows[1], ["2", "user2", "short post 2", "2"])
    }

    /// A genuinely pipe-delimited file must still be detected as pipe.
    func testGenuinePipeDelimitedStillDetected() throws {
        var psv = "id|name|city\n"
        for i in 1...20 { psv += "\(i)|name\(i)|city\(i)\n" }
        let url = tempDir.appendingPathComponent("data.csv")
        try Data(psv.utf8).write(to: url)

        let doc = try TableDocument.load(url: url)
        XCTAssertEqual(doc.headers, ["id", "name", "city"])
        XCTAssertEqual(doc.rows.first, ["1", "name1", "city1"])
    }

    /// Genuine TSV detection is unaffected.
    func testGenuineTabDelimitedStillDetected() throws {
        var tsv = "a\tb\tc\n"
        for i in 1...20 { tsv += "\(i)\tx\(i)\ty\(i)\n" }
        let url = tempDir.appendingPathComponent("data.csv")   // .csv ext, tab content
        try Data(tsv.utf8).write(to: url)

        let doc = try TableDocument.load(url: url)
        XCTAssertEqual(doc.headers, ["a", "b", "c"])
    }

    /// A plain comma file with short rows keeps working.
    func testPlainCommaDetection() throws {
        let url = tempDir.appendingPathComponent("plain.csv")
        try Data("x,y,z\n1,2,3\n4,5,6\n".utf8).write(to: url)
        let doc = try TableDocument.load(url: url)
        XCTAssertEqual(doc.headers, ["x", "y", "z"])
        XCTAssertEqual(doc.rows.count, 2)
    }
}

/// Pins the exact semantics of DelimitedTextParser.parse before/after performance
/// work: quoting, escaped quotes, embedded newlines, CR/CRLF normalization, emoji,
/// and trailing-newline handling must not change.
final class ParseSemanticsTests: XCTestCase {
    private func parse(_ text: String, delimiter: Character = ",") -> [[String]] {
        DelimitedTextParser.parse(text, delimiter: delimiter)
    }

    func testEscapedQuotesInsideQuotedField() {
        XCTAssertEqual(parse("a,\"he said \"\"hi\"\"\",c\n"),
                       [["a", "he said \"hi\"", "c"]])
    }

    func testEmbeddedNewlineAndCRLFInsideQuotes() {
        XCTAssertEqual(parse("a,\"line1\nline2\",z\n"),
                       [["a", "line1\nline2", "z"]])
        // CRLF inside quotes normalizes to LF
        XCTAssertEqual(parse("a,\"line1\r\nline2\",z\r\n"),
                       [["a", "line1\nline2", "z"]])
    }

    func testCRAndCRLFRecordSeparators() {
        XCTAssertEqual(parse("a,b\r\nc,d\r\n"), [["a", "b"], ["c", "d"]])
        XCTAssertEqual(parse("a,b\rc,d\r"), [["a", "b"], ["c", "d"]])
    }

    func testQuoteAppearingMidFieldIsLiteral() {
        // A quote NOT at field start is data, not a quoting toggle.
        XCTAssertEqual(parse("say \"hi\",b\n"), [["say \"hi\"", "b"]])
    }

    func testEmojiAndMultiScalarGraphemes() {
        XCTAssertEqual(parse("👩‍👩‍👧‍👦,\"🇨🇳 flag\",ok\n"),
                       [["👩‍👩‍👧‍👦", "🇨🇳 flag", "ok"]])
    }

    func testNoTrailingNewlineLastRecordKept() {
        XCTAssertEqual(parse("a,b\nc,d"), [["a", "b"], ["c", "d"]])
    }

    func testBlankLineDroppedButEmptyColumnsRowKept() {
        XCTAssertEqual(parse("a,b\n\n,\n"), [["a", "b"], ["", ""]])
    }

    func testUnterminatedQuoteConsumesRest() {
        XCTAssertEqual(parse("a,\"unclosed\nstill inside"),
                       [["a", "unclosed\nstill inside"]])
    }

    func testQuotedFieldFollowedByText() {
        // Content after the closing quote (nonstandard) is appended literally.
        XCTAssertEqual(parse("\"x\"tail,b\n"), [["xtail", "b"]])
    }
}
