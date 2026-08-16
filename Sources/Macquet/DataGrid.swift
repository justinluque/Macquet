import MacquetCore
import SwiftUI

/// The spreadsheet-style table.
///
/// Rows are virtualised by hand rather than handed to `LazyVStack`: with a
/// fixed row height, the visible range is a division, so the work per frame
/// scales with the window rather than with the file.
///
/// Two details make that safe at scale:
///
/// * Rows are positioned by **layout** — a leading spacer, the visible rows,
///   a trailing spacer — never by `.offset`. A `.offset` moves pixels but not
///   layout frames, and SwiftUI culls views whose frames are far off-screen,
///   so an offset-positioned grid renders blank once scrolled.
/// * Past `maxContentHeight` the scroll view stops mapping 1:1 (AppKit loses
///   precision in very tall documents) and switches to proportional scrolling:
///   the visible block is pinned to the viewport and which rows it holds
///   follows the scroll fraction.
struct DataGridView: View {
    @ObservedObject var model: TableModel

    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var verticalOffset: CGFloat = 0
    @State private var horizontalOffset: CGFloat = 0

    private static let maxContentHeight: CGFloat = 12_000_000

    private var columns: [ColumnInfo] { model.visibleColumns }

    private var showsGutter: Bool {
        UserDefaults.standard.object(forKey: Prefs.showRowNumbers) as? Bool ?? true
    }

    private var totalWidth: CGFloat {
        (showsGutter ? Theme.gutterWidth : 0)
            + columns.reduce(0) { $0 + model.width(for: $1) }
    }

    private var rowCount: Int { model.visibleRowCount }

    private var contentHeight: CGFloat {
        max(1, min(CGFloat(rowCount) * Theme.rowHeight, Self.maxContentHeight))
    }

    /// True while every row still has its own pixel position.
    private var isExactlyMapped: Bool {
        CGFloat(rowCount) * Theme.rowHeight <= Self.maxContentHeight
    }

    private func visibleRowCapacity(viewportHeight: CGFloat) -> Int {
        max(1, Int(ceil(viewportHeight / Theme.rowHeight)) + 2)
    }

    /// The window of rows to build, and the spacer height that puts them in
    /// the right place.
    private func layout(viewportHeight: CGFloat) -> (firstRow: Int, topInset: CGFloat) {
        guard rowCount > 0 else { return (0, 0) }
        if isExactlyMapped {
            let first = min(max(0, Int(verticalOffset / Theme.rowHeight)), max(0, rowCount - 1))
            return (first, CGFloat(first) * Theme.rowHeight)
        }
        let usable = max(1, contentHeight - viewportHeight)
        let fraction = min(max(verticalOffset / usable, 0), 1)
        let capacity = visibleRowCapacity(viewportHeight: viewportHeight)
        let maxFirst = max(0, rowCount - capacity + 2)
        let first = min(Int((fraction * CGFloat(maxFirst)).rounded()), max(0, rowCount - 1))
        return (first, verticalOffset)
    }

    /// Scroll offset that brings `row` to the top of the viewport.
    private func targetOffset(forRow row: Int, viewportHeight: CGFloat) -> CGFloat {
        guard rowCount > 0 else { return 0 }
        if isExactlyMapped {
            return CGFloat(row) * Theme.rowHeight
        }
        let capacity = visibleRowCapacity(viewportHeight: viewportHeight)
        let maxFirst = max(1, rowCount - capacity + 2)
        let fraction = min(max(CGFloat(row) / CGFloat(maxFirst), 0), 1)
        return fraction * max(1, contentHeight - viewportHeight)
    }

