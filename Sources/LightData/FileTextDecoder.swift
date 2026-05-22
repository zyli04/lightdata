import Foundation

enum LineEnding: String, Codable {
    case lf
    case crlf
    case cr
    case unknown

    var displayName: String {
        switch self {
        case .lf: "LF"
        case .crlf: "CRLF"
        case .cr: "CR"
        case .unknown: "Unknown"
        }
    }

    var stringValue: String {
        switch self {
        case .lf, .unknown: "\n"
        case .crlf: "\r\n"
        case .cr: "\r"
        }
    }
}

enum TextEncodingKind: Codable, Equatable {
    case utf8
    case utf8BOM
    case gb18030
    case latin1

    var displayName: String {
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

    static func encode(_ text: String, encoding: TextEncodingKind) -> Data {
        switch encoding {
        case .utf8:
            return Data(text.utf8)
        case .utf8BOM:
            return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        case .gb18030, .latin1:
            return text.data(using: encoding.stringEncoding, allowLossyConversion: false) ?? Data(text.utf8)
        }
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
