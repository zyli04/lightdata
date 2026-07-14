import XCTest
@testable import LightDataCore

/// Hostile-input hardening tests: crafted OLE2 headers and out-of-spec XLSX cell
/// references must fail cleanly (throw / ignore), never drive huge allocations,
/// overflow traps, or unbounded loops.
final class HostileFileTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightdata-hostile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - OLE2 header builders

    private func ole2Header(
        sectorShift: UInt16 = 9,
        miniSectorShift: UInt16 = 6,
        firstDIFATSector: UInt32 = 0xFFFFFFFE,
        numDIFATSectors: UInt32 = 0,
        totalSize: Int = 1024
    ) -> Data {
        var bytes = [UInt8](repeating: 0, count: totalSize)
        // OLE2 magic
        let magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        bytes.replaceSubrange(0..<8, with: magic)
        func putU16(_ value: UInt16, at offset: Int) {
            bytes[offset] = UInt8(value & 0xFF)
            bytes[offset + 1] = UInt8(value >> 8)
        }
        func putU32(_ value: UInt32, at offset: Int) {
            for i in 0..<4 { bytes[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
        }
        putU16(sectorShift, at: 30)
        putU16(miniSectorShift, at: 32)
        putU32(0xFFFFFFFE, at: 48)          // first directory sector: end of chain
        putU32(4096, at: 56)                // mini cutoff
        putU32(0xFFFFFFFE, at: 60)          // first mini FAT sector
        putU32(firstDIFATSector, at: 68)
        putU32(numDIFATSectors, at: 72)
        // Header DIFAT: all FREESECT
        for i in 0..<109 { putU32(0xFFFFFFFF, at: 76 + i * 4) }
        return Data(bytes)
    }

    private func writeXLS(_ data: Data) throws -> URL {
        let url = tempDir.appendingPathComponent("hostile-\(UUID().uuidString).xls")
        try data.write(to: url)
        return url
    }

    // MARK: - XLS: crafted headers

    func testGiantSectorShiftIsRejected() throws {
        // sectorShift 34 → "16 GiB sectors": must throw notOLE2, not reserve gigabytes
        // or trap on overflowing offset multiplies.
        let url = try writeXLS(ole2Header(sectorShift: 34))
        XCTAssertThrowsError(try XLSReader.readFirstSheet(url: url))
    }

    func testNonStandardMiniSectorShiftIsRejected() throws {
        let url = try writeXLS(ole2Header(miniSectorShift: 12))
        XCTAssertThrowsError(try XLSReader.readFirstSheet(url: url))
    }

    func testSelfReferentialDIFATChainTerminates() throws {
        // Sector 0 (bytes 512..1024) is a DIFAT sector whose "next" pointer points to
        // itself, and the header claims 4 billion DIFAT sectors. The walk must
        // terminate via the visited-set, then fail cleanly (no workbook stream).
        var data = ole2Header(firstDIFATSector: 0, numDIFATSectors: 0xFFFFFFFF, totalSize: 1024)
        data.withUnsafeMutableBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            // Fill DIFAT entries with FREESECT
            for i in 0..<(512 / 4 - 1) {
                for b in 0..<4 { base[512 + i * 4 + b] = 0xFF }
            }
            // Last entry: next DIFAT sector = 0 (itself)
            for b in 0..<4 { base[512 + 508 + b] = 0 }
        }
        let url = try writeXLS(data)
        let start = Date()
        XCTAssertThrowsError(try XLSReader.readFirstSheet(url: url))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "must terminate promptly, not iterate billions of times")
    }

    func testHugeDeclaredDIFATCountOnTinyFile() throws {
        // numDIFATSectors huge but chain immediately out of bounds — must not hang.
        let url = try writeXLS(ole2Header(firstDIFATSector: 999_999, numDIFATSectors: 0xFFFFFFFF))
        XCTAssertThrowsError(try XLSReader.readFirstSheet(url: url))
    }

    // MARK: - XLSX: out-of-spec cell references

    private func makeXLSX(cellRef: String) throws -> URL {
        let dir = tempDir.appendingPathComponent("xlsx-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("xl/worksheets"), withIntermediateDirectories: true)
        try Data("""
        <?xml version="1.0"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheets><sheet name="S1" sheetId="1" r:id="rId1" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></sheets></workbook>
        """.utf8).write(to: dir.appendingPathComponent("xl/workbook.xml"))
        try Data("""
        <?xml version="1.0"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        <row r="1"><c r="A1" t="inlineStr"><is><t>ok</t></is></c><c r="\(cellRef)" t="inlineStr"><is><t>evil</t></is></c></row>
        </sheetData></worksheet>
        """.utf8).write(to: dir.appendingPathComponent("xl/worksheets/sheet1.xml"))

        let url = tempDir.appendingPathComponent("hostile-\(UUID().uuidString).xlsx")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", dir.path, url.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)
        return url
    }

    func testAstronomicalColumnReferenceIsIgnored() throws {
        // "ZZZZZZZZ1" → column ≈ 2×10¹¹; the dense header materialization would OOM.
        // The cell must be ignored; the valid A1 cell still loads.
        let url = try makeXLSX(cellRef: "ZZZZZZZZ1")
        let table = try XLSXReader.readFirstSheet(url: url, firstRowIsHeader: false)
        XCTAssertEqual(table.headers.count, 1, "only column A materializes")
        XCTAssertEqual(table.rows.first?.first, "ok")
    }

    func testColumnBeyondXFDIsIgnored() throws {
        // XFE = 16385, one past the XLSX spec max.
        let url = try makeXLSX(cellRef: "XFE1")
        let table = try XLSXReader.readFirstSheet(url: url, firstRowIsHeader: false)
        XCTAssertEqual(table.headers.count, 1)
    }

    func testSpecMaxColumnStillAccepted() throws {
        // XFD (16384) is legitimate and must still work: 16384 dense headers is fine.
        let url = try makeXLSX(cellRef: "XFD1")
        let table = try XLSXReader.readFirstSheet(url: url, firstRowIsHeader: false)
        XCTAssertEqual(table.headers.count, 16384)
        XCTAssertEqual(table.rows.first?.last, "evil")
    }
}
