import AppKit
import MacquetCore
import SwiftUI

/// One row as the grid sees it.
struct RowEntry: Identifiable, Equatable {
    let index: Int
    let cells: [CellValue]
    let fileRowNumber: Int?
    var id: Int { index }
}

/// View state for a single open file.
///
/// The grid never holds the whole table: rows arrive in pages, are cached
/// around the viewport, and are dropped once the user scrolls away. Every
/// query runs on ``ParquetTable``'s actor, so the main thread only ever
/// receives finished value types.
@MainActor
final class TableModel: ObservableObject {

    enum LoadState: Equatable {
        case idle
        case opening
        case ready
        case failed(String)
    }

    // MARK: Published state

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var schema: [ColumnInfo] = []
    @Published private(set) var totalRowCount = 0
    /// Rows matching the current filter — equal to `totalRowCount` when unfiltered.
    @Published private(set) var visibleRowCount = 0
    @Published private(set) var isFetching = false
    @Published private(set) var profile: ParquetProfile?
    @Published private(set) var fileChangedOnDisk = false
    @Published var errorMessage: String?

    @Published var spec = QuerySpec()
    @Published var searchField = "" { didSet { scheduleSearchUpdate() } }

    @Published var selectedRowIndex: Int?
    @Published private(set) var selectedRowValues: [CellValue]?
    @Published var focusedColumn: String?

    @Published var columnWidths: [String: CGFloat] = [:]
    @Published var hiddenColumns: Set<String> = []

    @Published private(set) var pages: [Int: [RowEntry]] = [:]

    /// Set to ask the grid to scroll a row into view; the grid clears it.
    @Published var scrollRequest: Int?
    /// Rows currently on screen, maintained by the grid.
    private(set) var visibleRange: ClosedRange<Int> = 0...0

    let url: URL

    /// The most recently opened model. Used by the `--capture` developer hook
    /// to drive a window into a particular state before snapshotting it.
    private(set) static weak var mostRecentlyOpened: TableModel?

    // MARK: Private state

    private var table: ParquetTable?
    private var inFlightPages: Set<Int> = []
    private var generation = 0
    private var searchTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var watcher: FileWatcher?
    private var visiblePageRange: ClosedRange<Int> = 0...0

    private var pageSize: Int {
        let stored = UserDefaults.standard.integer(forKey: Prefs.pageSize)
        return stored > 0 ? stored : 200
    }
    /// Pages kept on either side of the viewport before eviction.
    private let cacheRadius = 3

    init(url: URL) {
        self.url = url
    }

    // MARK: - Opening

    func open() async {
        guard state == .idle else { return }
        state = .opening
        do {
            let table = try await ParquetTable.open(url: url)
            self.table = table
            schema = await table.schema
            totalRowCount = await table.totalRowCount
            visibleRowCount = totalRowCount
            state = .ready
            Self.mostRecentlyOpened = self
            startWatching()
            await loadProfile()
            await ensureLoaded(pageRange: 0...0)
        } catch {
            state = .failed(errorText(error))
        }
    }

    private func loadProfile() async {
        guard let table else { return }
        profile = try? await table.profile()
    }

    private func startWatching() {
        watcher = FileWatcher(url: url) { [weak self] in
            Task { @MainActor in self?.fileChangedOnDisk = true }
        }
    }

    /// Dismisses the "changed on disk" notice without re-reading.
    func dismissChangeNotice() {
        fileChangedOnDisk = false
    }

    /// Re-reads the file after an external write, keeping the user's filter,
    /// sort and scroll position.
    func reload() async {
        guard let table else { return }
        fileChangedOnDisk = false
        watcher?.stop()
        do {
            try await table.reload()
            schema = await table.schema
            totalRowCount = await table.totalRowCount
            invalidateRows()
            await refreshCount()
            await ensureLoaded(pageRange: visiblePageRange)
            await loadProfile()
            startWatching()
        } catch {
            errorMessage = errorText(error)
        }
    }

    // MARK: - Query spec

    private func scheduleSearchUpdate() {
        searchTask?.cancel()
        let text = searchField
        searchTask = Task { [weak self] in
            // Typing a filter re-counts and re-reads the file, so wait for a
            // pause rather than doing that on every keystroke.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.applySearch(text)
        }
    }

    private func applySearch(_ text: String) async {
        guard spec.searchText != text else { return }
        spec.searchText = text
        await specDidChange()
    }

    func setWhereClause(_ clause: String) async {
        guard spec.whereClause != clause else { return }
        spec.whereClause = clause
        await specDidChange()
    }

    func setSearchColumn(_ column: String?) async {
        guard spec.searchColumn != column else { return }
        spec.searchColumn = column
        await specDidChange()
    }

    func setSort(column: String, direction: ColumnSort.Direction) async {
        let descriptor = ColumnSort(columnName: column, direction: direction)
        guard spec.sort != descriptor else { return }
        spec.sort = descriptor
        await specDidChange()
    }

