import AppKit
import Foundation

/// A Parquet file found on disk, before grouping.
private struct Discovered: Sendable, Hashable {
    let url: URL
    let size: Int
    let modified: Date
}

/// Finds the Parquet files on this Mac so the welcome window isn't an empty
/// drop target.
///
/// Two sources, because neither is sufficient alone:
///
/// * **Spotlight** (`NSMetadataQuery`) is instant and covers the whole disk,
///   but it never indexes dot-directories — and `~/.cache/huggingface`, where
///   every downloaded dataset actually lives, is one.
/// * **A targeted scan** of the handful of places datasets are kept. Bounded
///   in depth and breadth, so it stays cheap.
///
/// Results are merged, de-duplicated, and grouped: a folder of
/// `train-00000-of-00042.parquet` parts collapses into one row that opens as a
/// single table.
@MainActor
final class ParquetLibrary: ObservableObject {

    struct Entry: Identifiable, Hashable {
        /// The file, or the containing folder for a shard group.
        let url: URL
        /// Display name — a readable dataset name where one can be derived.
        let title: String
        /// Where it came from, shown under the title.
        let subtitle: String
        let isShardGroup: Bool
        let fileCount: Int
        let totalSize: Int
        let modified: Date
        /// e.g. "Hugging Face", when the layout identifies a known cache.
        let provenance: String?

        var id: URL { url }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isSearching = false
    @Published private(set) var hasSearched = false

    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private var spotlightHits: Set<Discovered> = []
    private var scanHits: Set<Discovered> = []

    // MARK: Configuration

