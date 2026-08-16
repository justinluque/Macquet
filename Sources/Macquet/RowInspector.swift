import MacquetCore
import SwiftUI

/// Right-hand pane showing one row in full.
///
/// This is the half of the app that matters for text-heavy datasets: the grid
/// shows a clipped preview, and everything long — a full prompt, a completion,
/// a JSON blob — is readable here without leaving the window.
struct RowInspector: View {
    @ObservedObject var model: TableModel
    @AppStorage(Prefs.wrapCellText) private var wrapText = true

    var body: some View {
        VStack(spacing: 0) {
            if model.selectedRowIndex == nil {
                emptyState
            } else {
                header
                Divider()
                fields
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.and.text.magnifyingglass")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("Select a row")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Its full values appear here — no truncation.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                model.moveSelection(by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled((model.selectedRowIndex ?? 0) <= 0)
            .help("Previous row (↑)")

            Button {
                model.moveSelection(by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled((model.selectedRowIndex ?? 0) >= model.visibleRowCount - 1)
            .help("Next row (↓)")

            VStack(alignment: .leading, spacing: 0) {
                Text("Row \(Format.count(model.selectedRowIndex ?? 0))")
                    .font(.system(size: 12, weight: .semibold))
                Text("of \(Format.count(model.visibleRowCount))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle(isOn: $wrapText) {
                Image(systemName: "text.alignleft")
            }
            .toggleStyle(.button)
            .help("Wrap long values")

            Menu {
                Button("Copy Row as JSON") {
                    Task { await model.copySelectedRow(as: .json) }
                }
                Button("Copy Row as TSV") {
                    Task { await model.copySelectedRow(as: .tabSeparated) }
                }
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Copy this row")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var fields: some View {
        if let values = model.selectedRowValues {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.schema) { column in
                        FieldView(
                            column: column,
                            value: column.index < values.count
                                ? values[column.index] : .null,
                            wrapText: wrapText,
                            highlight: model.spec.searchText)
                        Divider()
                    }
                }
            }
        } else {
            VStack {
                ProgressView().controlSize(.small)
                Text("Loading row…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One field of the selected row.
private struct FieldView: View {
    let column: ColumnInfo
    let value: CellValue
    let wrapText: Bool
    let highlight: String

    @State private var isCollapsed = false

    /// Values longer than this start collapsed so a single 40 KB completion
    /// doesn't bury every field beneath it.
    private static let collapseThreshold = 900

    private var text: String { value.stringValue }
    private var isLong: Bool { text.count > Self.collapseThreshold }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: column.kind.symbolName)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.accent(for: column.kind))
                Text(column.name)
                    .font(.system(size: 11, weight: .semibold))
                Text(column.typeName)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Spacer()

                if !value.isNull {
                    Text(lengthLabel)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.quaternary)
                }

                Button {
                    Finder.copyText(text)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Copy value")
                .disabled(value.isNull)
            }

            if value.isNull {
                Text("null")
                    .font(.system(size: 11).italic())
                    .foregroundStyle(Theme.nullText)
            } else {
                valueBody
            }

            if isLong {
                Button(isCollapsed ? "Show all \(Format.count(text.count)) characters" : "Collapse")
                {
                    isCollapsed.toggle()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { isCollapsed = isLong }
    }

    private var lengthLabel: String {
        column.kind == .text ? "\(Format.count(text.count)) chars" : ""
    }

    @ViewBuilder
    private var valueBody: some View {
        let shown = isCollapsed ? String(text.prefix(Self.collapseThreshold)) + "…" : text
        Text(attributed(shown))
            .font(.system(size: 12, design: monospacedKind ? .monospaced : .default))
            .textSelection(.enabled)
            .lineLimit(wrapText ? nil : 1)
            .fixedSize(horizontal: false, vertical: wrapText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var monospacedKind: Bool {
        switch column.kind {
        case .text: return false
        default: return true
        }
    }

    /// Highlights the active search term inside the value, so a hit in a long
    /// prompt is findable instead of merely present.
    private func attributed(_ source: String) -> AttributedString {
        var result = AttributedString(source)
        let needle = highlight.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2 else { return result }

        var searchRange = result.startIndex..<result.endIndex
        while let found = result[searchRange].range(of: needle, options: [.caseInsensitive]) {
            result[found].backgroundColor = .yellow.opacity(0.45)
            result[found].foregroundColor = .black
            guard found.upperBound < result.endIndex else { break }
            searchRange = found.upperBound..<result.endIndex
        }
        return result
    }
}
