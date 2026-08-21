# Macquet

A window into Parquet — a native macOS viewer for Parquet files.

The name is `mac` + `parquet`, in the spirit of `htop` → `mactop`. It also
lands on *maquette*: a small scale model you look at to understand something
much larger. Which is the whole job.

Parquet is named after the flooring, so the app icon is a parquet floor with
one block lit up like a selected cell.

## What it does

Opening a multi-gigabyte dataset should feel like opening a text file. Macquet
reads Parquet through an embedded [DuckDB](https://duckdb.org), so it never
loads a whole file into memory — it pages rows in around wherever you're
looking.

- **Grid** — virtualised, so 25 rows or 25 million behave the same. Physical
  file row numbers in the gutter, resizable and hideable columns, click-to-sort,
  type-coloured headers.
- **Row inspector** — the grid clips long text; the inspector shows the real
  value. Built for datasets whose interesting column is a 4 KB prompt. Search
  hits are highlighted inside the value.
- **Filter** — free-text across all columns (or one), plus a hand-written
  `WHERE` clause. Row counts always tell you how much was filtered out.
- **SQL console** — the open file is `tbl`. Snippets for value counts,
  distributions, sampling and `SUMMARIZE` are one menu away.
- **File pane** — what the Parquet footer actually says: row groups drawn to
  scale, per-column compression, encodings and on-disk size, plus the embedded
  key/value metadata (where Hugging Face keeps its dataset card).
- **Column stats** — expand a column in the sidebar for distinct counts, null
  percentage, min/max/median, and the most common values. Click a value to
  filter to it.
- **Export** — the current view, filter and sort included, to CSV, JSON or
  Parquet.

## Finder integration

- Declares the `org.apache.parquet` type, so `.parquet` files get Macquet's
  icon and open on double-click.
- Press space on a `.parquet` file for a **Quick Look** preview: schema with
  types, the first 60 rows, and footer stats. The extension runs the same
  `ParquetTable` the app does, so it's a third front end over the core rather
  than a reimplementation.
- Real document windows: the title bar carries the file's proxy icon — drag it
  into Mail, ⌘-click it for the folder path.
- Drag a file (or a folder of shards) onto the window or the Dock icon.
- A folder of `train-00000-of-00042.parquet` shards opens as **one** table,
  with `union_by_name` so shards with drifting schemas still line up.
- Reveal in Finder (⇧⌘R), Copy Path, and a working Open Recent.
- Notices when the file changes on disk and offers to reload, keeping your
  filter and sort.

## Requirements

macOS 15 or later, and a Swift 6 toolchain (Xcode 26+). The only dependency is
[duckdb-swift](https://github.com/duckdb/duckdb-swift), pinned to 1.1.3.

## Install

```bash
./Scripts/build-app.sh --install
```

That builds `Macquet.app`, copies it to `~/Applications`, registers it with
Launch Services, and symlinks the `macquetql` CLI onto your `PATH` if a
writable `bin` directory exists.

Build without installing:

```bash
./Scripts/build-app.sh
```

Zip the app and publish it as a GitHub release (requires the `gh` CLI):

```bash
./Scripts/build-app.sh --release v0.1
```

The first build compiles DuckDB from source and takes a few minutes. After
that it's seconds.

## macquetql

The same engine, in the terminal:

```bash
macquetql schema data.parquet
macquetql head   data.parquet 20
macquetql meta   data.parquet
macquetql sql    data.parquet "SELECT label, count(*) FROM tbl GROUP BY 1"
macquetql sample demo.parquet
```

`sample` writes a 25,000-row demo file shaped like an eval/red-teaming dataset
— long free text, categorical labels, scores, a list column and some nulls.

## Keyboard

| | |
| --- | --- |
| ↑ / ↓ | move the selected row |
| ⇞ / ⇟ | page through |
| ↖ / ↘ | first / last row |
| ⌘L | jump to a row number |
| ⌘F | search |
| ⌘T | SQL console |
| ⌥⌘I | row inspector |
| ⌘R | reload from disk |
| ⇧⌘R | reveal in Finder |
| ⌘C | copy the selected row |
| ⇧⌘C | copy the focused cell |

## Layout

```
Sources/
  MacquetCore/       ParquetTable actor, SQL building, the data model
  Macquet/           SwiftUI app
  MacquetQL/         CLI
  MacquetQuickLook/  Finder preview extension (.appex)
Scripts/
  build-app.sh   builds and installs the .app bundle
  make-icon.swift  draws Macquet.icns from scratch
```

`MacquetCore` has no UI dependencies — the app, the CLI and the Quick Look
extension are three front ends over the same actor.

## Notes

- Every value reaches the UI as text: the grid asks DuckDB to `CAST` each
  column to `VARCHAR`, keeping the logical type separately for alignment and
  colour. One decode path handles every Parquet type, nested `STRUCT`/`LIST`
  columns included.
- Column names and file paths are escaped before they reach SQL. A Parquet
  file is free to name a column `"); DROP …`.
- Beyond ~500,000 rows the scroll view stops mapping rows to pixels 1:1 —
  AppKit loses precision in very tall documents — and switches to proportional
  scrolling. Jump-to-row stays exact.
- `Macquet --capture <file> <out.png> [delay] [--scenario select:4]` renders a
  window to a PNG. It exists because the app was developed on a machine
  without screen-recording permission.

- Quick Look previews match on the `org.apache.parquet` type, which comes from
  the `.parquet` extension. Files in the Hugging Face cache are symlinks to
  extensionless blobs that macOS types as `public.data`, so they get the generic
  preview — claiming `public.data` would make Macquet the previewer for every
  unidentified file on the system. Opening them in the app works fine.

### Not built

No Spotlight importer, so Parquet files aren't indexed by row count or column
names. The app is ad-hoc signed for local use, not notarized for distribution.

## License

MIT — see [LICENSE](LICENSE). DuckDB is MIT-licensed too.
