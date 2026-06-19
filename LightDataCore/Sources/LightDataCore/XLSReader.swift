import Foundation

enum XLSReaderError: LocalizedError {
    case notOLE2
    case workbookStreamMissing
    case noWorksheet

    var errorDescription: String? {
        switch self {
        case .notOLE2:
            "This is not a valid Excel 97–2003 (.xls) workbook."
        case .workbookStreamMissing:
            "Could not find the workbook stream inside the .xls file."
        case .noWorksheet:
            "The .xls workbook does not contain a worksheet."
        }
    }
}

/// Reads legacy Excel 97–2003 binary workbooks (`.xls`, BIFF8). Unlike `.xlsx` (a zip of
/// XML), `.xls` is an OLE2 compound document containing a stream of binary BIFF records,
/// so this is a from-scratch, dependency-free parser: an OLE2 container reader (`OLE2`)
/// that extracts the "Workbook" stream, then a BIFF record walker (`BIFF`) that decodes
/// the first worksheet's cells. Read-only, first sheet only — mirroring `XLSXReader`.
enum XLSReader {
    static func readFirstSheet(url: URL, firstRowIsHeader: Bool = true) throws -> ParsedTable {
        let bytes = [UInt8](try Data(contentsOf: url))
        let workbook = try OLE2.extractWorkbookStream(bytes)
        let (sheetName, cells) = try BIFF.parseFirstWorksheet(workbook)
        guard !cells.isEmpty else { throw TableDocumentError.emptyFile }

        let maxColumn = cells.values.flatMap(\.keys).max() ?? 0
        let firstRowIndex = cells.keys.min() ?? 0
        let headers: [String]
        let dataRowKeys: [Int]
        if firstRowIsHeader {
            let headerCells = cells[firstRowIndex] ?? [:]
            let names = (0...maxColumn).map { index -> String in
                let value = headerCells[index]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return value.isEmpty ? "Column \(index + 1)" : value
            }
            headers = makeUnique(names)
            dataRowKeys = cells.keys.sorted().filter { $0 != firstRowIndex }
        } else {
            headers = (0...maxColumn).map { "Column \($0 + 1)" }
            dataRowKeys = cells.keys.sorted()
        }

        let rows = dataRowKeys.map { rowIndex -> [String] in
            let row = cells[rowIndex] ?? [:]
            return (0..<headers.count).map { row[$0] ?? "" }
        }

        return ParsedTable(
            headers: headers,
            rows: rows,
            sheetName: sheetName,
            openInfo: FileOpenInfo(
                encoding: nil,
                lineEnding: nil,
                delimiter: .none,
                readOnlyReason: "XLS read-only"
            )
        )
    }
}

// MARK: - OLE2 / Compound File Binary Format

private enum OLE2 {
    static let endOfChain: UInt32 = 0xFFFFFFFE
    static let freeSect: UInt32 = 0xFFFFFFFF

