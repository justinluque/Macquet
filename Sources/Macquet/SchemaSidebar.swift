import MacquetCore
import SwiftUI

/// Left sidebar: the file's columns, and the Parquet footer behind them.
struct SchemaSidebar: View {
    @ObservedObject var model: TableModel
    @State private var section: Section = .columns
    @State private var expandedColumn: String?

    enum Section: String, CaseIterable, Identifiable {
        case columns = "Columns"
        case file = "File"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Divider()

            switch section {
            case .columns: columnList
            case .file: FileFactsView(model: model)
            }
        }
    }

    private var columnList: some View {
        List {
            ForEach(model.schema) { column in
                ColumnRow(
                    model: model,
                    column: column,
                    isExpanded: expandedColumn == column.name,
                    onToggleExpanded: {
                        expandedColumn = expandedColumn == column.name ? nil : column.name
                    })
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if !model.hiddenColumns.isEmpty {
                HStack {
                    Text("\(model.hiddenColumns.count) hidden")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show All") { model.showAllColumns() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
    }
}

/// One column in the sidebar, expanding into its statistics on demand.
private struct ColumnRow: View {
    @ObservedObject var model: TableModel
    let column: ColumnInfo
    let isExpanded: Bool
    let onToggleExpanded: () -> Void

    @State private var profile: ColumnProfile?
    @State private var topValues: [(String, Int)] = []
    @State private var isLoading = false

    private var isHidden: Bool { model.hiddenColumns.contains(column.name) }
    private var storage: ColumnStorageInfo? {
        // Nested columns appear in the footer under a dotted leaf path.
        model.profile?.columnStorage.first {
            $0.path == column.name || $0.path.hasPrefix(column.name + ",")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if isExpanded { details }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleExpanded)
        .contextMenu { ColumnMenu(model: model, column: column) }
        .task(id: isExpanded) {
            guard isExpanded, profile == nil else { return }
            isLoading = true
            profile = await model.columnProfile(for: column.name)
            if column.kind != .binary {
                topValues = await model.topValues(for: column.name)
            }
            isLoading = false
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: column.kind.symbolName)
                .font(.system(size: 10))
                .foregroundStyle(Theme.accent(for: column.kind))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(column.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(isHidden, color: .secondary)
                Text(column.typeName)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                model.toggleVisibility(of: column)
            } label: {
                Image(systemName: isHidden ? "eye.slash" : "eye")
                    .font(.system(size: 10))
                    .foregroundStyle(isHidden ? .secondary : .tertiary)
            }
            .buttonStyle(.plain)
            .help(isHidden ? "Show this column" : "Hide this column")

            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .opacity(isHidden ? 0.55 : 1)
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoading {
                ProgressView().controlSize(.small)
            }

            if let profile {
                statGrid(profile)
            }

            if let storage {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    fact("stored as", storage.physicalType)
                    fact("compression", storage.compression)
                    fact("encodings", storage.encodings)
                    fact(
                        "on disk",
                        "\(Format.bytes(storage.compressedSize)) "
                            + "(\(Format.ratio(storage.compressionRatio)))")
                }
            }

            if !topValues.isEmpty {
                Divider()
                Text("MOST COMMON")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                ValueHistogram(values: topValues, total: model.totalRowCount) { value in
                    Task { await filter(byValue: value) }
                }
            }
        }
        .padding(.leading, 20)
        .padding(.bottom, 4)
    }

    private func statGrid(_ profile: ColumnProfile) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let distinct = profile.distinctCount {
                fact("distinct", "≈\(Format.count(distinct))")
            }
            if let nulls = profile.nullPercentage {
                fact("null", Format.percent(nulls))
            }
            if let min = profile.min { fact("min", min) }
            if let max = profile.max { fact("max", max) }
            if let average = profile.average { fact("avg", average) }
            if let median = profile.median { fact("median", median) }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func filter(byValue value: String) async {
        guard value != "∅ null" else {
            await model.setWhereClause("\(SQL.identifier(column.name)) IS NULL")
            return
        }
        await model.setWhereClause(
            "CAST(\(SQL.identifier(column.name)) AS VARCHAR) = \(SQL.literal(value))")
    }
}

/// Tiny bar chart of a column's most frequent values; clicking one filters.
private struct ValueHistogram: View {
    let values: [(String, Int)]
    let total: Int
    let onSelect: (String) -> Void

    private var maxCount: Int { values.map(\.1).max() ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, entry in
                Button {
                    onSelect(entry.0)
                } label: {
                    HStack(spacing: 4) {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.accentColor.opacity(0.18))
                                    .frame(
                                        width: max(
                                            2,
                                            geometry.size.width * CGFloat(entry.1)
                                                / CGFloat(maxCount)))
                                Text(entry.0)
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .padding(.leading, 4)
                            }
                        }
                        .frame(height: 14)
                        Text(Format.compactCount(entry.1))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
                .buttonStyle(.plain)
                .help("Filter to \(entry.0)")
            }
        }
    }
}

