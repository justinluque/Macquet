import Foundation

/// Small helpers for building SQL by hand without opening injection holes.
///
/// Everything the app sends to DuckDB is assembled here: column names come from
/// the file's own schema and file paths come from the open panel, but both are
/// still escaped, because a Parquet file is free to name a column
/// `"); DROP …` and a filename is free to contain a quote.
public enum SQL {

    /// Quotes an identifier: `foo"bar` -> `"foo""bar"`.
    public static func identifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Quotes a string literal: `it's` -> `'it''s'`.
    public static func literal(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// Escapes the `%` and `_` wildcards so a user's search text is matched
    /// literally, then wraps it for a contains-style `ILIKE`.
    public static func containsPattern(_ raw: String) -> String {
        var escaped = raw.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "%", with: "\\%")
        escaped = escaped.replacingOccurrences(of: "_", with: "\\_")
        return "%" + escaped + "%"
    }

    /// The expression used to render one column as display text.
    ///
    /// - BLOBs are summarised rather than cast, so a column of raw bytes cannot
    ///   flood the grid with escape sequences.
    /// - Long strings are clipped for the grid; the inspector re-fetches the
    ///   full value for a single row when the user selects it.
    public static func displayExpression(
        for column: ColumnInfo, truncateAt limit: Int?
    ) -> String {
        let quoted = identifier(column.name)
        if column.kind == .binary {
            return "CASE WHEN \(quoted) IS NULL THEN NULL ELSE "
                + "'<' || octet_length(\(quoted)) || ' bytes>' END"
        }
        let cast = "CAST(\(quoted) AS VARCHAR)"
        guard let limit else { return cast }
        return "CASE WHEN length(\(cast)) > \(limit) "
            + "THEN substr(\(cast), 1, \(limit)) || '…' ELSE \(cast) END"
    }

    /// Builds the `WHERE` body for a ``QuerySpec``, or nil when unfiltered.
    public static func whereClause(for spec: QuerySpec, schema: [ColumnInfo]) -> String? {
        var predicates: [String] = []

        let search = spec.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            let pattern = literal(containsPattern(search))
            let targets: [ColumnInfo]
            if let only = spec.searchColumn {
                targets = schema.filter { $0.name == only }
            } else {
                targets = schema.filter { $0.kind.isSearchable }
            }
            let terms = targets.map {
                "CAST(\(identifier($0.name)) AS VARCHAR) ILIKE \(pattern) ESCAPE '\\'"
            }
            if !terms.isEmpty {
                predicates.append("(" + terms.joined(separator: " OR ") + ")")
            }
        }

        let manual = spec.whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty {
            predicates.append("(" + manual + ")")
        }

        guard !predicates.isEmpty else { return nil }
        return predicates.joined(separator: " AND ")
    }

    /// `ORDER BY` body, with the physical row number appended as a tie-breaker
    /// so that paging through a sorted view never shuffles equal rows between
    /// one page fetch and the next.
    public static func orderClause(for spec: QuerySpec, rowNumberColumn: String?) -> String? {
        guard let sort = spec.sort else { return nil }
        var clause = "\(identifier(sort.columnName)) \(sort.direction.sqlKeyword)"
        // NULLs last on ascending reads better than DuckDB's default.
        clause += sort.direction == .ascending ? " NULLS LAST" : " NULLS FIRST"
        if let rowNumberColumn {
            clause += ", \(identifier(rowNumberColumn)) ASC"
        }
        return clause
    }
}