    /// Parses the OLE2 container and returns the bytes of the "Workbook" (BIFF8) or
    /// "Book" (BIFF5) stream.
    static func extractWorkbookStream(_ bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.count >= 512,
              bytes[0] == 0xD0, bytes[1] == 0xCF, bytes[2] == 0x11, bytes[3] == 0xE0,
              bytes[4] == 0xA1, bytes[5] == 0xB1, bytes[6] == 0x1A, bytes[7] == 0xE1 else {
            throw XLSReaderError.notOLE2
        }

        let sectorSize = 1 << Int(readU16(bytes, 30))
        let miniSectorSize = 1 << Int(readU16(bytes, 32))
        let firstDirSector = Int(readU32(bytes, 48))
        let miniCutoff = Int(readU32(bytes, 56))
        let firstMiniFATSector = Int(readU32(bytes, 60))
        let firstDIFATSector = Int(readU32(bytes, 68))
        let numDIFATSectors = Int(readU32(bytes, 72))
        guard sectorSize >= 512, miniSectorSize >= 1 else { throw XLSReaderError.notOLE2 }

        func sectorRange(_ s: Int) -> Range<Int> {
            let off = (s + 1) * sectorSize
            return off ..< min(off + sectorSize, bytes.count)
        }

        // Collect the FAT sector numbers from the header DIFAT (first 109) plus any DIFAT chain.
        var fatSectors: [Int] = []
        for i in 0..<109 {
            let v = readU32(bytes, 76 + i * 4)
            if v != freeSect && v != endOfChain { fatSectors.append(Int(v)) }
        }
        var difat = firstDIFATSector
        var difatGuard = 0
        while difat != Int(endOfChain), difat != Int(freeSect), difatGuard < numDIFATSectors + 1 {
            let range = sectorRange(difat)
            let entries = sectorSize / 4
            for i in 0..<(entries - 1) {
                let v = readU32(bytes, range.lowerBound + i * 4)
                if v != freeSect && v != endOfChain { fatSectors.append(Int(v)) }
            }
            difat = Int(readU32(bytes, range.lowerBound + (entries - 1) * 4))
            difatGuard += 1
        }

        // Build the flat FAT.
        var fat: [UInt32] = []
        fat.reserveCapacity(fatSectors.count * (sectorSize / 4))
        for sn in fatSectors {
            let range = sectorRange(sn)
            for i in 0..<(sectorSize / 4) { fat.append(readU32(bytes, range.lowerBound + i * 4)) }
        }

        func chain(from start: Int, in table: [UInt32]) -> [Int] {
            var result: [Int] = []
            var s = start
            var steps = 0
            while s >= 0, s < table.count, s != Int(endOfChain), steps <= table.count {
                result.append(s)
                s = Int(table[s])
                steps += 1
            }
            return result
        }

        func readFATStream(start: Int, size: Int) -> [UInt8] {
            var out: [UInt8] = []
            for s in chain(from: start, in: fat) { out.append(contentsOf: bytes[sectorRange(s)]) }
            if size > 0, out.count > size { out.removeLast(out.count - size) }
            return out
        }

        // Walk the directory to find the Workbook stream and the Root Entry (mini-stream host).
        let directory = readFATStream(start: firstDirSector, size: 0)
        let entrySize = 128
        var workbook: (start: Int, size: Int)?
        var root: (start: Int, size: Int)?
        for e in 0..<(directory.count / entrySize) {
            let base = e * entrySize
            let nameLen = Int(readU16(directory, base + 64))
            let objectType = directory[base + 66]
            let startSector = Int(readU32(directory, base + 116))
            let streamSize = Int(readU32(directory, base + 120))
            let name = directoryName(directory, base: base, byteLength: nameLen)
            if objectType == 5 { root = (startSector, streamSize) }
            if objectType == 2, name == "Workbook" || name == "Book" {
                workbook = (startSector, streamSize)
            }
        }
        guard let workbook else { throw XLSReaderError.workbookStreamMissing }

        // Large streams live in the regular FAT; small ones in the mini stream.
        if workbook.size >= miniCutoff {
            return readFATStream(start: workbook.start, size: workbook.size)
        }

        guard let root else { throw XLSReaderError.workbookStreamMissing }
        let miniContainer = readFATStream(start: root.start, size: root.size)
        var miniFAT: [UInt32] = []
        for s in chain(from: firstMiniFATSector, in: fat) {
            let range = sectorRange(s)
            for i in 0..<(sectorSize / 4) { miniFAT.append(readU32(bytes, range.lowerBound + i * 4)) }
        }
        var out: [UInt8] = []
        for ms in chain(from: workbook.start, in: miniFAT) {
            let off = ms * miniSectorSize
            guard off < miniContainer.count else { continue }
            out.append(contentsOf: miniContainer[off ..< min(off + miniSectorSize, miniContainer.count)])
        }
        if out.count > workbook.size { out.removeLast(out.count - workbook.size) }
        return out
    }

    private static func directoryName(_ dir: [UInt8], base: Int, byteLength: Int) -> String {
        guard byteLength >= 2 else { return "" }
        let chars = byteLength / 2 - 1 // drop the UTF-16 null terminator
        guard chars > 0 else { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(chars)
        for c in 0..<chars { units.append(readU16(dir, base + c * 2)) }
        return String(utf16CodeUnits: units, count: units.count)
    }
}

// MARK: - BIFF record decoding

private enum BIFF {
    static let bof: UInt16 = 0x0809
    static let eof: UInt16 = 0x000A
    static let sst: UInt16 = 0x00FC
    static let continueRec: UInt16 = 0x003C
    static let boundSheet: UInt16 = 0x0085
    static let labelSST: UInt16 = 0x00FD
    static let label: UInt16 = 0x0204
    static let rk: UInt16 = 0x027E
    static let mulRK: UInt16 = 0x00BD
    static let number: UInt16 = 0x0203
    static let boolErr: UInt16 = 0x0205
    static let formula: UInt16 = 0x0006
    static let string: UInt16 = 0x0207

    struct Record { let type: UInt16; let start: Int; let length: Int }

