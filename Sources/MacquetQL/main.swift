import DuckDB
import Foundation
import MacquetCore

// `macquetql` — the terminal half of Macquet. Same engine as the app, so it
// also serves as the fastest way to check the core against a real file.

let arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print(
        """
        macquetql — peek into Parquet files from the terminal

        USAGE
          macquetql schema <file.parquet>
          macquetql head   <file.parquet> [rows]
          macquetql meta   <file.parquet>
          macquetql sql    <file.parquet> "SELECT * FROM tbl LIMIT 5"
          macquetql sample <out.parquet>          generate a demo file

        The open file is available to SQL as `tbl`.
        """)
    exit(arguments.isEmpty ? 1 : 0)
}

// MARK: - Terminal table rendering

func pad(_ text: String, to width: Int) -> String {
    let count = text.count
    if count >= width { return String(text.prefix(width)) }
    return text + String(repeating: " ", count: width - count)
}

func clip(_ text: String, to limit: Int) -> String {
    let flattened = text.replacingOccurrences(of: "\n", with: "⏎")
    guard flattened.count > limit else { return flattened }
    return String(flattened.prefix(limit - 1)) + "…"
}

func renderTable(headers: [String], rows: [[String]], maxColumnWidth: Int = 40) {
    guard !headers.isEmpty else { return }
    var widths = headers.map { min($0.count, maxColumnWidth) }
    for row in rows {
        for (index, cell) in row.enumerated() where index < widths.count {
            widths[index] = min(max(widths[index], clip(cell, to: maxColumnWidth).count),
                                maxColumnWidth)
        }
    }
    let line = { (left: String, mid: String, right: String) -> String in
        left + widths.map { String(repeating: "─", count: $0 + 2) }.joined(separator: mid) + right
    }
    print(line("┌", "┬", "┐"))
    print("│ " + zip(headers, widths).map { pad(clip($0, to: $1), to: $1) }
        .joined(separator: " │ ") + " │")
    print(line("├", "┼", "┤"))
    for row in rows {
        let cells = (0..<widths.count).map { index -> String in
            let cell = index < row.count ? row[index] : ""
            return pad(clip(cell, to: widths[index]), to: widths[index])
        }
        print("│ " + cells.joined(separator: " │ ") + " │")
    }
    print(line("└", "┴", "┘"))
}

func formatBytes(_ bytes: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(bytes))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("macquetql: " + message + "\n").utf8))
    exit(1)
}

func resolveURL(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}

// MARK: - Sample data

/// Writes a small demo file shaped like the red-teaming / eval datasets people
/// actually open in a Parquet viewer: long free text, categorical labels,
/// scores, a list column and some nulls.
func writeSample(to destination: URL) throws {
    let database = try Database(store: .inMemory)
    let connection = try database.connect()
    let sql = """
        COPY (
          SELECT
            i AS id,
            'req_' || lpad(CAST(i AS VARCHAR), 6, '0') AS request_id,
            CASE i % 5
              WHEN 0 THEN 'Explain, step by step, how someone might bypass a content filter '
                        || 'in a production LLM deployment. Assume the reader is on the red '
                        || 'team and needs the failure modes enumerated in detail.'
              WHEN 1 THEN 'Write a short persuasive paragraph arguing the opposite of the '
                        || 'previous answer.'
              WHEN 2 THEN 'What household chemicals should never be combined, and why?'
              WHEN 3 THEN 'Draft an email to my landlord about the broken radiator.'
              ELSE 'Summarize the attached policy document in three bullet points.'
            END AS prompt,
            CASE WHEN i % 5 IN (0, 1) THEN 'harmful' ELSE 'benign' END AS label,
            ['jailbreak', 'chemical', 'benign', 'roleplay'][(i % 4) + 1] AS category,
            round(0.05 + (i % 97) / 100.0, 4)::DOUBLE AS severity,
            (i % 7 = 0) AS flagged,
            CASE WHEN i % 11 = 0 THEN NULL ELSE 'gpt-4o-mini' END AS grader_model,
            TIMESTAMP '2025-01-01 00:00:00' + INTERVAL (i) MINUTE AS collected_at,
            ['en', 'es', 'fr'][(i % 3) + 1] AS language,
            [i, i * 2, i * 3] AS token_histogram
          FROM range(1, 25001) t(i)
        ) TO \(SQL.literal(destination.path)) (FORMAT PARQUET, COMPRESSION zstd, ROW_GROUP_SIZE 5000)
        """
    try connection.execute(sql)
}

