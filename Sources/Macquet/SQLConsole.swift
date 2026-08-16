import MacquetCore
import SwiftUI

/// Bottom panel for running SQL against the open file.
///
/// The point of building on DuckDB is that "show me the data" and "answer a
/// question about the data" are the same tool. The open file is `tbl`.
struct SQLConsole: View {
    @ObservedObject var model: TableModel

    @State private var query = "SELECT * FROM tbl LIMIT 100"
    @State private var result: QueryResult?
    @State private var errorText: String?
    @State private var isRunning = false
    @State private var history: [String] = []
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            editor
            Divider()
            resultArea
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: Editor

    private var editor: some View {
        HStack(alignment: .top, spacing: 8) {
            TextEditor(text: $query)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(height: 62)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.04)))
                .focused($editorFocused)

            VStack(spacing: 6) {
                Button {
                    Task { await run() }
                } label: {
                    Label("Run", systemImage: "play.fill")
                        .frame(width: 54)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isRunning)
                .help("Run the query (⌘↩)")

                Menu {
                    Section("Snippets") {
                        ForEach(snippets, id: \.title) { snippet in
                            Button(snippet.title) { query = snippet.sql }
                        }
                    }
                    if !history.isEmpty {
                        Section("Recent") {
                            ForEach(history.prefix(8), id: \.self) { entry in
                                Button(entry.prefix(60) + (entry.count > 60 ? "…" : "")) {
                                    query = entry
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(8)
    }

    private var snippets: [(title: String, sql: String)] {
        let firstText = model.schema.first { $0.kind == .text }?.name
        let firstNumeric = model.schema.first { $0.kind.isNumeric }?.name
        var items: [(String, String)] = [
            ("All columns, first 100 rows", "SELECT * FROM tbl LIMIT 100"),
            ("Row count", "SELECT count(*) AS rows FROM tbl"),
            ("Random sample", "SELECT * FROM tbl USING SAMPLE 50 ROWS"),
            ("Full summary", "SUMMARIZE SELECT * FROM tbl"),
        ]
        if let firstText {
            let quoted = SQL.identifier(firstText)
            items.append((
                "Value counts for \(firstText)",
                "SELECT \(quoted), count(*) AS n FROM tbl GROUP BY 1 ORDER BY n DESC LIMIT 50"
            ))
            items.append((
                "Longest \(firstText)",
                "SELECT length(\(quoted)) AS len, \(quoted) FROM tbl ORDER BY len DESC LIMIT 20"
            ))
        }
        if let firstNumeric {
            let quoted = SQL.identifier(firstNumeric)
            items.append((
                "Distribution of \(firstNumeric)",
                "SELECT min(\(quoted)) AS min, median(\(quoted)) AS median, "
                    + "max(\(quoted)) AS max, avg(\(quoted)) AS avg FROM tbl"
            ))
        }
        return items.map { (title: $0.0, sql: $0.1) }
    }

    // MARK: Results

    @ViewBuilder
    private var resultArea: some View {
        if let errorText {
            ScrollView {
                Text(errorText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        } else if let result {
            if result.columns.isEmpty {
                Text("Statement executed in \(Format.duration(result.elapsed)).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    ResultTable(result: result)
                    Divider()
                    HStack(spacing: 8) {
                        Text(
                            "\(Format.count(result.rows.count)) rows in "
                                + Format.duration(result.elapsed))
                        if result.truncated {
                            Text("· truncated")
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Button("Copy as TSV") { copyResult(result) }
                            .buttonStyle(.link)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
            }
        } else {
            VStack(spacing: 4) {
                Text("The open file is available as `tbl`.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("⌘↩ to run")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func run() async {
        isRunning = true
        errorText = nil
        switch await model.runQuery(query) {
        case .success(let value):
            result = value
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            history.removeAll { $0 == trimmed }
            history.insert(trimmed, at: 0)
        case .failure(let failure):
            result = nil
            errorText = failure.message
        }
        isRunning = false
    }

    private func copyResult(_ result: QueryResult) {
        var lines = [result.columns.map(\.name).joined(separator: "\t")]
        for row in result.rows {
            lines.append(row.map { $0.isNull ? "" : $0.stringValue }.joined(separator: "\t"))
        }
        Finder.copyText(lines.joined(separator: "\n"))
    }
}

/// Simple scrollable table for console output. Console results are capped, so
/// this one can afford to be eager where the main grid cannot.
private struct ResultTable: View {
    let result: QueryResult

    private func width(for column: ColumnInfo) -> CGFloat {
        switch column.kind {
        case .boolean: return 70
        case .integer, .decimal: return 110
        case .temporal: return 160
        default: return 190
        }
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(result.rows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 0) {
                            ForEach(result.columns) { column in
                                cell(row: row, column: column)
                                Divider()
                            }
                        }
                        .frame(height: Theme.rowHeight)
                        .background(index.isMultiple(of: 2) ? Theme.stripe : Color.clear)
                    }
                } header: {
                    HStack(spacing: 0) {
                        ForEach(result.columns) { column in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Theme.accent(for: column.kind))
                                    .frame(width: 4, height: 4)
                                Text(column.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Theme.cellPadding)
                            .frame(width: width(for: column), alignment: .leading)
                            Divider()
                        }
                    }
                    .frame(height: Theme.headerHeight)
                    .background(Theme.headerBackground)
                }
            }
        }
    }

    @ViewBuilder
    private func cell(row: [CellValue], column: ColumnInfo) -> some View {
        let value = column.index < row.count ? row[column.index] : CellValue.null
        Group {
            if value.isNull {
                Text("null")
                    .font(.system(size: 11).italic())
                    .foregroundStyle(Theme.nullText)
            } else {
                Text(Format.inline(value.stringValue))
                    .font(Theme.font(for: column.kind))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(value.stringValue)
            }
        }
        .padding(.horizontal, Theme.cellPadding)
        .frame(
            width: width(for: column),
            alignment: column.kind.isNumeric ? .trailing : .leading)
    }
}
