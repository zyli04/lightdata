import XCTest
@testable import LightDataCore

final class ColumnTypeTests: XCTestCase {
    // MARK: - Single-value conformance

    func testNumberMatches() {
        XCTAssertTrue(ColumnTypeValidator.matches("42", type: .number))
        XCTAssertTrue(ColumnTypeValidator.matches("-3.14", type: .number))
        XCTAssertFalse(ColumnTypeValidator.matches("abc", type: .number))
        XCTAssertFalse(ColumnTypeValidator.matches("1,000", type: .number))
    }

    func testURLMatches() {
        XCTAssertTrue(ColumnTypeValidator.matches("https://example.com", type: .url))
        XCTAssertTrue(ColumnTypeValidator.matches("http://a.b/c", type: .url))
        XCTAssertFalse(ColumnTypeValidator.matches("example.com", type: .url))
        XCTAssertFalse(ColumnTypeValidator.matches("ftp://x", type: .url))
    }

    func testCheckboxMatches() {
        for v in ["true", "False", "YES", "no", "1", "0", "y", "n"] {
            XCTAssertTrue(ColumnTypeValidator.matches(v, type: .checkbox), "\(v) should be checkbox")
        }
        XCTAssertFalse(ColumnTypeValidator.matches("maybe", type: .checkbox))
        XCTAssertFalse(ColumnTypeValidator.matches("2", type: .checkbox))
    }

    func testDateMatchesISO8601Only() {
        XCTAssertTrue(ColumnTypeValidator.matches("2026-06-10", type: .date))
        XCTAssertTrue(ColumnTypeValidator.matches("2026-06-10T13:45:00", type: .date))
        XCTAssertFalse(ColumnTypeValidator.matches("06/10/2026", type: .date))
        XCTAssertFalse(ColumnTypeValidator.matches("June 10", type: .date))
    }

    func testEmptyValueIsUniversallyCompatible() {
        for type in ColumnType.allCases {
            XCTAssertTrue(ColumnTypeValidator.matches("", type: type))
            XCTAssertTrue(ColumnTypeValidator.matches("   ", type: type))
        }
    }

    // MARK: - Column gate

    func testColumnConformsIgnoresEmpties() {
        XCTAssertTrue(ColumnTypeValidator.columnConforms(["1", "", "2", "  "], to: .number))
        XCTAssertFalse(ColumnTypeValidator.columnConforms(["1", "x", "2"], to: .number))
    }

    func testIntentTypesAlwaysConform() {
        for type in [ColumnType.select, .multiSelect, .status, .text] {
            XCTAssertTrue(ColumnTypeValidator.columnConforms(["anything", "goes"], to: type))
        }
    }

    func testConformingFormatTypesAmbiguity() {
        // All 0/1 → both number and checkbox.
        let both = ColumnTypeValidator.conformingFormatTypes(for: ["0", "1", "1", "0"])
        XCTAssertTrue(both.contains(.number))
        XCTAssertTrue(both.contains(.checkbox))
        // Pure decimals → number only.
        XCTAssertEqual(ColumnTypeValidator.conformingFormatTypes(for: ["1.5", "2.0"]), [.number])
    }

    // MARK: - Inference (auto-assign only when unambiguous)

    func testInferUniqueMatch() {
        let schema = TableSchema.inferred(headers: ["d", "u", "n"], rows: [
            ["2026-06-10", "https://x.com", "5"],
            ["2026-06-11", "http://y.com", "6.5"]
        ])
        XCTAssertEqual(schema.schema(for: "d").type, .date)
        XCTAssertEqual(schema.schema(for: "u").type, .url)
        XCTAssertEqual(schema.schema(for: "n").type, .number)
    }

    func testInferAmbiguousStaysText() {
        // 0/1 is both number and checkbox → ambiguous → text (user chooses).
        let schema = TableSchema.inferred(headers: ["flag"], rows: [["1"], ["0"], ["1"]])
        XCTAssertEqual(schema.schema(for: "flag").type, .text)
    }

    func testInferTrueFalseIsCheckbox() {
        let schema = TableSchema.inferred(headers: ["ok"], rows: [["true"], ["false"]])
        XCTAssertEqual(schema.schema(for: "ok").type, .checkbox)
    }

    // MARK: - Self-healing demotion

    func testDemoteNonConforming() {
        var schema = TableSchema()
        schema.setType(.number, for: "n", sampleValues: ["1", "2"])
        schema.demoteNonConforming(headers: ["n"], rows: [["1"], ["oops"], ["3"]])
        XCTAssertEqual(schema.schema(for: "n").type, .text)
    }

    func testDemoteKeepsConforming() {
        var schema = TableSchema()
        schema.setType(.number, for: "n", sampleValues: ["1", "2"])
        schema.demoteNonConforming(headers: ["n"], rows: [["1"], ["2"], [""]])
        XCTAssertEqual(schema.schema(for: "n").type, .number)
    }
}
