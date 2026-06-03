import DuckDB
import Foundation

enum ParquetReader {
    static func read(url: URL) throws -> ParsedTable {
        do {
            let database = try Database(store: .inMemory)
            let connection = try database.connect()
            let relation = "read_parquet(\(sqlStringLiteral(url.path)))"
            let schemaResult = try connection.query("SELECT * FROM \(relation) LIMIT 0")
            let headers = makeUnique((0..<schemaResult.columnCount).map { index in
                schemaResult.columnName(at: index)
            })
            guard !headers.isEmpty else { throw TableDocumentError.emptyFile }

            let selectList = headers.enumerated().map { index, header in
                "CAST(\(sqlIdentifier(schemaResult.columnName(at: DBInt(index)))) AS VARCHAR) AS \(sqlIdentifier(header))"
            }.joined(separator: ", ")
            let result = try connection.query("SELECT \(selectList) FROM \(relation)")
            let columns = (0..<result.columnCount).map { index in
                result[index].cast(to: String.self)
            }
            let rowCount = Int(result.rowCount)
            guard rowCount > 0 else { throw TableDocumentError.emptyFile }

            let rows = (0..<rowCount).map { rowIndex in
                columns.map { column in
                    column[DBInt(rowIndex)] ?? ""
                }
            }

            return ParsedTable(
                headers: headers,
                rows: rows,
                openInfo: FileOpenInfo(
                    encoding: nil,
                    lineEnding: nil,
                    delimiter: .none,
                    readOnlyReason: "Parquet read-only"
                )
            )
        } catch let error as TableDocumentError {
            throw error
        } catch {
            throw TableDocumentError.invalidParquet(error.localizedDescription)
        }
    }

    private static func sqlStringLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func sqlIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