    static func parseFirstWorksheet(_ wb: [UInt8]) throws -> (sheetName: String?, cells: [Int: [Int: String]]) {
        let records = scanRecords(wb)
        let substreams = splitSubstreams(records)
        guard let globals = substreams.first else { throw XLSReaderError.noWorksheet }

        // Globals substream: shared strings + the first worksheet's name.
        var sharedStrings: [String] = []
        var sheetName: String?
        var i = 0
        while i < globals.count {
            let record = globals[i]
            if record.type == sst {
                var blocks = [(record.start, record.length)]
                var j = i + 1
                while j < globals.count, globals[j].type == continueRec {
                    blocks.append((globals[j].start, globals[j].length))
                    j += 1
                }
                sharedStrings = parseSST(wb, blocks: blocks)
                i = j
                continue
            }
            if record.type == boundSheet, sheetName == nil, wb[safe: record.start + 5] == 0 {
                sheetName = readShortString(wb, record.start + 6)
            }
            i += 1
        }

        guard substreams.count > 1 else { throw XLSReaderError.noWorksheet }
        let sheet = substreams[1]
        var cells: [Int: [Int: String]] = [:]
        func put(_ row: Int, _ col: Int, _ value: String) { cells[row, default: [:]][col] = value }

        var k = 0
        while k < sheet.count {
            let record = sheet[k]
            let s = record.start
            switch record.type {
            case labelSST:
                let index = Int(readU32(wb, s + 6))
                if sharedStrings.indices.contains(index) {
                    put(Int(readU16(wb, s)), Int(readU16(wb, s + 2)), sharedStrings[index])
                }
            case label:
                put(Int(readU16(wb, s)), Int(readU16(wb, s + 2)), readLongString(wb, s + 6))
            case number:
                put(Int(readU16(wb, s)), Int(readU16(wb, s + 2)), formatDouble(readDouble(wb, s + 6)))
            case rk:
                put(Int(readU16(wb, s)), Int(readU16(wb, s + 2)), formatDouble(rkValue(readU32(wb, s + 6))))
            case mulRK:
                let row = Int(readU16(wb, s))
                let colFirst = Int(readU16(wb, s + 2))
                let count = (record.length - 6) / 6
                for n in 0..<max(0, count) {
                    let value = rkValue(readU32(wb, s + 4 + n * 6 + 2))
                    put(row, colFirst + n, formatDouble(value))
                }
            case boolErr:
                let raw = wb[safe: s + 6] ?? 0
                let isError = (wb[safe: s + 7] ?? 0) != 0
                put(Int(readU16(wb, s)), Int(readU16(wb, s + 2)), isError ? errorText(raw) : (raw != 0 ? "true" : "false"))
            case formula:
                let row = Int(readU16(wb, s))
                let col = Int(readU16(wb, s + 2))
                // The 8-byte cached result: a special marker (bytes 6,7 == 0xFFFF) flags a
                // non-numeric result whose kind is in byte 0; otherwise it's an IEEE double.
                if wb[safe: s + 12] == 0xFF, wb[safe: s + 13] == 0xFF {
                    switch wb[safe: s + 6] ?? 0 {
                    case 1:
                        put(row, col, (wb[safe: s + 8] ?? 0) != 0 ? "true" : "false")
                    case 2:
                        put(row, col, errorText(wb[safe: s + 8] ?? 0))
                    case 0:
                        // String result lives in the STRING record that follows.
                        if k + 1 < sheet.count, sheet[k + 1].type == string {
                            put(row, col, readLongString(wb, sheet[k + 1].start))
                        }
                    default:
                        break // empty
                    }
                } else {
                    put(row, col, formatDouble(readDouble(wb, s + 6)))
                }
            default:
                break
            }
            k += 1
        }

        return (sheetName, cells)
    }

    private static func scanRecords(_ wb: [UInt8]) -> [Record] {
        var records: [Record] = []
        var pos = 0
        while pos + 4 <= wb.count {
            let type = readU16(wb, pos)
            let length = Int(readU16(wb, pos + 2))
            let dataStart = pos + 4
            guard dataStart + length <= wb.count else { break }
            records.append(Record(type: type, start: dataStart, length: length))
            pos = dataStart + length
        }
        return records
    }

    /// Splits the record stream into BOF…EOF substreams (globals first, then each sheet).
    private static func splitSubstreams(_ records: [Record]) -> [[Record]] {
        var substreams: [[Record]] = []
        var current: [Record] = []
        var depth = 0
        for record in records {
            if record.type == bof {
                if depth == 0 { current = [] }
                depth += 1
            }
            if depth > 0 { current.append(record) }
            if record.type == eof, depth > 0 {
                depth -= 1
                if depth == 0 { substreams.append(current) }
            }
        }
        return substreams
    }

