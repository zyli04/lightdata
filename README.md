# LightData

LightData is a lightweight local-first macOS data viewer/editor for structured files.

## Current MVP

- Native macOS AppKit UI.
- Opens `.csv`, `.tsv`, `.json`, `.jsonl`, basic `.xlsx`, and `.parquet` / `.pq` files.
- CSV/TSV/JSON/JSONL support viewing, editing, search, filtering, sorting, and safe save.
- XLSX and Parquet are read-only in this MVP. XLSX supports basic first-sheet viewing for normal workbooks; Parquet is loaded through DuckDB.
- Per-file view and schema metadata are stored centrally under `~/Library/Application Support/LightData/Metadata`.
  LightData uses the macOS file resource identifier when available, so metadata can usually survive file renames and moves on the same filesystem.
- Finder-oriented app bundle packaging via `Scripts/build-app.sh`.

## Build

```sh
swift build
```

Run from source:

```sh
swift run LightData /path/to/data.csv
```

Build a local `.app` bundle:

```sh
Scripts/build-app.sh
open .build/app/LightData.app
```

The app bundle declares file associations for CSV, TSV, JSON, JSONL, XLSX, Parquet, and PQ.

Build the Finder Quick Look generator:

```sh
Scripts/build-quicklook.sh
```

Install it for the current user:

```sh
Scripts/install-quicklook.sh
```

After installation, select a CSV, TSV, JSON, or JSONL file in Finder and press Space.

## Scope Notes

This is intentionally not a full Excel clone. The product target is quick local inspection and light editing of structured files with a clean, stable desktop UI.
