# LightData

LightData is a lightweight local-first macOS data viewer/editor for structured files.

## Current MVP

- Native macOS AppKit UI.
- Opens `.csv`, `.tsv`, `.json`, `.jsonl`, basic `.xlsx`, and `.parquet` / `.pq` files.
- CSV/TSV/JSON/JSONL support viewing, editing, search, filtering, sorting, and safe save.
- XLSX and Parquet are read-only in this MVP. XLSX supports basic first-sheet viewing for normal workbooks; Parquet is loaded through DuckDB.
- Per-file view and schema metadata are stored centrally under `~/Library/Application Support/LightData/Metadata`.
  LightData uses the macOS file resource identifier when available, so metadata can usually survive file renames and moves on the same filesystem.
- Xcode-based macOS app bundle (with Bundle ID, code signing, and file associations).

## Development

Open the Xcode project:

```sh
open LightData.xcodeproj
```

Select the **LightData** scheme, target **My Mac**, then **⌘R** to build and run.

### Project structure

- **LightDataCore/** — portable core library (parsers, table model, query/filter, schema, metadata). Zero AppKit dependencies; decoupled for future iOS / cross-platform reuse.
- **App/** — macOS UI (AppKit). Depends on `LightDataCore` as a local Swift package.
- **`project.yml`** — XcodeGen spec; if you change project structure, regenerate with `xcodegen generate`.

### Quick Look generator

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