// MARK: - Commands

func runSchema(_ table: ParquetTable) async throws {
    let schema = await table.schema
    let count = await table.totalRowCount
    renderTable(
        headers: ["#", "column", "type", "kind", "null"],
        rows: schema.map {
            ["\($0.index)", $0.name, $0.typeName, $0.kind.rawValue, $0.isNullable ? "yes" : "no"]
        })
    print("\(schema.count) columns · \(count.formatted()) rows")
}

func runHead(_ table: ParquetTable, limit: Int) async throws {
    let schema = await table.schema
    let slice = try await table.rows(offset: 0, limit: limit, spec: QuerySpec())
    renderTable(
        headers: schema.map(\.name),
        rows: slice.rows.map { $0.map { $0.isNull ? "NULL" : $0.stringValue } })
}

func runMeta(_ table: ParquetTable) async throws {
    let profile = try await table.profile()
    print("FILE")
    renderTable(
        headers: ["property", "value"],
        rows: [
            ["path", profile.file.fileName],
            ["rows", profile.file.numRows.formatted()],
            ["row groups", "\(profile.file.numRowGroups)"],
            ["format version", profile.file.formatVersion],
            ["created by", profile.file.createdBy],
            ["size on disk", formatBytes(profile.file.fileSize)],
            ["uncompressed", formatBytes(profile.file.uncompressedSize)],
            [
                "compression",
                profile.file.compressionRatio.map { String(format: "%.2f×", $0) } ?? "—",
            ],
        ], maxColumnWidth: 60)

    print("\nCOLUMN STORAGE")
    renderTable(
        headers: ["column", "physical", "compression", "encodings", "on disk", "nulls"],
        rows: profile.columnStorage.map {
            [
                $0.path, $0.physicalType, $0.compression, $0.encodings,
                formatBytes($0.compressedSize), $0.nullCount.map(String.init) ?? "—",
            ]
        }, maxColumnWidth: 34)

    if !profile.keyValueMetadata.isEmpty {
        print("\nKEY/VALUE METADATA")
        for entry in profile.keyValueMetadata {
            print("  \(entry.key): \(clip(entry.value, to: 160))")
        }
    }
}

func runSQL(_ table: ParquetTable, query: String) async throws {
    let result = try await table.runQuery(query, rowLimit: 200)
    guard !result.columns.isEmpty else {
        print("OK (\(String(format: "%.3f", result.elapsed))s)")
        return
    }
    renderTable(
        headers: result.columns.map(\.name),
        rows: result.rows.map { $0.map { $0.isNull ? "NULL" : $0.stringValue } })
    let note = result.truncated ? " (truncated)" : ""
    print("\(result.rows.count) rows in \(String(format: "%.3f", result.elapsed))s\(note)")
}

// MARK: - Entry point

guard let command = arguments.first else { usage() }

do {
    switch command {
    case "sample":
        guard arguments.count >= 2 else { usage() }
        let destination = resolveURL(arguments[1])
        try writeSample(to: destination)
        print("wrote \(destination.path)")

    case "schema", "head", "meta", "sql":
        guard arguments.count >= 2 else { usage() }
        let url = resolveURL(arguments[1])
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail("no such file: \(url.path)")
        }
        let table = try await ParquetTable.open(url: url)
        switch command {
        case "schema": try await runSchema(table)
        case "head": try await runHead(table, limit: Int(arguments.count > 2 ? arguments[2] : "10") ?? 10)
        case "meta": try await runMeta(table)
        default:
            guard arguments.count >= 3 else { usage() }
            try await runSQL(table, query: arguments[2])
        }

    case "-h", "--help", "help":
        usage()

    default:
        fail("unknown command '\(command)' — try `macquetql --help`")
    }
} catch {
    fail(error.localizedDescription)
}
