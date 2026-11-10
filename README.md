# LightData

[![CI](https://github.com/zyli04/lightdata/actions/workflows/ci.yml/badge.svg)](https://github.com/zyli04/lightdata/actions/workflows/ci.yml)

A native macOS viewer for data files (CSV, TSV, JSON/JSONL, Parquet), built for people who work with data. Double-click a file and see it immediately, without starting a notebook.

**Status: alpha.** Viewing is the focus. Editing is limited to plain text formats and is still being hardened.

## What it opens

| Format | View | Edit |
| --- | --- | --- |
| CSV / TSV | ✓ search, filter, sort | ✓ cells, rows, columns; atomic save |
| JSON / JSONL (array of objects) | ✓ nested values are flattened for display | Only when every value is a string. Files with numbers, booleans, nulls or nested values open read-only so saving can't change their types. |
| Parquet (`.parquet`, `.pq`) | ✓ paged through DuckDB; only the visible rows and columns are read | Read-only. Search, filter and sort are not available yet. |
| XLSX / XLS | ✓ first sheet | Read-only |

Encodings: UTF-8 (with or without BOM) and GB18030/GBK. UTF-16 files open read-only.

**Known limits:** very wide Parquet files (around 150 or more columns) stutter when scrolling, because the native table view doesn't virtualize columns. Parquet files written as a single huge row group are slow to jump deep into. Both are on the roadmap.

## View memory

Per-file view state (column widths, column order, sort and column types) is stored outside your data under `~/Library/Application Support/LightData/Metadata`. Records are keyed by file path, and a bookmark carries them over when a file is renamed or moved. Viewing a file never writes to it.

## Development

Requires Xcode 16 or later. The deployment target is macOS 13.

```sh
open LightData.xcodeproj   # scheme "LightData", target "My Mac", ⌘R
```

- **LightDataCore/**: portable core library (parsers, table model, query/filter, schema, metadata, DuckDB paging). It has no AppKit dependency.
- **App/**: macOS UI (AppKit). It depends on `LightDataCore` as a local Swift package.
- **project.yml**: XcodeGen spec. Regenerate with `xcodegen generate` after changing the project structure.

### Running tests

```sh
Scripts/test.sh        # core unit tests + app-hosted integration tests
Scripts/test.sh core   # core only (fast, headless)
Scripts/test.sh app    # integration tests drive real windows (they flash briefly)
```

CI runs the same script on every push to `main` and on pull requests.

### Quick Look

```sh
Scripts/build-quicklook.sh && Scripts/install-quicklook.sh
```

After installing, select a CSV, TSV, JSON or JSONL file in Finder and press Space.

## Scope

LightData is deliberately not a spreadsheet: it has no formulas, collaboration or workbook editing. The goal is to open, understand and lightly edit local structured data files quickly, natively and without corrupting them.

## License

[MIT](LICENSE)