    /// Cycles a column between ascending, descending and unsorted.
    func toggleSort(on columnName: String) async {
        if spec.sort?.columnName == columnName {
            if spec.sort?.direction == .ascending {
                spec.sort?.direction = .descending
            } else {
                spec.sort = nil
            }
        } else {
            spec.sort = ColumnSort(columnName: columnName, direction: .ascending)
        }
        await specDidChange()
    }

    func clearFilters() async {
        searchTask?.cancel()
        searchField = ""
        spec.searchText = ""
        spec.whereClause = ""
        spec.searchColumn = nil
        await specDidChange()
    }

    private func specDidChange() async {
        invalidateRows()
        selectedRowIndex = nil
        selectedRowValues = nil
        await refreshCount()
        await ensureLoaded(pageRange: 0...0)
    }

    private func invalidateRows() {
        generation += 1
        pages.removeAll()
        inFlightPages.removeAll()
    }

    private func refreshCount() async {
        guard let table else { return }
        do {
            visibleRowCount = try await table.rowCount(matching: spec)
        } catch {
            errorMessage = errorText(error)
            visibleRowCount = 0
        }
    }

    // MARK: - Row access

    /// Cached lookup only — never triggers a fetch, so it is safe to call from
    /// a view body.
    func row(at index: Int) -> RowEntry? {
        let page = index / pageSize
        guard let rows = pages[page] else { return nil }
        let offset = index % pageSize
        return offset < rows.count ? rows[offset] : nil
    }

    /// Called when the visible range changes; loads what's on screen plus a
    /// little margin, and evicts what's far away.
    func viewportChanged(firstVisibleRow: Int, lastVisibleRow: Int) {
        guard visibleRowCount > 0 else { return }
        visibleRange = max(0, firstVisibleRow)...max(0, max(firstVisibleRow, lastVisibleRow))
        let first = max(0, firstVisibleRow) / pageSize
        let last = max(0, min(lastVisibleRow, visibleRowCount - 1)) / pageSize
        let range = first...max(first, last)
        guard range != visiblePageRange else { return }
        visiblePageRange = range
        Task { await ensureLoaded(pageRange: range) }
    }

    private func ensureLoaded(pageRange: ClosedRange<Int>) async {
        guard let table, state == .ready else { return }
        let lastPage = visibleRowCount == 0 ? 0 : (visibleRowCount - 1) / pageSize
        let wanted = max(0, pageRange.lowerBound - 1)...min(lastPage, pageRange.upperBound + 1)
        evictPages(keeping: wanted)

        for page in wanted where pages[page] == nil && !inFlightPages.contains(page) {
            inFlightPages.insert(page)
            let currentGeneration = generation
            let offset = page * pageSize
            let limit = pageSize
            let currentSpec = spec

            isFetching = true
            do {
                let slice = try await table.rows(offset: offset, limit: limit, spec: currentSpec)
                // A filter or sort may have changed while this was in flight.
                guard currentGeneration == generation else {
                    inFlightPages.remove(page)
                    continue
                }
                pages[page] = slice.rows.enumerated().map { position, cells in
                    RowEntry(
                        index: offset + position,
                        cells: cells,
                        fileRowNumber: position < slice.fileRowNumbers.count
                            ? slice.fileRowNumbers[position] : nil)
                }
                if columnWidths.isEmpty { autosizeColumns(using: slice.rows) }
            } catch {
                if currentGeneration == generation { errorMessage = errorText(error) }
            }
            inFlightPages.remove(page)
        }
        isFetching = !inFlightPages.isEmpty
    }

    private func evictPages(keeping range: ClosedRange<Int>) {
        let keepLower = range.lowerBound - cacheRadius
        let keepUpper = range.upperBound + cacheRadius
        pages = pages.filter { $0.key >= keepLower && $0.key <= keepUpper }
    }

    // MARK: - Selection