    /// Decodes the shared string table. Strings can be split across CONTINUE records, and
    /// at each split the continuation re-states the 8/16-bit flag for the remaining chars,
    /// so we concatenate the blocks and consume that flag byte when a string crosses a
    /// recorded block boundary.
    private static func parseSST(_ wb: [UInt8], blocks: [(start: Int, len: Int)]) -> [String] {
        var blob: [UInt8] = []
        var boundaries: Set<Int> = []
        for (index, block) in blocks.enumerated() {
            if index > 0 { boundaries.insert(blob.count) }
            blob.append(contentsOf: wb[block.start ..< block.start + block.len])
        }
        guard blob.count >= 8 else { return [] }

        var pos = 8 // skip cstTotal (u32) + cstUnique (u32)
        let unique = Int(readU32(blob, 4))
        var result: [String] = []
        result.reserveCapacity(unique)

        for _ in 0..<unique {
            guard pos + 3 <= blob.count else { break }
            let cch = Int(readU16(blob, pos)); pos += 2
            var grbit = Int(blob[pos]); pos += 1
            var highByte = (grbit & 0x01) != 0
            let hasRichRuns = (grbit & 0x08) != 0
            let hasExtPhonetic = (grbit & 0x04) != 0
            var runCount = 0
            var extSize = 0
            if hasRichRuns { runCount = Int(readU16(blob, pos)); pos += 2 }
            if hasExtPhonetic { extSize = Int(readU32(blob, pos)); pos += 4 }

            var units: [UInt16] = []
            units.reserveCapacity(cch)
            var produced = 0
            while produced < cch, pos < blob.count {
                if boundaries.contains(pos) {
                    grbit = Int(blob[pos]); pos += 1
                    highByte = (grbit & 0x01) != 0
                }
                if highByte {
                    guard pos + 2 <= blob.count else { break }
                    units.append(readU16(blob, pos)); pos += 2
                } else {
                    units.append(UInt16(blob[pos])); pos += 1
                }
                produced += 1
            }
            pos += runCount * 4
            pos += extSize
            result.append(String(utf16CodeUnits: units, count: units.count))
        }
        return result
    }

    /// A ShortXLUnicodeString: 1-byte char count, 1-byte flags, then the chars.
    private static func readShortString(_ wb: [UInt8], _ offset: Int) -> String {
        guard let count = wb[safe: offset], let grbit = wb[safe: offset + 1] else { return "" }
        return readChars(wb, start: offset + 2, count: Int(count), highByte: (grbit & 0x01) != 0)
    }

    /// An XLUnicodeString: 2-byte char count, 1-byte flags, then the chars.
    private static func readLongString(_ wb: [UInt8], _ offset: Int) -> String {
        let count = Int(readU16(wb, offset))
        guard let grbit = wb[safe: offset + 2] else { return "" }
        return readChars(wb, start: offset + 3, count: count, highByte: (grbit & 0x01) != 0)
    }

    private static func readChars(_ wb: [UInt8], start: Int, count: Int, highByte: Bool) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(count)
        var p = start
        for _ in 0..<count {
            if highByte {
                guard p + 2 <= wb.count else { break }
                units.append(readU16(wb, p)); p += 2
            } else {
                guard let b = wb[safe: p] else { break }
                units.append(UInt16(b)); p += 1
            }
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    /// Decodes an RK-encoded number (a packed integer or truncated IEEE double, optionally ÷100).
    private static func rkValue(_ rk: UInt32) -> Double {
        let divide = (rk & 0x01) != 0
        let isInt = (rk & 0x02) != 0
        var value: Double
        if isInt {
            value = Double(Int32(bitPattern: rk) >> 2) // arithmetic shift keeps the sign
        } else {
            value = Double(bitPattern: UInt64(rk & 0xFFFFFFFC) << 32)
        }
        return divide ? value / 100 : value
    }

    private static func formatDouble(_ value: Double) -> String {
        if value.isFinite, value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    private static func errorText(_ code: UInt8) -> String {
        switch code {
        case 0x00: "#NULL!"
        case 0x07: "#DIV/0!"
        case 0x0F: "#VALUE!"
        case 0x17: "#REF!"
        case 0x1D: "#NAME?"
        case 0x24: "#NUM!"
        case 0x2A: "#N/A"
        default: "#ERR"
        }
    }
}

// MARK: - Little-endian byte readers

private extension Array where Element == UInt8 {
    subscript(safe index: Int) -> UInt8? {
        indices.contains(index) ? self[index] : nil
    }
}

private func readU16(_ bytes: [UInt8], _ index: Int) -> UInt16 {
    guard index >= 0, index + 1 < bytes.count else { return 0 }
    return UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
}

private func readU32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
    guard index >= 0, index + 3 < bytes.count else { return 0 }
    return UInt32(bytes[index])
        | (UInt32(bytes[index + 1]) << 8)
        | (UInt32(bytes[index + 2]) << 16)
        | (UInt32(bytes[index + 3]) << 24)
}

private func readDouble(_ bytes: [UInt8], _ index: Int) -> Double {
    guard index >= 0, index + 7 < bytes.count else { return 0 }
    var bits: UInt64 = 0
    for i in 0..<8 { bits |= UInt64(bytes[index + i]) << (8 * i) }
    return Double(bitPattern: bits)
}
