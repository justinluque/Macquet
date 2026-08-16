import MacquetCore
import SwiftUI

/// Shared metrics, colours and formatters.
enum Theme {
    /// Fixed row height keeps the virtualised grid's maths trivial: any row's
    /// offset is `index * rowHeight`, which is what makes jump-to-row and
    /// scroll-position restoration exact rather than approximate.
    static let rowHeight: CGFloat = 24
    static let headerHeight: CGFloat = 28
    static let cellPadding: CGFloat = 8
    static let gutterWidth: CGFloat = 62
    static let minColumnWidth: CGFloat = 48
    static let maxAutoColumnWidth: CGFloat = 420

    static let gridLine = Color.primary.opacity(0.08)
    static let headerBackground = Color(nsColor: .controlBackgroundColor)
    static let stripe = Color.primary.opacity(0.028)
    static let nullText = Color.secondary.opacity(0.55)

    static func accent(for kind: ColumnKind) -> Color {
        switch kind {
        case .integer: return .blue
        case .decimal: return .teal
        case .boolean: return .purple
        case .text: return .green
        case .temporal: return .orange
        case .binary: return .brown
        case .nested: return .pink
        case .other: return .gray
        }
    }

    static let cellFont = Font.system(size: 12)
    static let monoCellFont = Font.system(size: 12, design: .monospaced)

    static func font(for kind: ColumnKind) -> Font {
        switch kind {
        case .integer, .decimal, .temporal, .binary: return monoCellFont
        default: return cellFont
        }
    }
}

// MARK: - Formatting

enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func bytes(_ value: Int) -> String {
        byteFormatter.string(fromByteCount: Int64(value))
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// Compact row counts for tight spots: 25,000 -> "25K".
    static func compactCount(_ value: Int) -> String {
        value < 10_000 ? count(value) : value.formatted(.number.notation(.compactName))
    }

    static func ratio(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f×", value)
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f%%", value)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 0.001 { return "<1 ms" }
        if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
        return String(format: "%.2f s", seconds)
    }

    /// One-line preview of a cell for the grid: control characters collapse so
    /// a multi-line prompt can't blow out the fixed row height.
    static func inline(_ text: String) -> String {
        guard text.contains(where: \.isNewline) || text.contains("\t") else { return text }
        return
            text
            .replacingOccurrences(of: "\r\n", with: " ⏎ ")
            .replacingOccurrences(of: "\n", with: " ⏎ ")
            .replacingOccurrences(of: "\r", with: " ⏎ ")
            .replacingOccurrences(of: "\t", with: "  ")
    }
}