    func select(rowIndex: Int?) {
        selectedRowIndex = rowIndex
        selectedRowValues = nil
        selectionTask?.cancel()
        guard let rowIndex, let table else { return }
        let currentSpec = spec
        let currentGeneration = generation
        selectionTask = Task { [weak self] in
            // The grid holds clipped text; the inspector wants the real thing.
            let values = try? await table.fullRow(at: rowIndex, spec: currentSpec)
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                guard self.generation == currentGeneration,
                    self.selectedRowIndex == rowIndex
                else { return }
                self.selectedRowValues = values
            }
        }
    }

    func moveSelection(by delta: Int) {
        guard visibleRowCount > 0 else { return }
        let current = selectedRowIndex ?? (visibleRange.lowerBound - 1)
        let next = min(max(0, current + delta), visibleRowCount - 1)
        select(rowIndex: next)
        // Only scroll when the selection would otherwise walk off screen —
        // scrolling on every keypress makes the grid feel jumpy.
        let margin = 2
        if next <= visibleRange.lowerBound + margin || next >= visibleRange.upperBound - margin {
            revealRow(next)
        }
    }

    /// Asks the grid to bring a row into view.
    func revealRow(_ index: Int) {
        scrollRequest = min(max(0, index), max(0, visibleRowCount - 1))
    }

    func jump(toRow index: Int) {
        let target = min(max(0, index), max(0, visibleRowCount - 1))
        select(rowIndex: target)
        revealRow(target)
    }

    // MARK: - Columns

    var visibleColumns: [ColumnInfo] {
        schema.filter { !hiddenColumns.contains($0.name) }
    }

    func width(for column: ColumnInfo) -> CGFloat {
        columnWidths[column.name] ?? defaultWidth(for: column)
    }

    func setWidth(_ width: CGFloat, for column: ColumnInfo) {
        columnWidths[column.name] = max(Theme.minColumnWidth, width)
    }

    func toggleVisibility(of column: ColumnInfo) {
        if hiddenColumns.contains(column.name) {
            hiddenColumns.remove(column.name)
        } else {
            hiddenColumns.insert(column.name)
        }
    }

    func showAllColumns() {
        hiddenColumns.removeAll()
    }

    private func defaultWidth(for column: ColumnInfo) -> CGFloat {
        switch column.kind {
        case .boolean: return 74
        case .integer, .decimal: return 110
        case .temporal: return 170
        case .binary: return 110
        case .nested: return 220
        default: return 200
        }
    }

    /// Picks initial widths from the first page so the common case — open a
    /// file, see the data — needs no manual column dragging.
    private func autosizeColumns(using rows: [[CellValue]]) {
        guard !rows.isEmpty else { return }
        var widths: [String: CGFloat] = [:]
        for (index, column) in schema.enumerated() {
            var longest = column.name.count + 4
            for row in rows.prefix(60) where index < row.count {
                longest = max(longest, min(row[index].stringValue.count, 90))
            }
            let estimated = CGFloat(longest) * 7.1 + Theme.cellPadding * 2 + 8
            widths[column.name] = min(
                max(estimated, Theme.minColumnWidth), Theme.maxAutoColumnWidth)
        }
        columnWidths = widths
    }

    // MARK: - SQL

    /// Carries a DuckDB message back to the console for display.
    struct QueryFailure: Error {
        let message: String
    }

    func runQuery(_ sql: String) async -> Result<QueryResult, QueryFailure> {
        guard let table else { return .failure(QueryFailure(message: "No file open.")) }
        do {
            return .success(try await table.runQuery(sql))
        } catch {
            return .failure(QueryFailure(message: errorText(error)))
        }
    }

    func columnProfile(for name: String) async -> ColumnProfile? {
        guard let table else { return nil }
        return try? await table.columnProfile(for: name)
    }

    func topValues(for name: String) async -> [(String, Int)] {
        guard let table else { return [] }
        return (try? await table.topValues(for: name)) ?? []
    }

    // MARK: - Export

    func export(format: ParquetTable.ExportFormat) async {
        guard let table else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue =
            url.deletingPathExtension().lastPathComponent + "-export." + format.fileExtension
        panel.message = spec.isFiltered
            ? "Exports the \(Format.count(visibleRowCount)) filtered rows."
            : "Exports all \(Format.count(visibleRowCount)) rows."
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try await table.export(to: destination, format: format, spec: spec)
            Finder.reveal(destination)
        } catch {
            errorMessage = errorText(error)
        }
    }

    enum RowClipboardFormat {
        case tabSeparated
        case json
    }

    /// Copies a row, fetching its untruncated values first so the clipboard
    /// gets the real data rather than the grid's clipped preview.
    func copyRow(at index: Int, as format: RowClipboardFormat) async {
        guard let table else { return }
        let values: [CellValue]?
        if index == selectedRowIndex, let cached = selectedRowValues {
            values = cached
        } else {
            values = try? await table.fullRow(at: index, spec: spec)
        }
        guard let values else { return }

        switch format {
        case .tabSeparated:
            let header = schema.map(\.name).joined(separator: "\t")
            let line = values.map { $0.isNull ? "" : $0.stringValue }.joined(separator: "\t")
            Finder.copyText(header + "\n" + line)
        case .json:
            var object: [String: Any] = [:]
            for (column, value) in zip(schema, values) {
                object[column.name] = value.isNull ? NSNull() : value.stringValue
            }
            guard
                let data = try? JSONSerialization.data(
                    withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
                let text = String(data: data, encoding: .utf8)
            else { return }
            Finder.copyText(text)
        }
    }

    func copySelectedRow(as format: RowClipboardFormat) async {
        guard let index = selectedRowIndex else { return }
        await copyRow(at: index, as: format)
    }

    // MARK: - Helpers

    private func errorText(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    var subtitle: String {
        switch state {
        case .ready:
            var parts = ["\(Format.count(visibleRowCount)) rows"]
            if spec.isFiltered { parts[0] += " of \(Format.count(totalRowCount))" }
            parts.append("\(schema.count) columns")
            if let size = profile?.file.fileSize, size > 0 {
                parts.append(Format.bytes(size))
            }
            return parts.joined(separator: " · ")
        case .opening: return "Opening…"
        case .failed: return "Couldn't open"
        case .idle: return ""
        }
    }
}
