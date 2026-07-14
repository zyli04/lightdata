import Foundation

public enum LineEnding: String, Codable {
    case lf
    case crlf
    case cr
    case unknown

    public var displayName: String {
        switch self {
        case .lf: "LF"
        case .crlf: "CRLF"
        case .cr: "CR"
        case .unknown: "Unknown"
        }
    }

    public var stringValue: String {
        switch self {
        case .lf, .unknown: "\n"
        case .crlf: "\r\n"
        case .cr: "\r"
        }
    }
}

public enum TextEncodingKind: Codable, Equatable {
    case utf8
    case utf8BOM
    case gb18030
    case latin1

    public var displayName: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf8BOM: "UTF-8 BOM"
        case .gb18030: "GB18030/GBK"
        case .latin1: "Latin-1"
        }
    }

    var stringEncoding: String.Encoding {
        switch self {
        case .utf8, .utf8BOM: return String.Encoding.utf8
        case .gb18030:
            let cfEncoding = CFStringEncodings.GB_18030_2000.rawValue
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEncoding)))
        case .latin1: return String.Encoding.isoLatin1
        }
    }
}

struct DecodedText {
    var text: String
    var encoding: TextEncodingKind
    var lineEnding: LineEnding
    /// Set when the file decoded fine for VIEWING but saving through the current
    /// pipeline would corrupt it (e.g. UTF-16 input, which the writer can't emit).
    var readOnlyReason: String?
}

public struct EncodingUnrepresentableError: LocalizedError {
    public let encoding: TextEncodingKind

    public var errorDescription: String? {
        "Some characters cannot be represented in \(encoding.displayName). Use Save As with a UTF-8 format instead, or remove the unsupported characters."
    }
}

enum FileTextDecoder {
    static func decode(url: URL) throws -> DecodedText {
        let data = try Data(contentsOf: url)
        return try decode(data: data)
    }

    static func decode(data: Data) throws -> DecodedText {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            let body = data.dropFirst(3)
            let text = String(decoding: body, as: UTF8.self)
            return DecodedText(text: text, encoding: .utf8BOM, lineEnding: detectLineEnding(in: text))
        }

        // UTF-16 (BOM'd, or BOM-less with the telltale NUL density of ASCII-heavy
        // content). Without this, UTF-16 data falls through to the never-failing
        // Latin-1 branch as NUL-riddled mojibake — and is then editable, so one save
        // destroys the original file. Decode properly, but open read-only since the
        // save pipeline only writes UTF-8/GB18030/Latin-1.
        if let utf16 = decodeUTF16(data: data) {
            return utf16
        }

        if let text = String(data: data, encoding: .utf8), text.unicodeScalars.allSatisfy({ $0.value != 0xFFFD }) {
            return DecodedText(text: text, encoding: .utf8, lineEnding: detectLineEnding(in: text))
        }

        let gbEncoding = TextEncodingKind.gb18030.stringEncoding
        if let text = String(data: data, encoding: gbEncoding), isPlausibleDecodedText(text) {
            return DecodedText(text: text, encoding: .gb18030, lineEnding: detectLineEnding(in: text))
        }

        if let text = String(data: data, encoding: .isoLatin1) {
            return DecodedText(text: text, encoding: .latin1, lineEnding: detectLineEnding(in: text))
        }

        let text = String(decoding: data, as: UTF8.self)
        return DecodedText(text: text, encoding: .utf8, lineEnding: detectLineEnding(in: text))
    }

    /// Encodes text for saving. Throws when the text can't be represented in the
    /// target encoding — silently substituting UTF-8 bytes here would rewrite the
    /// whole file in a different encoding than its declared one (mojibake for every
    /// legacy consumer, including our own info panel).
    static func encode(_ text: String, encoding: TextEncodingKind) throws -> Data {
        switch encoding {
        case .utf8:
            return Data(text.utf8)
        case .utf8BOM:
            return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        case .gb18030, .latin1:
            guard let data = text.data(using: encoding.stringEncoding, allowLossyConversion: false) else {
                throw EncodingUnrepresentableError(encoding: encoding)
            }
            return data
        }
    }

    private static func decodeUTF16(data: Data) -> DecodedText? {
        let hasBigBOM = data.starts(with: [0xFE, 0xFF])
        let hasLittleBOM = data.starts(with: [0xFF, 0xFE])

        if hasBigBOM || hasLittleBOM {
            let encoding: String.Encoding = hasBigBOM ? .utf16BigEndian : .utf16LittleEndian
            guard let text = String(data: data.dropFirst(2), encoding: encoding) else { return nil }
            return DecodedText(
                text: text,
                encoding: .utf8,
                lineEnding: detectLineEnding(in: text),
                readOnlyReason: "UTF-16 file (read-only; use Save As to convert)"
            )
        }

        // BOM-less heuristic: UTF-16 text that is mostly ASCII has a NUL in nearly
        // every other byte; genuine single-byte text essentially never does.
        guard data.count >= 16, data.count % 2 == 0 else { return nil }
        let sample = data.prefix(4096)
        let nulCount = sample.filter { $0 == 0 }.count
        guard Double(nulCount) / Double(sample.count) > 0.2 else { return nil }

        let evenNULs = stride(from: sample.startIndex, to: sample.endIndex, by: 2).filter { sample[$0] == 0 }.count
        let oddNULs = nulCount - evenNULs
        let encoding: String.Encoding = evenNULs > oddNULs ? .utf16BigEndian : .utf16LittleEndian
        guard let text = String(data: data, encoding: encoding), isPlausibleDecodedText(text) else { return nil }
        return DecodedText(
            text: text,
            encoding: .utf8,
            lineEnding: detectLineEnding(in: text),
            readOnlyReason: "UTF-16 file (read-only; use Save As to convert)"
        )
    }

    private static func detectLineEnding(in text: String) -> LineEnding {
        var lf = 0
        var crlf = 0
        var cr = 0
        let characters = Array(text.unicodeScalars)
        var index = 0
        while index < characters.count {
            if characters[index].value == 13 {
                if index + 1 < characters.count, characters[index + 1].value == 10 {
                    crlf += 1
                    index += 1
                } else {
                    cr += 1
                }
            } else if characters[index].value == 10 {
                lf += 1
            }
            index += 1
        }

        let counts: [(LineEnding, Int)] = [(.crlf, crlf), (.lf, lf), (.cr, cr)]
        guard let best = counts.max(by: { $0.1 < $1.1 }), best.1 > 0 else {
            return .unknown
        }
        return best.0
    }

    private static func isPlausibleDecodedText(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        let replacementCount = text.unicodeScalars.filter { $0.value == 0xFFFD }.count
        let controlCount = text.unicodeScalars.filter { scalar in
            scalar.value < 0x20 && scalar != "\n" && scalar != "\r" && scalar != "\t"
        }.count
        return replacementCount == 0 && Double(controlCount) / Double(text.unicodeScalars.count) < 0.01
    }
}