    /// Directories worth walking. Anything not indexed by Spotlight has to be
    /// found here, which in practice means the model caches.
    private static var scanRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            ".cache/huggingface", ".cache/kagglehub", ".cache/torch",
            "Downloads", "Documents", "Desktop", "Developer", "Datasets", "data",
            "Projects", "src",
        ].map { home.appending(path: $0) }
    }

    /// Directory names never worth descending into.
    private static let prunedDirectories: Set<String> = [
        ".git", ".build", "node_modules", "DerivedData", "Library", ".venv",
        "venv", "site-packages", "__pycache__", ".Trash", "Pods", ".next",
    ]

    private static let parquetExtensions: Set<String> = ["parquet", "parq", "pqt"]
    private static let maxScanDepth = 10
    private static let maxScanResults = 4000

    init() {
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.predicate = NSPredicate(
            format: "kMDItemFSName LIKE[cd] %@ OR kMDItemFSName LIKE[cd] %@ "
                + "OR kMDItemFSName LIKE[cd] %@",
            "*.parquet", "*.parq", "*.pqt")

        let center = NotificationCenter.default
        for name: NSNotification.Name in [
            .NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate,
        ] {
            observers.append(
                center.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.collectSpotlight() }
                })
        }
    }

    deinit {
        let center = NotificationCenter.default
        for observer in observers { center.removeObserver(observer) }
    }

    /// Stops the Spotlight query.
    ///
    /// `NSMetadataQuery` complains loudly if it is deallocated while running,
    /// so the view stops it explicitly on the run loop that started it.
    func stop() {
        if query.isStarted { query.stop() }
    }

    // MARK: Running

    func start() {
        guard !hasSearched, !isSearching else { return }
        refresh()
    }

    func refresh() {
        isSearching = true
        spotlightHits.removeAll()
        scanHits.removeAll()

        if query.isStarted { query.stop() }
        query.start()

        Task { [weak self] in
            let roots = Self.scanRoots
            let found = await Self.scan(roots: roots)
            guard let self else { return }
            self.scanHits = found
            self.rebuild()
            self.isSearching = false
            self.hasSearched = true
        }
    }

    private func collectSpotlight() {
        query.disableUpdates()
        defer { query.enableUpdates() }

        var found: Set<Discovered> = []
        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem,
                let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }
            let url = URL(fileURLWithPath: path)
            guard !Self.isPruned(url) else { continue }
            let size = (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.intValue
            let modified =
                item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
            found.insert(
                Discovered(url: url, size: size ?? 0, modified: modified ?? .distantPast))
        }
        spotlightHits = found
        rebuild()
        hasSearched = true
    }

    // MARK: Scanning

    private nonisolated static func scan(roots: [URL]) async -> Set<Discovered> {
        await withTaskGroup(of: [Discovered].self) { group in
            for root in roots {
                group.addTask { scan(root: root) }
            }
            var combined: Set<Discovered> = []
            for await found in group { combined.formUnion(found) }
            return combined
        }
    }

    private nonisolated static func scan(root: URL) -> [Discovered] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return [] }

        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .nameKey,
        ]
        guard
            let enumerator = manager.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true })
        else { return [] }

        var found: [Discovered] = []
        let rootDepth = root.pathComponents.count

        for case let url as URL in enumerator {
            if found.count >= maxScanResults { break }

            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }

            if values.isDirectory == true {
                // Prune noisy trees and runaway depth rather than walking them.
                if prunedDirectories.contains(url.lastPathComponent)
                    || url.pathComponents.count - rootDepth >= maxScanDepth {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard parquetExtensions.contains(url.pathExtension.lowercased()) else { continue }

            // The Hugging Face cache keeps snapshots as symlinks into `blobs/`,
            // so the link reports its own ~79-byte size and the blob path is an
            // opaque hash. Keep the readable snapshot path, but take size and
            // date from the link's target.
            let target = try? url.resolvingSymlinksInPath()
                .resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            found.append(
                Discovered(
                    url: url,
                    size: target?.fileSize ?? values.fileSize ?? 0,
                    modified: target?.contentModificationDate
                        ?? values.contentModificationDate ?? .distantPast))
        }
        return found
    }

    private static func isPruned(_ url: URL) -> Bool {
        url.pathComponents.contains { prunedDirectories.contains($0) }
    }

    // MARK: Grouping

    private func rebuild() {
        entries = Self.group(spotlightHits.union(scanHits))
    }

    /// Strips a `-00000-of-00042` suffix so shards of one split collapse
    /// together while `train` and `test` stay apart.
    private static func splitPrefix(of url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        guard
            let range = stem.range(
                of: "-[0-9]{4,6}-of-[0-9]{4,6}$", options: .regularExpression)
        else { return stem }
        return String(stem[stem.startIndex..<range.lowerBound])
    }

    private static func group(_ files: Set<Discovered>) -> [Entry] {
        var buckets: [String: [Discovered]] = [:]
        for file in files {
            let key = file.url.deletingLastPathComponent().path + "\u{0}" + splitPrefix(of: file.url)
            buckets[key, default: []].append(file)
        }

        var result: [Entry] = []
        for (_, bucket) in buckets {
            guard let first = bucket.first else { continue }
            let modified = bucket.map(\.modified).max() ?? .distantPast
            let size = bucket.reduce(0) { $0 + $1.size }

            if bucket.count >= 2 {
                let folder = first.url.deletingLastPathComponent()
                let naming = describe(folder, isFolder: true)
                result.append(
                    Entry(
                        url: folder,
                        title: naming.title,
                        subtitle: "\(splitPrefix(of: first.url)) · \(naming.subtitle)",
                        isShardGroup: true,
                        fileCount: bucket.count,
                        totalSize: size,
                        modified: modified,
                        provenance: naming.provenance))
            } else {
                let naming = describe(first.url, isFolder: false)
                result.append(
                    Entry(
                        url: first.url,
                        title: naming.title,
                        subtitle: naming.subtitle,
                        isShardGroup: false,
                        fileCount: 1,
                        totalSize: size,
                        modified: modified,
                        provenance: naming.provenance))
            }
        }
        return result.sorted { $0.modified > $1.modified }
    }

    /// Turns a path into something readable.
    ///
    /// A Hugging Face cache path like
    /// `…/hub/datasets--mlabonne--harmful_behaviors/snapshots/<sha>/data/train.parquet`
    /// is 200 characters of noise around two useful words, so it becomes
    /// `mlabonne/harmful_behaviors`.
    private static func describe(
        _ url: URL, isFolder: Bool
    ) -> (title: String, subtitle: String, provenance: String?) {
        let components = url.pathComponents

        if let index = components.firstIndex(where: { $0.hasPrefix("datasets--") }) {
            let parts = components[index].dropFirst("datasets--".count).components(
                separatedBy: "--")
            let name = parts.joined(separator: "/")
            // Everything after the snapshot hash is the interesting remainder.
            var detail = components.dropFirst(index + 1)
            if let snapshots = detail.firstIndex(of: "snapshots") {
                detail = detail.dropFirst(detail.distance(from: detail.startIndex, to: snapshots) + 2)
            }
            let tail = detail.joined(separator: "/")
            return (name, tail.isEmpty ? "cached dataset" : tail, "Hugging Face")
        }

        let title = isFolder ? url.lastPathComponent : url.lastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var parent = url.deletingLastPathComponent().path
        if parent.hasPrefix(home) { parent = "~" + parent.dropFirst(home.count) }
        return (title, parent, nil)
    }

    // MARK: Queries

    func filtered(by text: String) -> [Entry] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || $0.subtitle.localizedCaseInsensitiveContains(needle)
                || $0.url.path.localizedCaseInsensitiveContains(needle)
        }
    }

    var totalFileCount: Int {
        entries.reduce(0) { $0 + $1.fileCount }
    }
}