    var body: some View {
        GeometryReader { proxy in
            let viewportHeight = max(0, proxy.size.height - Theme.headerHeight)
            let pageStep = max(1, Int(viewportHeight / Theme.rowHeight) - 1)

            VStack(spacing: 0) {
                header(viewportWidth: proxy.size.width)
                ScrollView([.horizontal, .vertical]) {
                    rows(
                        viewportHeight: viewportHeight,
                        rowWidth: max(totalWidth, proxy.size.width))
                }
                .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: ScrollSnapshot.self) { geometry in
                ScrollSnapshot(
                    x: geometry.contentOffset.x + geometry.contentInsets.leading,
                    y: geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, snapshot in
                horizontalOffset = max(0, snapshot.x)
                verticalOffset = max(0, snapshot.y)
                let placement = layout(viewportHeight: viewportHeight)
                model.viewportChanged(
                    firstVisibleRow: placement.firstRow,
                    lastVisibleRow: placement.firstRow
                        + visibleRowCapacity(viewportHeight: viewportHeight))
            }
            .onChange(of: model.scrollRequest) { _, request in
                guard let request else { return }
                let target = targetOffset(forRow: request, viewportHeight: viewportHeight)
                scrollPosition.scrollTo(y: target)
                model.scrollRequest = nil
            }
            }
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand { direction in
                switch direction {
                case .up: model.moveSelection(by: -1)
                case .down: model.moveSelection(by: 1)
                default: break
                }
            }
            .onKeyPress(.pageUp) {
                model.moveSelection(by: -pageStep)
                return .handled
            }
            .onKeyPress(.pageDown) {
                model.moveSelection(by: pageStep)
                return .handled
            }
            .onKeyPress(.home) {
                model.jump(toRow: 0)
                return .handled
            }
            .onKeyPress(.end) {
                model.jump(toRow: model.visibleRowCount - 1)
                return .handled
            }
            .copyable(copyPayload())
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Column header, pinned to the top and slid sideways to stay above its
    /// columns as the grid scrolls horizontally.
    private func header(viewportWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            GridHeaderView(model: model, showsGutter: showsGutter)
                .frame(width: max(totalWidth, viewportWidth), alignment: .leading)
                .offset(x: -horizontalOffset)
            Divider()
        }
        // A definite width, not `maxWidth: .infinity`: the header's inner frame
        // is as wide as all the columns, and without this the enclosing VStack
        // adopts that width and pushes the grid out of the window.
        .frame(width: viewportWidth, alignment: .leading)
        .clipped()
    }

    private func rows(viewportHeight: CGFloat, rowWidth: CGFloat) -> some View {
        let placement = layout(viewportHeight: viewportHeight)
        let upper = min(rowCount, placement.firstRow + visibleRowCapacity(viewportHeight: viewportHeight))
        let bodyHeight = CGFloat(max(0, upper - placement.firstRow)) * Theme.rowHeight
        let bottomInset = max(0, contentHeight - placement.topInset - bodyHeight)

        return VStack(spacing: 0) {
            if placement.firstRow < upper {
                ForEach(placement.firstRow..<upper, id: \.self) { index in
                    GridRowView(
                        model: model,
                        index: index,
                        columns: columns,
                        showsGutter: showsGutter,
                        width: rowWidth
                    )
                    .frame(height: Theme.rowHeight)
                }
            }
        }
        .padding(.top, placement.topInset)
        .padding(.bottom, bottomInset)
    }

    /// Supplies ⌘C with the selected row as tab-separated text.
    ///
    /// Prefers the inspector's values, which are fetched untruncated when a row
    /// is selected. The grid's own cached cells are clipped to
    /// `gridCellCharacterLimit` for display, and copying those would silently
    /// hand over a 600-character prefix of a long prompt.
    private func copyPayload() -> [String] {
        guard let index = model.selectedRowIndex else { return [] }
        guard let values = model.selectedRowValues ?? model.row(at: index)?.cells else {
            return []
        }
        let header = model.schema.map(\.name).joined(separator: "\t")
        let line = values.map { $0.isNull ? "" : $0.stringValue }.joined(separator: "\t")
        return [header + "\n" + line]
    }
}

/// Scroll offsets, normalised past the pinned header inset.
private struct ScrollSnapshot: Equatable {
    let x: CGFloat
    let y: CGFloat
}

// MARK: - Header

struct GridHeaderView: View {
    @ObservedObject var model: TableModel
    let showsGutter: Bool

    var body: some View {
        HStack(spacing: 0) {
            if showsGutter {
                Text("#")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: Theme.gutterWidth, alignment: .trailing)
                    .padding(.trailing, Theme.cellPadding)
                Divider()
            }
            ForEach(model.visibleColumns) { column in
                headerCell(for: column)
                Divider()
            }
            Spacer(minLength: 0)
        }
        .frame(height: Theme.headerHeight)
        .background(Theme.headerBackground)
    }

