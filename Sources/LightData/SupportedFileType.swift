import UniformTypeIdentifiers

enum SupportedFileType {
    static let contentTypes: [UTType] = [
        .commaSeparatedText,
        UTType(filenameExtension: "tsv") ?? .tabSeparatedText,
        .json,
        UTType(filenameExtension: "jsonl") ?? .text,
        UTType(filenameExtension: "xlsx") ?? .data,
        UTType(filenameExtension: "parquet") ?? .data,
        UTType(filenameExtension: "pq") ?? .data
    ]
}
