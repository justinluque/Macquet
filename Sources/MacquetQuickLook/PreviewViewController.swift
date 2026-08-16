import AppKit
import MacquetCore
import QuickLookUI
import SwiftUI

/// Finder's spacebar preview for a Parquet file.
///
/// Quick Look gives an extension a short budget and a modest amount of memory,
/// so this reads the footer and one page of rows and stops. It is the same
/// ``ParquetTable`` the app uses — the extension is a third front end over the
/// core, not a reimplementation.
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {

    /// Rows to show. Enough to judge the shape of the data, few enough that a
    /// preview never becomes a scrolling session.
    private static let previewRowLimit = 60

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 560))
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let table = try await ParquetTable.open(url: url)
        let schema = await table.schema
        let totalRows = await table.totalRowCount
        let slice = try await table.rows(
            offset: 0, limit: Self.previewRowLimit, spec: QuerySpec())
        let profile = try? await table.profile()

        let summary = PreviewSummary(
            fileName: url.lastPathComponent,
            rowCount: totalRows,
            schema: schema,
            rows: slice.rows,
            fileSize: profile?.file.fileSize ?? 0,
            uncompressedSize: profile?.file.uncompressedSize ?? 0,
            rowGroups: profile?.file.numRowGroups ?? 0,
            createdBy: profile?.file.createdBy ?? "",
            compression: profile?.columnStorage.first?.compression ?? "")

        await MainActor.run {
            let hosting = NSHostingView(rootView: PreviewContent(summary: summary))
            hosting.frame = view.bounds
            hosting.autoresizingMask = [.width, .height]
            view.subviews.forEach { $0.removeFromSuperview() }
            view.addSubview(hosting)
            preferredContentSize = NSSize(width: 820, height: 560)
        }
    }
}

/// Everything the preview needs, gathered off the main thread.
struct PreviewSummary: Sendable {
    let fileName: String
    let rowCount: Int
    let schema: [ColumnInfo]
    let rows: [[CellValue]]
    let fileSize: Int
    let uncompressedSize: Int
    let rowGroups: Int
    let createdBy: String
    let compression: String

    var compressionRatio: Double? {
        guard fileSize > 0, uncompressedSize > 0 else { return nil }
        return Double(uncompressedSize) / Double(fileSize)
    }
}

// MARK: - View

struct PreviewContent: View {
    let summary: PreviewSummary

    private static let rowHeight: CGFloat = 22
    private static let maxColumnWidth: CGFloat = 260

    /// Widths from the header and a sample of the values, since the preview has
    /// no way to resize columns.
    private func width(for column: ColumnInfo) -> CGFloat {
        var longest = column.name.count + 3
        for row in summary.rows.prefix(25) where column.index < row.count {
            longest = max(longest, min(row[column.index].stringValue.count, 60))
        }
        return min(max(CGFloat(longest) * 7.0 + 20, 60), Self.maxColumnWidth)
    }

    private var totalWidth: CGFloat {
        44 + summary.schema.reduce(0) { $0 + width(for: $1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if summary.schema.isEmpty {
                Text("No columns")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                grid
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(summary.fileName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(
                "\(summary.rowCount.formatted()) rows · \(summary.schema.count) columns"
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var grid: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(spacing: 0) {
                columnHeader
                ForEach(Array(summary.rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 0) {
                        Text("\(index)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 36, alignment: .trailing)
                            .padding(.trailing, 8)
                        ForEach(summary.schema) { column in
                            cell(row: row, column: column)
                        }
                    }
                    .frame(width: totalWidth, height: Self.rowHeight, alignment: .leading)
                    .background(
                        index.isMultiple(of: 2)
                            ? Color.primary.opacity(0.03) : Color.clear)
                }
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 44, height: 1)
            ForEach(summary.schema) { column in
                VStack(alignment: .leading, spacing: 0) {
                    Text(column.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text(column.typeName)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .frame(width: width(for: column), alignment: .leading)
            }
        }
        .frame(width: totalWidth, height: 32, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func cell(row: [CellValue], column: ColumnInfo) -> some View {
        let value = column.index < row.count ? row[column.index] : CellValue.null
        return Group {
            if value.isNull {
                Text("null")
                    .font(.system(size: 10).italic())
                    .foregroundStyle(.tertiary)
            } else {
                Text(inline(value.stringValue))
                    .font(.system(size: 11, design: column.kind.isNumeric ? .monospaced : .default))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 6)
        .frame(
            width: width(for: column),
            alignment: column.kind.isNumeric ? .trailing : .leading)
    }

    private func inline(_ text: String) -> String {
        guard text.contains(where: \.isNewline) else { return text }
        return text.replacingOccurrences(of: "\n", with: " ⏎ ")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if summary.fileSize > 0 {
                label(byteString(summary.fileSize))
            }
            if let ratio = summary.compressionRatio {
                label(String(format: "%.1f× compressed", ratio))
            }
            if !summary.compression.isEmpty {
                label(summary.compression)
            }
            if summary.rowGroups > 0 {
                label("\(summary.rowGroups) row groups")
            }
            Spacer()
            if summary.rows.count < summary.rowCount {
                Text("first \(summary.rows.count) rows")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(.bar)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
    }

    private func byteString(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