    private func headerCell(for column: ColumnInfo) -> some View {
        let sort = model.spec.sort
        let isSorted = sort?.columnName == column.name

        return HStack(spacing: 4) {
            Circle()
                .fill(Theme.accent(for: column.kind))
                .frame(width: 5, height: 5)
            Text(column.name)
                .font(.system(size: 11, weight: isSorted ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            if isSorted, let direction = sort?.direction {
                Image(systemName: direction.symbolName)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tint)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.cellPadding)
        .frame(width: model.width(for: column), height: Theme.headerHeight, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { Task { await model.toggleSort(on: column.name) } }
        .help("\(column.name) — \(column.typeName)")
        .overlay(alignment: .trailing) {
            ColumnResizeHandle(model: model, column: column)
        }
        .contextMenu { ColumnMenu(model: model, column: column) }
    }
}

/// Drag target on a column's trailing edge.
private struct ColumnResizeHandle: View {
    @ObservedObject var model: TableModel
    let column: ColumnInfo
    @State private var widthAtDragStart: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = widthAtDragStart ?? model.width(for: column)
                        if widthAtDragStart == nil { widthAtDragStart = base }
                        model.setWidth(base + value.translation.width, for: column)
                    }
                    .onEnded { _ in widthAtDragStart = nil }
            )
    }
}

struct ColumnMenu: View {
    @ObservedObject var model: TableModel
    let column: ColumnInfo

    var body: some View {
        Button("Sort Ascending") {
            Task { await model.setSort(column: column.name, direction: .ascending) }
        }
        Button("Sort Descending") {
            Task { await model.setSort(column: column.name, direction: .descending) }
        }
        Divider()
        Button("Search Only This Column") {
            Task { await model.setSearchColumn(column.name) }
        }
        Button("Search All Columns") {
            Task { await model.setSearchColumn(nil) }
        }
        Divider()
        Button("Copy Column Name") { Finder.copyText(column.name) }
        Button("Hide Column") { model.toggleVisibility(of: column) }
        if !model.hiddenColumns.isEmpty {
            Button("Show All Columns") { model.showAllColumns() }
        }
    }
}

// MARK: - Rows

struct GridRowView: View {
    @ObservedObject var model: TableModel
    let index: Int
    let columns: [ColumnInfo]
    let showsGutter: Bool
    /// Explicit width, rather than a trailing `Spacer`.
    ///
    /// A two-axis `ScrollView` proposes an unspecified width to its content,
    /// and a flexible `Spacer` resolves that to something unbounded — the row
    /// then wants an enormous layer and nothing in the grid draws at all.
    let width: CGFloat

    private var isSelected: Bool { model.selectedRowIndex == index }

    var body: some View {
        let entry = model.row(at: index)

        HStack(spacing: 0) {
            if showsGutter {
                Text(gutterLabel(for: entry))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isSelected ? .primary : .tertiary)
                    .frame(width: Theme.gutterWidth, alignment: .trailing)
                    .padding(.trailing, Theme.cellPadding)
                Divider()
            }
            ForEach(Array(columns.enumerated()), id: \.element.id) { _, column in
                cell(for: column, entry: entry)
                Divider()
            }
        }
        .frame(width: width, height: Theme.rowHeight, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture { model.select(rowIndex: index) }
        .contextMenu {
            Button("Copy Row as TSV") {
                Task { await model.copyRow(at: index, as: .tabSeparated) }
            }
            Button("Copy Row as JSON") {
                Task { await model.copyRow(at: index, as: .json) }
            }
        }
    }

    private func gutterLabel(for entry: RowEntry?) -> String {
        if let number = entry?.fileRowNumber { return "\(number)" }
        return "\(index)"
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            Color.accentColor.opacity(0.18)
        } else if index.isMultiple(of: 2) {
            Theme.stripe
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func cell(for column: ColumnInfo, entry: RowEntry?) -> some View {
        let alignment: Alignment = column.kind.isNumeric ? .trailing : .leading
        Group {
            if let entry, column.index < entry.cells.count {
                let value = entry.cells[column.index]
                if value.isNull {
                    Text("null")
                        .font(.system(size: 11).italic())
                        .foregroundStyle(Theme.nullText)
                } else {
                    Text(Format.inline(value.stringValue))
                        .font(Theme.font(for: column.kind))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else {
                // Placeholder while the page is in flight.
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 9)
                    .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, Theme.cellPadding)
        .frame(width: model.width(for: column), alignment: alignment)
    }
}