// MARK: - File facts

struct FileFactsView: View {
    @ObservedObject var model: TableModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                fileCard

                if let profile = model.profile {
                    if !profile.rowGroups.isEmpty {
                        section("ROW GROUPS") {
                            RowGroupStrip(groups: profile.rowGroups)
                        }
                    }
                    if !profile.keyValueMetadata.isEmpty {
                        section("EMBEDDED METADATA") {
                            ForEach(profile.keyValueMetadata) { entry in
                                MetadataDisclosure(entry: entry)
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private var fileCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(nsImage: Finder.fileIcon(for: model.url, size: 32))
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.url.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(model.url.deletingLastPathComponent().path)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .contextMenu {
                Button("Reveal in Finder") { Finder.reveal(model.url) }
                Button("Copy Path") { Finder.copyPath(model.url) }
            }

            Divider()

            if let file = model.profile?.file {
                fact("rows", Format.count(file.numRows))
                fact("columns", "\(model.schema.count)")
                fact("row groups", "\(file.numRowGroups)")
                fact("size on disk", Format.bytes(file.fileSize))
                fact("uncompressed", Format.bytes(file.uncompressedSize))
                fact("compression", Format.ratio(file.compressionRatio))
                if !file.formatVersion.isEmpty {
                    fact("format", "Parquet v\(file.formatVersion)")
                }
                if !file.createdBy.isEmpty {
                    fact("written by", file.createdBy)
                }
                if !file.encryptionAlgorithm.isEmpty {
                    fact("encryption", file.encryptionAlgorithm)
                }
            } else {
                fact("rows", Format.count(model.totalRowCount))
                fact("columns", "\(model.schema.count)")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04)))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 86, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }

    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            content()
        }
    }
}

/// Row groups drawn to scale, so an unevenly written file is visible at a glance.
private struct RowGroupStrip: View {
    let groups: [RowGroupInfo]

    private var totalRows: Int { max(1, groups.reduce(0) { $0 + $1.numRows }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    ForEach(groups) { group in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.accentColor.opacity(0.45))
                            .frame(
                                width: max(
                                    1,
                                    (geometry.size.width - CGFloat(groups.count))
                                        * CGFloat(group.numRows) / CGFloat(totalRows)))
                            .help(
                                "Row group \(group.id): \(Format.count(group.numRows)) rows, "
                                    + Format.bytes(group.compressedSize))
                    }
                }
            }
            .frame(height: 16)

            Text(
                "\(groups.count) groups · "
                    + "\(Format.count(totalRows / max(1, groups.count))) rows each on average")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct MetadataDisclosure: View {
    let entry: KeyValueMetadata
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView {
                Text(entry.prettyValue)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        } label: {
            HStack {
                Text(entry.key)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Button {
                    Finder.copyText(entry.prettyValue)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Copy value")
            }
        }
    }
}
