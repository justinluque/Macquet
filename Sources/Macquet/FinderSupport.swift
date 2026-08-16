import AppKit
import SwiftUI

// MARK: - Recent files

/// Keeps the system Open Recent menu in sync and backs the welcome screen's
/// list. Bookmarks are stored so a recent entry survives the file being moved.
@MainActor
final class RecentFiles: ObservableObject {
    static let shared = RecentFiles()
    private static let defaultsKey = "recentBookmarks"
    private static let limit = 12

    @Published private(set) var urls: [URL] = []

    private init() {
        urls = loadBookmarks()
    }

    func note(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        urls.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        urls.insert(url, at: 0)
        if urls.count > Self.limit { urls.removeLast(urls.count - Self.limit) }
        saveBookmarks()
    }

    func forget(_ url: URL) {
        urls.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        saveBookmarks()
    }

    func clear() {
        urls.removeAll()
        saveBookmarks()
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    private func saveBookmarks() {
        let data = urls.compactMap { try? $0.bookmarkData(options: [.suitableForBookmarkFile]) }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private func loadBookmarks() -> [URL] {
        guard let stored = UserDefaults.standard.array(forKey: Self.defaultsKey) as? [Data] else {
            return []
        }
        return stored.compactMap { data in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
            else { return nil }
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }
}

// MARK: - Finder actions

enum Finder {
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func copyPath(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }

    static func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Hands the file to whichever app the user has set for "Open With".
    static func openWithDefaultApp(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func fileIcon(for url: URL, size: CGFloat) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: size, height: size)
        return icon
    }
}

// MARK: - Window plumbing

/// Reaches the hosting `NSWindow` so the document proxy icon, title and
/// subtitle behave the way a native document window does: the titlebar icon is
/// draggable into Finder or Mail, and ⌘-clicking the title reveals the folder
/// path.
struct WindowConfigurator: NSViewRepresentable {
    /// Marks a window that holds no file, so stale welcome windows can be
    /// identified and closed once a real file opens.
    static let welcomeIdentifier = "macquet.welcome"

    var fileURL: URL?
    var subtitle: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView.window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.representedURL = fileURL
        window.title = fileURL?.lastPathComponent ?? "Macquet"
        window.subtitle = subtitle
        window.titlebarSeparatorStyle = .automatic
        window.identifier =
            fileURL == nil
            ? NSUserInterfaceItemIdentifier(Self.welcomeIdentifier)
            : NSUserInterfaceItemIdentifier("macquet.document")
    }
}

extension View {
    /// Applies document-window behaviour for `fileURL`.
    func documentWindow(fileURL: URL?, subtitle: String) -> some View {
        background(WindowConfigurator(fileURL: fileURL, subtitle: subtitle))
    }
}

// MARK: - File watching

/// Watches a file for external writes so the viewer can offer to reload.
///
/// Data files get regenerated constantly while someone iterates on a pipeline;
/// noticing that is the difference between a viewer and a stale screenshot.
final class FileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private let url: URL
    private let onChange: @Sendable () -> Void

    init?(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
        guard start() else { return nil }
    }

    private func start() -> Bool {
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main)
        let callback = onChange
        source.setEventHandler { callback() }
        source.setCancelHandler { [descriptor] in
            if descriptor >= 0 { close(descriptor) }
        }
        source.resume()
        self.source = source
        return true
    }

    func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
    }

    deinit { source?.cancel() }
}
