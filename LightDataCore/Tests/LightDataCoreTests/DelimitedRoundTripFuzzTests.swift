import XCTest
@testable import LightDataCore

/// Property-based round-trip fuzzing: for hundreds of randomly generated tables —
/// deliberately including every nasty shape we've been bitten by (huge multi-line
/// fields, other-delimiter-joined list columns, quotes, emoji, empty cells) — writing
/// with delimiter d and re-loading through AUTO-DETECTION must reproduce the exact
/// table. This is the mine-sweeper: it finds detection/parse/write bugs before a real
/// file does. Deterministic (seeded PRNG); on failure it prints the seed and case.
final class DelimitedRoundTripFuzzTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightdata-fuzz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // SplitMix64: tiny deterministic PRNG so failures are reproducible.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private func randomValue(_ rng: inout SplitMix64, kind: Int) -> String {
        let words = ["alpha", "beta", "关键字", "naïve", "data", "x1", "🚀", "hello world"]
        switch kind {
        case 0: return ""                                             // empty
        case 1: return words.randomElement(using: &rng)!              // plain word
        case 2: return String(Int.random(in: -9999...9999, using: &rng))
        case 3:                                                       // other-delimiter joined list
            let joiner = [";", "|", ",", "\t"].randomElement(using: &rng)!
            let n = Int.random(in: 2...30, using: &rng)
            return (0..<n).map { "item\($0)" }.joined(separator: joiner)
        case 4:                                                       // quotes + newlines
            return "said \"hi\"\nline2 \"quoted\" end"
        case 5:                                                       // huge multi-line field with stray delimiters
            let n = Int.random(in: 200...900, using: &rng)
            return (0..<n).map { "seg\($0) | with ; and , inside" }.joined(separator: "\n")
        case 6: return "trailing space "                              // whitespace edge
        default:
            return words.randomElement(using: &rng)! + ["", ";x", "|y", ", z"].randomElement(using: &rng)!
        }
    }

    private func randomTable(_ rng: inout SplitMix64) -> (headers: [String], rows: [[String]]) {
        let cols = Int.random(in: 2...10, using: &rng)
        let rows = Int.random(in: 1...25, using: &rng)
        // Headers: plain names (no delimiter chars — matching real exports; ambiguous
        // headers are separately covered by testAmbiguousFilePrefersCommaForCSV).
        let headers = (0..<cols).map { "col\($0)_\(Int.random(in: 0...99, using: &rng))" }
        var body: [[String]] = []
        for _ in 0..<rows {
            var row: [String] = []
            for _ in 0..<cols {
                // Bias toward nasty kinds; kind 5 (huge) rarer to keep runtime sane.
                let roll = Int.random(in: 0...100, using: &rng)
                let kind: Int
                switch roll {
                case 0...25: kind = 1
                case 26...40: kind = 2
                case 41...60: kind = 3
                case 61...75: kind = 4
                case 76...80: kind = 5
                case 81...90: kind = 0
                case 91...95: kind = 6
                default: kind = 7
                }
                row.append(randomValue(&rng, kind: kind))
            }
            body.append(row)
        }
        return (headers, body)
    }

    func testWriteDetectParseRoundTripsExactly() throws {
        let delimiters: [Character] = [",", "\t", ";", "|"]
        let seed: UInt64 = 20260715   // fixed seed; change to re-roll locally
        var rng = SplitMix64(state: seed)

        for caseIndex in 0..<120 {
            let table = randomTable(&rng)
            for delimiter in delimiters {
                let url = tempDir.appendingPathComponent("fuzz-\(caseIndex)-\(delimiter == "\t" ? "tab" : String(delimiter)).csv")
                try DelimitedTextParser.write(
                    url: url, headers: table.headers, rows: table.rows,
                    delimiter: delimiter, encoding: .utf8, lineEnding: .lf
                )
                let doc = try TableDocument.load(url: url)   // auto-detects the delimiter
                XCTAssertEqual(doc.headers, table.headers,
                               "case \(caseIndex) delim '\(delimiter)': headers must survive write→detect→parse")
                XCTAssertEqual(doc.rows, table.rows,
                               "case \(caseIndex) delim '\(delimiter)': rows must survive write→detect→parse")
                if doc.headers != table.headers || doc.rows != table.rows {
                    return   // one detailed failure is enough; don't spam 480 asserts
                }
            }
        }
    }
}
