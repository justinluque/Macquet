import Foundation

// MARK: - Cell values

/// A single rendered cell. Everything arrives from DuckDB pre-cast to VARCHAR,
/// so the viewer has exactly one representation to reason about, while
/// ``ColumnInfo/kind`` carries the original logical type for alignment,
/// colouring and sort behaviour.
public enum CellValue: Sendable, Hashable {
    case null
    case text(String)

    public var stringValue: String {
        switch self {
        case .null: return ""
        case .text(let s): return s
        }
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

// MARK: - Column kinds

/// Coarse bucket derived from the DuckDB/Parquet logical type. Drives right vs
/// left alignment, the accent colour of the type badge, and whether a column
/// is worth including in a full-text filter.
public enum ColumnKind: String, Sendable, Hashable, CaseIterable {
    case integer
    case decimal
    case boolean
    case text
    case temporal
    case binary
    case nested
    case other

    public var isNumeric: Bool { self == .integer || self == .decimal }

    /// Whether a plain `ILIKE` filter over this column is meaningful.
    public var isSearchable: Bool {
        switch self {
        case .binary: return false
        default: return true
        }
    }

    public var symbolName: String {
        switch self {
        case .integer: return "number"
        case .decimal: return "percent"
        case .boolean: return "switch.2"
        case .text: return "textformat"
        case .temporal: return "calendar"
        case .binary: return "cube"
        case .nested: return "list.bullet.indent"
        case .other: return "questionmark"
        }
    }

    /// Short badge shown next to a column name in the schema sidebar.
    public var shortLabel: String {
        switch self {
        case .integer: return "INT"
        case .decimal: return "NUM"
        case .boolean: return "BOOL"
        case .text: return "TEXT"
        case .temporal: return "TIME"
        case .binary: return "BLOB"
        case .nested: return "NEST"
        case .other: return "?"
        }
    }

    static func infer(from duckDBType: String) -> ColumnKind {
        let t = duckDBType.uppercased()
        // Nested types are matched first: a STRUCT can contain the word INT.
        if t.hasPrefix("STRUCT") || t.hasPrefix("MAP") || t.hasPrefix("UNION") || t.hasSuffix("[]")
            || t.contains("LIST") {
            return .nested
        }
        if t.hasPrefix("DECIMAL") || t == "DOUBLE" || t == "FLOAT" || t == "REAL" { return .decimal }
        if t.hasPrefix("TIMESTAMP") || t == "DATE" || t == "TIME" || t == "INTERVAL"
            || t.hasPrefix("TIMESTAMPTZ") {
            return .temporal
        }
        if t == "BOOLEAN" { return .boolean }
        if t == "BLOB" || t == "BIT" { return .binary }
        if t == "VARCHAR" || t == "UUID" || t == "JSON" || t == "ENUM" || t.hasPrefix("ENUM") {
            return .text
        }
        if t.contains("INT") || t == "HUGEINT" || t == "UHUGEINT" { return .integer }
        return .other
    }
}

// MARK: - Schema

public struct ColumnInfo: Sendable, Hashable, Identifiable {
    public let index: Int
    public let name: String
    /// The DuckDB rendering of the type, e.g. `VARCHAR`, `STRUCT(a INTEGER)`.
    public let typeName: String
    public let kind: ColumnKind
    public let isNullable: Bool

    public var id: Int { index }

    public init(index: Int, name: String, typeName: String, isNullable: Bool) {
        self.index = index
        self.name = name
        self.typeName = typeName
        self.kind = ColumnKind.infer(from: typeName)
        self.isNullable = isNullable
    }
}

// MARK: - Sorting & filtering

public struct ColumnSort: Sendable, Hashable {
    public enum Direction: Sendable, Hashable {
        case ascending, descending
        public var toggled: Direction { self == .ascending ? .descending : .ascending }
        public var sqlKeyword: String { self == .ascending ? "ASC" : "DESC" }
        public var symbolName: String { self == .ascending ? "chevron.up" : "chevron.down" }
    }

    public var columnName: String
    public var direction: Direction

    public init(columnName: String, direction: Direction = .ascending) {
        self.columnName = columnName
        self.direction = direction
    }
}

/// The user-facing query state of a window: a free-text filter, an optional
/// hand-written `WHERE` clause, and an optional sort.
public struct QuerySpec: Sendable, Hashable {
    public var searchText: String = ""
    /// Restricts the free-text search to a single column when set.
    public var searchColumn: String? = nil
    public var whereClause: String = ""
    public var sort: ColumnSort? = nil

    public init() {}

    public var isFiltered: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
            || !whereClause.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// MARK: - Row data

public struct RowSlice: Sendable {
    /// Index of the first row, relative to the current filtered/sorted result.
    public let startRow: Int
    /// Row-major cells. Each inner array matches ``ParquetTable/schema`` order.
    public let rows: [[CellValue]]
    /// The physical row number in the file for each row, when available.
    public let fileRowNumbers: [Int?]

    public init(startRow: Int, rows: [[CellValue]], fileRowNumbers: [Int?]) {
        self.startRow = startRow
        self.rows = rows
        self.fileRowNumbers = fileRowNumbers
    }

    public var endRow: Int { startRow + rows.count }
    public var isEmpty: Bool { rows.isEmpty }
}

/// Result of an ad-hoc SQL query typed into the console.
public struct QueryResult: Sendable {
    public let columns: [ColumnInfo]
    public let rows: [[CellValue]]
    public let elapsed: TimeInterval
    /// True when the result was clipped by the console's row cap.
    public let truncated: Bool

    public init(columns: [ColumnInfo], rows: [[CellValue]], elapsed: TimeInterval, truncated: Bool) {
        self.columns = columns
        self.rows = rows
        self.elapsed = elapsed
        self.truncated = truncated
    }
}

// MARK: - Parquet file metadata

public struct FileMetadata: Sendable, Hashable {
    public var fileName: String = ""
    public var createdBy: String = ""
    public var numRows: Int = 0
    public var numRowGroups: Int = 0
    public var formatVersion: String = ""
    public var encryptionAlgorithm: String = ""
    /// Total bytes on disk.
    public var fileSize: Int = 0
    /// Summed from the per-column chunk metadata.
    public var compressedSize: Int = 0
    public var uncompressedSize: Int = 0

    public var compressionRatio: Double? {
        guard compressedSize > 0, uncompressedSize > 0 else { return nil }
        return Double(uncompressedSize) / Double(compressedSize)
    }

    public init() {}
}

/// Per-column physical storage facts, aggregated across row groups.
public struct ColumnStorageInfo: Sendable, Hashable, Identifiable {
    public let path: String
    public let physicalType: String
    public let compression: String
    public let encodings: String
    public let compressedSize: Int
    public let uncompressedSize: Int
    public let nullCount: Int?
    public let statsMin: String?
    public let statsMax: String?

    public var id: String { path }

    public var compressionRatio: Double? {
        guard compressedSize > 0, uncompressedSize > 0 else { return nil }
        return Double(uncompressedSize) / Double(compressedSize)
    }

    public init(
        path: String, physicalType: String, compression: String, encodings: String,
        compressedSize: Int, uncompressedSize: Int, nullCount: Int?,
        statsMin: String?, statsMax: String?
    ) {
        self.path = path
        self.physicalType = physicalType
        self.compression = compression
        self.encodings = encodings
        self.compressedSize = compressedSize
        self.uncompressedSize = uncompressedSize
        self.nullCount = nullCount
        self.statsMin = statsMin
        self.statsMax = statsMax
    }
}

public struct RowGroupInfo: Sendable, Hashable, Identifiable {
    public let id: Int
    public let numRows: Int
    public let compressedSize: Int
    public let uncompressedSize: Int

    public init(id: Int, numRows: Int, compressedSize: Int, uncompressedSize: Int) {
        self.id = id
        self.numRows = numRows
        self.compressedSize = compressedSize
        self.uncompressedSize = uncompressedSize
    }
}

/// A key/value pair from the Parquet footer. Hugging Face datasets stash their
/// dataset card JSON here under the `huggingface` key, which is worth surfacing.
public struct KeyValueMetadata: Sendable, Hashable, Identifiable {
    public let key: String
    public let value: String
    public var id: String { key }

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    /// Pretty-printed when the value parses as JSON, otherwise returned as-is.
    public var prettyValue: String {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: pretty, encoding: .utf8)
        else { return value }
        return string
    }
}

/// Everything the inspector shows about the file itself.
public struct ParquetProfile: Sendable {
    public var file: FileMetadata = .init()
    public var rowGroups: [RowGroupInfo] = []
    public var columnStorage: [ColumnStorageInfo] = []
    public var keyValueMetadata: [KeyValueMetadata] = []

    public init() {}
}

/// Per-column summary statistics computed on demand via `SUMMARIZE`.
public struct ColumnProfile: Sendable, Hashable {
    public var columnName: String
    public var distinctCount: Int?
    public var nullPercentage: Double?
    public var min: String?
    public var max: String?
    public var average: String?
    public var standardDeviation: String?
    public var median: String?

    public init(columnName: String) {
        self.columnName = columnName
    }
}
