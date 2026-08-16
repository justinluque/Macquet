import DuckDB
import Foundation

/// Reads a Parquet file (or a directory of shards) through an in-memory DuckDB
/// instance.
///
/// The actor owns the connection, so every query is serialised off the main
/// thread. Results cross the isolation boundary only as plain value types —
/// DuckDB's own `ResultSet`/`Column` never escape.
public actor ParquetTable {

    public enum TableError: LocalizedError {
        case unreadable(URL)
        case emptySchema
        case query(String, underlying: String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let url):
                return "Couldn't read \(url.lastPathComponent) as Parquet."
            case .emptySchema:
                return "That file has no columns."
            case .query(let sql, let underlying):
                let head = sql.prefix(160)
                return "Query failed: \(underlying)\n\n\(head)"
            }
        }
    }

    /// Name of the synthetic ordinal column DuckDB adds via `file_row_number`.
    private static let rowNumberColumnName = "file_row_number"
    /// Name of the synthetic column carrying the source shard's path.
    private static let fileNameColumnName = "filename"
    /// The temp view every query reads from.
    private static let viewName = "macquet_src"
    /// Cell text longer than this is clipped in the grid; the inspector
    /// re-fetches the untruncated value for the selected row.
    public static let gridCellCharacterLimit = 600

    public let url: URL
    /// True when `url` is a directory and the table spans several shards.
    public private(set) var isMultiFile: Bool = false

    private let database: Database
    private let connection: Connection

    public private(set) var schema: [ColumnInfo] = []
    /// Row count of the whole file, ignoring any filter.
    public private(set) var totalRowCount: Int = 0
    /// Set when DuckDB accepted `file_row_number`; nil when it had to be
    /// dropped (e.g. the file already has a column by that name).
    private var rowNumberColumn: String?
    private var fileNameColumn: String?
    private var filteredCountCache: [String: Int] = [:]

    // MARK: - Lifecycle

    /// Opens a file.
    ///
    /// Opening reads the footer and counts rows, which is fast but not free on
    /// a multi-gigabyte file. The initializer is `async` so that work happens
    /// on the actor's own executor rather than on whatever thread — usually the
    /// main one — asked for the file.
    public static func open(url: URL) async throws -> ParquetTable {
        try await ParquetTable(url: url)
    }

    public init(url: URL) async throws {
        self.url = url
        do {
            self.database = try Database(store: .inMemory)
            self.connection = try database.connect()
        } catch {
            throw TableError.unreadable(url)
        }
        try configure()
        try loadSchema()
    }

    private func configure() throws {
        // A viewer should stay responsive rather than grab the whole machine.
        let cores = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
        try? connection.execute("SET threads TO \(cores)")
        try? connection.execute("SET enable_progress_bar TO false")
    }

    /// Rebuilds the source view and re-reads the schema and row count. Called
    /// on open and whenever the file changes underneath us.
    public func reload() throws {
        filteredCountCache.removeAll()
        try loadSchema()
    }

    // MARK: - Source expression

    /// The `read_parquet(...)` call for this URL.
    ///
    /// A directory becomes a recursive glob so a sharded dataset
    /// (`train-00000-of-00042.parquet`, …) opens as one table, with
    /// `union_by_name` so shards with drifting schemas still line up.
    private func sourceExpression(fileRowNumber: Bool) -> String {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path, isDirectory: &isDirectory)
        let target: String
        if exists && isDirectory.boolValue {
            target = url.appendingPathComponent("**/*.parquet").path
        } else {
            target = url.path
        }
        var options = ["union_by_name := true"]
        if isDirectory.boolValue {
            options.append("filename := true")
        }
        if fileRowNumber {
            options.append("file_row_number := true")
        }
        return "read_parquet(\(SQL.literal(target)), \(options.joined(separator: ", ")))"
    }

    private func loadSchema() throws {
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        isMultiFile = isDirectory.boolValue

        // Prefer the variant carrying a physical row number: it gives the grid
        // a stable ordinal and makes sorted paging deterministic. If the file
        // already defines a clashing column name, fall back to the plain read.
        var describeRows: [[String?]]
        do {
            try connection.execute(
                "CREATE OR REPLACE TEMP VIEW \(Self.viewName) AS "
                    + "SELECT * FROM \(sourceExpression(fileRowNumber: true))")
            describeRows = try stringRows("DESCRIBE \(Self.viewName)")
            let names = describeRows.compactMap { $0.first ?? nil }
            if names.filter({ $0 == Self.rowNumberColumnName }).count == 1 {
                rowNumberColumn = Self.rowNumberColumnName
            } else {
                throw TableError.emptySchema  // force the fallback below
            }
        } catch {
            rowNumberColumn = nil
            do {
                try connection.execute(
                    "CREATE OR REPLACE TEMP VIEW \(Self.viewName) AS "
                        + "SELECT * FROM \(sourceExpression(fileRowNumber: false))")
                describeRows = try stringRows("DESCRIBE \(Self.viewName)")
            } catch {
                throw TableError.unreadable(url)
            }
        }
        fileNameColumn = isMultiFile ? Self.fileNameColumnName : nil

        var columns: [ColumnInfo] = []
        for row in describeRows {
            guard let name = row.first ?? nil, row.count >= 2, let type = row[1] else { continue }
            // Synthetic columns are machinery, not data the file actually holds.
            if name == rowNumberColumn { continue }
            let nullable = (row.count > 2 ? row[2] : nil)?.uppercased() != "NO"
            columns.append(
                ColumnInfo(
                    index: columns.count, name: name, typeName: type, isNullable: nullable))
        }
        guard !columns.isEmpty else { throw TableError.emptySchema }
        schema = columns

        totalRowCount = try scalarInt("SELECT count(*) FROM \(Self.viewName)") ?? 0
    }

    // MARK: - Low-level query helpers

    /// Runs a query and returns every cell as an optional String.
    ///
    /// `COLUMNS(*)::VARCHAR` casts every projected column in one shot, which
    /// means the whole app needs exactly one result decoder no matter what
    /// types the file contains — including nested STRUCT/LIST columns, which
    /// render as readable JSON-ish text.
    private func stringRows(_ sql: String, castAll: Bool = true) throws -> [[String?]] {
        let wrapped = castAll ? "SELECT COLUMNS(*)::VARCHAR FROM (\(sql)) AS macquet_sub" : sql
        let result: ResultSet
        do {
            result = try connection.query(wrapped)
        } catch {
            throw TableError.query(wrapped, underlying: describe(error))
        }
        return decode(result)
    }

    private func decode(_ result: ResultSet) -> [[String?]] {
        let rowCount = Int(result.rowCount)
        let columnCount = Int(result.columnCount)
        guard rowCount > 0, columnCount > 0 else { return [] }

        // Read column-wise (DuckDB's native layout), then transpose.
        var byColumn: [[String?]] = []
        byColumn.reserveCapacity(columnCount)
        for index in 0..<columnCount {
            let column = result[DBInt(index)].cast(to: String.self)
            var values: [String?] = []
            values.reserveCapacity(rowCount)
            for value in column { values.append(value) }
            // Guard against a short column so the transpose below stays safe.
            while values.count < rowCount { values.append(nil) }
            byColumn.append(values)
        }

        var rows: [[String?]] = []
        rows.reserveCapacity(rowCount)
        for rowIndex in 0..<rowCount {
            var row: [String?] = []
            row.reserveCapacity(columnCount)
            for columnIndex in 0..<columnCount {
                row.append(byColumn[columnIndex][rowIndex])
            }
            rows.append(row)
        }
        return rows
    }

    private func scalarInt(_ sql: String) throws -> Int? {
        guard let text = try stringRows(sql).first?.first ?? nil else { return nil }
        return Int(text)
    }

    /// Digs the actual DuckDB message out of the error.
    ///
    /// `DatabaseError` is a plain enum, so its synthesised `localizedDescription`
    /// is the useless "operation couldn't be completed" string — the real
    /// parser message only lives in the associated `reason`.
    private func describe(_ error: Error) -> String {
        guard let dbError = error as? DatabaseError else { return error.localizedDescription }
        let reason: String?
        switch dbError {
        case .connectionQueryError(let value),
            .preparedStatementQueryError(let value),
            .preparedStatementFailedToInitialize(let value),
            .preparedStatementFailedToBindParameter(let value),
            .databaseFailedToInitialize(let value),
            .appenderFailedToAppendItem(let value),
            .appenderFailedToEndRow(let value),
            .appenderFailedToFlush(let value),
            .appenderFailedToInitialize(let value):
            reason = value
        case .typeMismatch(let type):
            reason = "type mismatch: \(type)"
        case .valueNotFound(let type):
            reason = "value not found: \(type)"
        case .decimalUnrepresentable:
            reason = "decimal value is out of range"
        case .connectionFailedToInitialize:
            reason = "couldn't open a database connection"
        case .configurationFailedToSetFlag:
            reason = "couldn't apply a database setting"
        }
        guard let reason, !reason.isEmpty else { return "\(dbError)" }
        // DuckDB prefixes its messages ("Parser Error: …"); keep them, they're
        // the most useful part for someone debugging a query.
        return reason.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func columnNames(of result: ResultSet) -> [String] {
        (0..<Int(result.columnCount)).map { result.columnName(at: DBInt($0)) }
    }

    // MARK: - Row access

    /// Number of rows matching the spec's filter, cached per distinct clause.
    public func rowCount(matching spec: QuerySpec) throws -> Int {
        guard let clause = SQL.whereClause(for: spec, schema: schema) else {
            return totalRowCount
        }
        if let cached = filteredCountCache[clause] { return cached }
        let count = try scalarInt(
            "SELECT count(*) FROM \(Self.viewName) WHERE \(clause)") ?? 0
        filteredCountCache[clause] = count
        return count
    }

    /// Fetches a page of display-ready rows.
    public func rows(offset: Int, limit: Int, spec: QuerySpec) throws -> RowSlice {
        guard limit > 0, offset >= 0 else {
            return RowSlice(startRow: max(0, offset), rows: [], fileRowNumbers: [])
        }

        var projections = schema.map {
            SQL.displayExpression(for: $0, truncateAt: Self.gridCellCharacterLimit)
        }
        if let rowNumberColumn {
            projections.append("CAST(\(SQL.identifier(rowNumberColumn)) AS VARCHAR)")
        }

        var sql = "SELECT \(projections.joined(separator: ", ")) FROM \(Self.viewName)"
        if let clause = SQL.whereClause(for: spec, schema: schema) {
            sql += " WHERE \(clause)"
        }
        if let order = SQL.orderClause(for: spec, rowNumberColumn: rowNumberColumn) {
            sql += " ORDER BY \(order)"
        }
        sql += " LIMIT \(limit) OFFSET \(offset)"

        // Projections already produce VARCHAR, so the extra cast wrapper is
        // just overhead here.
        let raw = try stringRows(sql, castAll: false)

        var rows: [[CellValue]] = []
        var ordinals: [Int?] = []
        rows.reserveCapacity(raw.count)
        ordinals.reserveCapacity(raw.count)
        let columnCount = schema.count
        for row in raw {
            var cells: [CellValue] = []
            cells.reserveCapacity(columnCount)
            for index in 0..<columnCount {
                let value = index < row.count ? row[index] : nil
                cells.append(value.map(CellValue.text) ?? .null)
            }
            rows.append(cells)
            if rowNumberColumn != nil, row.count > columnCount,
                let text = row[columnCount] {
                ordinals.append(Int(text))
            } else {
                ordinals.append(nil)
            }
        }
        return RowSlice(startRow: offset, rows: rows, fileRowNumbers: ordinals)
    }

    /// Full, untruncated values for a single row — what the inspector shows.
    ///
    /// Re-runs the page query with `LIMIT 1 OFFSET n` so the row identified by
    /// a grid index is the same row under any sort or filter.
    public func fullRow(at index: Int, spec: QuerySpec) throws -> [CellValue]? {
        guard index >= 0 else { return nil }
        let projections = schema.map { SQL.displayExpression(for: $0, truncateAt: nil) }
        var sql = "SELECT \(projections.joined(separator: ", ")) FROM \(Self.viewName)"
        if let clause = SQL.whereClause(for: spec, schema: schema) {
            sql += " WHERE \(clause)"
        }
        if let order = SQL.orderClause(for: spec, rowNumberColumn: rowNumberColumn) {
            sql += " ORDER BY \(order)"
        }
        sql += " LIMIT 1 OFFSET \(index)"

        guard let row = try stringRows(sql, castAll: false).first else { return nil }
        return (0..<schema.count).map { position in
            let value = position < row.count ? row[position] : nil
            return value.map(CellValue.text) ?? .null
        }
    }

    // MARK: - Ad-hoc SQL

    /// Runs user-typed SQL against the file.
    ///
    /// The open file is available as `macquet_src`, and `tbl` is accepted as a
    /// friendlier alias. Statements that return no result set (`SET`, `PRAGMA`)
    /// report as an empty result rather than an error.
    public func runQuery(_ rawSQL: String, rowLimit: Int = 2000) throws -> QueryResult {
        let trimmed = rawSQL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        guard !trimmed.isEmpty else {
            return QueryResult(columns: [], rows: [], elapsed: 0, truncated: false)
        }

        let start = Date()
        // `tbl` is the convenience alias people reach for. It projects the real
        // columns only, so `SELECT *` never surfaces the synthetic row-number
        // column the grid uses internally. Re-created each run so it survives a
        // reload of the source view.
        let projection = schema.map { SQL.identifier($0.name) }.joined(separator: ", ")
        try? connection.execute(
            "CREATE OR REPLACE TEMP VIEW tbl AS SELECT \(projection) FROM \(Self.viewName)")

        let isSelectLike = ["SELECT", "WITH", "DESCRIBE", "SUMMARIZE", "SHOW", "PRAGMA", "FROM",
                            "TABLE", "VALUES"]
            .contains { trimmed.uppercased().hasPrefix($0) }

        guard isSelectLike else {
            do {
                try connection.execute(trimmed)
            } catch {
                throw TableError.query(trimmed, underlying: describe(error))
            }
            return QueryResult(
                columns: [], rows: [], elapsed: Date().timeIntervalSince(start), truncated: false)
        }

        // Names and types come from DESCRIBE; values come from a VARCHAR-cast
        // read of the same statement, so the console handles any result shape.
        var columns: [ColumnInfo] = []
        if let described = try? stringRows("DESCRIBE (\(trimmed))", castAll: false) {
            for row in described {
                guard let name = row.first ?? nil, row.count >= 2, let type = row[1] else {
                    continue
                }
                let nullable = (row.count > 2 ? row[2] : nil)?.uppercased() != "NO"
                columns.append(
                    ColumnInfo(
                        index: columns.count, name: name, typeName: type, isNullable: nullable))
            }
        }

        let capped = "SELECT * FROM (\(trimmed)) AS macquet_q LIMIT \(rowLimit + 1)"
        let result: ResultSet
        do {
            result = try connection.query(
                "SELECT COLUMNS(*)::VARCHAR FROM (\(capped)) AS macquet_cast")
        } catch {
            throw TableError.query(trimmed, underlying: describe(error))
        }

        if columns.isEmpty {
            columns = columnNames(of: result).enumerated().map {
                ColumnInfo(index: $0.offset, name: $0.element, typeName: "VARCHAR", isNullable: true)
            }
        }

        var raw = decode(result)
        let truncated = raw.count > rowLimit
        if truncated { raw.removeLast(raw.count - rowLimit) }

        let rows = raw.map { row in
            (0..<columns.count).map { position -> CellValue in
                let value = position < row.count ? row[position] : nil
                return value.map(CellValue.text) ?? .null
            }
        }
        return QueryResult(
            columns: columns, rows: rows,
            elapsed: Date().timeIntervalSince(start), truncated: truncated)
    }

    // MARK: - File profile

    /// Reads the Parquet footer: file-level facts, row groups, per-column
    /// storage, and the key/value metadata block.
    public func profile() throws -> ParquetProfile {
        var profile = ParquetProfile()
        let source = SQL.literal(resolvedGlobPath())

        profile.file.fileSize = totalFileSize()
        profile.file.numRows = totalRowCount

        if let row = try? stringRows(
            "SELECT file_name, created_by, num_rows, num_row_groups, format_version, "
                + "encryption_algorithm FROM parquet_file_metadata(\(source))"
        ).first {
            func value(_ index: Int) -> String { (index < row.count ? row[index] : nil) ?? "" }
            profile.file.fileName = value(0)
            profile.file.createdBy = value(1)
            profile.file.numRowGroups = Int(value(3)) ?? 0
            profile.file.formatVersion = value(4)
            profile.file.encryptionAlgorithm = value(5)
        }

        // Row groups, aggregated from the per-chunk rows.
        if let groups = try? stringRows(
            "SELECT row_group_id, any_value(row_group_num_rows), "
                + "sum(total_compressed_size), sum(total_uncompressed_size) "
                + "FROM parquet_metadata(\(source)) GROUP BY row_group_id ORDER BY row_group_id")
        {
            profile.rowGroups = groups.compactMap { row in
                guard let idText = row.first ?? nil, let id = Int(idText) else { return nil }
                return RowGroupInfo(
                    id: id,
                    numRows: Int(row.count > 1 ? (row[1] ?? "0") : "0") ?? 0,
                    compressedSize: Int(row.count > 2 ? (row[2] ?? "0") : "0") ?? 0,
                    uncompressedSize: Int(row.count > 3 ? (row[3] ?? "0") : "0") ?? 0)
            }
        }
        profile.file.compressedSize = profile.rowGroups.reduce(0) { $0 + $1.compressedSize }
        profile.file.uncompressedSize = profile.rowGroups.reduce(0) { $0 + $1.uncompressedSize }
        if profile.file.numRowGroups == 0 {
            profile.file.numRowGroups = profile.rowGroups.count
        }

        // Per-column storage, aggregated across row groups.
        if let chunks = try? stringRows(
            "SELECT path_in_schema, any_value(type), string_agg(DISTINCT compression, ', '), "
                + "string_agg(DISTINCT encodings, ', '), sum(total_compressed_size), "
                + "sum(total_uncompressed_size), sum(stats_null_count), "
                + "min(stats_min_value), max(stats_max_value) "
                + "FROM parquet_metadata(\(source)) GROUP BY path_in_schema")
        {
            profile.columnStorage = chunks.compactMap { row in
                guard let path = row.first ?? nil else { return nil }
                func value(_ index: Int) -> String? { index < row.count ? row[index] : nil }
                return ColumnStorageInfo(
                    path: path,
                    physicalType: value(1) ?? "",
                    compression: value(2) ?? "",
                    encodings: value(3) ?? "",
                    compressedSize: Int(value(4) ?? "") ?? 0,
                    uncompressedSize: Int(value(5) ?? "") ?? 0,
                    nullCount: Int(value(6) ?? ""),
                    statsMin: value(7),
                    statsMax: value(8))
            }
            // Keep the sidebar in the file's own column order.
            let order = Dictionary(
                uniqueKeysWithValues: schema.enumerated().map { ($0.element.name, $0.offset) })
            profile.columnStorage.sort {
                (order[$0.path] ?? Int.max) < (order[$1.path] ?? Int.max)
            }
        }

        // Footer key/value metadata — where Hugging Face keeps its dataset card.
        if let kv = try? stringRows(
            "SELECT CAST(key AS VARCHAR), CAST(value AS VARCHAR) "
                + "FROM parquet_kv_metadata(\(source))", castAll: false)
        {
            var seen = Set<String>()
            for row in kv {
                guard let key = row.first ?? nil, !seen.contains(key) else { continue }
                seen.insert(key)
                profile.keyValueMetadata.append(
                    KeyValueMetadata(key: key, value: (row.count > 1 ? row[1] : nil) ?? ""))
            }
        }

        return profile
    }

    /// Column summary statistics, computed on demand via `SUMMARIZE`.
    public func columnProfile(for columnName: String) throws -> ColumnProfile {
        var profile = ColumnProfile(columnName: columnName)
        let rows = try stringRows(
            "SELECT column_name, min, max, approx_unique, avg, std, q50, null_percentage "
                + "FROM (SUMMARIZE SELECT \(SQL.identifier(columnName)) FROM \(Self.viewName))",
            castAll: false)
        guard let row = rows.first else { return profile }
        func value(_ index: Int) -> String? {
            guard index < row.count, let text = row[index], !text.isEmpty else { return nil }
            return text
        }
        profile.min = value(1)
        profile.max = value(2)
        profile.distinctCount = Int(value(3) ?? "")
        profile.average = value(4)
        profile.standardDeviation = value(5)
        profile.median = value(6)
        profile.nullPercentage = Double(value(7) ?? "")
        return profile
    }

    /// The most common values in a column, for the sidebar's histogram.
    public func topValues(for columnName: String, limit: Int = 12) throws -> [(String, Int)] {
        let quoted = SQL.identifier(columnName)
        let rows = try stringRows(
            "SELECT CASE WHEN \(quoted) IS NULL THEN '∅ null' ELSE "
                + "substr(CAST(\(quoted) AS VARCHAR), 1, 80) END AS v, count(*) AS n "
                + "FROM \(Self.viewName) GROUP BY 1 ORDER BY n DESC LIMIT \(limit)",
            castAll: false)
        return rows.compactMap { row in
            guard let value = row.first ?? nil, row.count > 1,
                let countText = row[1], let count = Int(countText)
            else { return nil }
            return (value, count)
        }
    }

    // MARK: - Export

    public enum ExportFormat: String, Sendable, CaseIterable {
        case csv = "CSV"
        case json = "JSON"
        case parquet = "Parquet"

        public var fileExtension: String {
            switch self {
            case .csv: return "csv"
            case .json: return "json"
            case .parquet: return "parquet"
            }
        }

        var copyOptions: String {
            switch self {
            case .csv: return "FORMAT CSV, HEADER"
            case .json: return "FORMAT JSON, ARRAY true"
            case .parquet: return "FORMAT PARQUET, COMPRESSION zstd"
            }
        }
    }

    /// Writes the current view — filter and sort included — to `destination`.
    public func export(
        to destination: URL, format: ExportFormat, spec: QuerySpec, rowLimit: Int? = nil
    ) throws {
        var inner = "SELECT \(schema.map { SQL.identifier($0.name) }.joined(separator: ", ")) "
            + "FROM \(Self.viewName)"
        if let clause = SQL.whereClause(for: spec, schema: schema) {
            inner += " WHERE \(clause)"
        }
        if let order = SQL.orderClause(for: spec, rowNumberColumn: rowNumberColumn) {
            inner += " ORDER BY \(order)"
        }
        if let rowLimit { inner += " LIMIT \(rowLimit)" }

        let sql = "COPY (\(inner)) TO \(SQL.literal(destination.path)) (\(format.copyOptions))"
        do {
            try connection.execute(sql)
        } catch {
            throw TableError.query(sql, underlying: describe(error))
        }
    }

    // MARK: - Helpers

    /// The path expression handed to the `parquet_*` metadata functions.
    private func resolvedGlobPath() -> String {
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return isDirectory.boolValue
            ? url.appendingPathComponent("**/*.parquet").path : url.path
    }

    private func totalFileSize() -> Int {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            let attributes = try? manager.attributesOfItem(atPath: url.path)
            return (attributes?[.size] as? NSNumber)?.intValue ?? 0
        }
        guard
            let enumerator = manager.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var total = 0
        for case let child as URL in enumerator {
            guard child.pathExtension.lowercased() == "parquet",
                let values = try? child.resourceValues(forKeys: [.fileSizeKey])
            else { continue }
            total += values.fileSize ?? 0
        }
        return total
    }
}
