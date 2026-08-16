import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct MacquetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: AppRouter.viewerWindowID, for: URL.self) { $url in
            RootView(fileURL: url)
                .frame(minWidth: 720, minHeight: 420)
                .task {
                    // Finder can hand us a file before any scene exists, so the
                    // router queues those opens and replays them the moment an
                    // `openWindow` action becomes available.
                    AppRouter.shared.register(openWindow: openWindow)
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands { MacquetCommands() }

        Settings { SettingsView() }
    }
}

// MARK: - Routing

/// Bridges AppKit's file-open events to SwiftUI's window system.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    static let viewerWindowID = "viewer"

    private var openWindow: OpenWindowAction?
    private var pending: [URL] = []

    func register(openWindow action: OpenWindowAction) {
        guard openWindow == nil else { return }
        openWindow = action
        let queued = pending
        pending.removeAll()
        for url in queued { present(url) }
    }

    /// Opens `url` in a window, or focuses the window already showing it.
    func present(_ url: URL) {
        let standardized = url.standardizedFileURL
        RecentFiles.shared.note(standardized)
        guard let openWindow else {
            pending.append(standardized)
            return
        }
        openWindow(id: Self.viewerWindowID, value: standardized)
        closeEmptyWindows()
    }

    /// Closes leftover welcome windows once something is actually open.
    ///
    /// Launching by double-clicking a file in Finder makes SwiftUI show the
    /// group's default (empty) window before the open event arrives; without
    /// this, every Finder open leaves a stray welcome window behind.
    private func closeEmptyWindows() {
        Task { @MainActor in
            // Let the new window materialise before deciding what's stale.
            try? await Task.sleep(nanoseconds: 400_000_000)
            let windows = NSApp.windows.filter { $0.isVisible }
            guard windows.contains(where: { $0.representedURL != nil }) else { return }
            for window in windows
            where window.identifier?.rawValue == WindowConfigurator.welcomeIdentifier {
                window.close()
            }
        }
    }

    /// Opens a window with no file — the welcome screen.
    ///
    /// Deliberately calls `openWindow(id:)` with no value: the group's value
    /// type is `URL`, so handing it `URL?.none` matches nothing and silently
    /// opens no window at all.
    func presentEmptyWindow() {
        guard let openWindow else { return }
        openWindow(id: Self.viewerWindowID)
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Finder double-click, drag-onto-dock, `open -a`, and Services all land here.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls { AppRouter.shared.present(url) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Developer hook: open a file, capture the window, exit. Used to check
        // layout on machines where taking a screenshot isn't an option.
        if let request = Snapshot.parseArguments() {
            Task { @MainActor in Snapshot.run(request) }
            return
        }

        // The grid draws its own separators; the stock window shadow under a
        // full-size toolbar is enough visual separation.
        UserDefaults.standard.register(defaults: [
            "NSInitialToolbarIsVisible": true
        ])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Re-opening from the Dock with no windows shows the welcome screen.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        if !hasVisibleWindows {
            Task { @MainActor in AppRouter.shared.presentEmptyWindow() }
        }
        return true
    }
}

// MARK: - Menus

struct MacquetCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                openWindow(id: AppRouter.viewerWindowID)
            }
            .keyboardShortcut("n")

            Button("Open…") { FilePicker.presentOpenPanel() }
                .keyboardShortcut("o")
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("Open Recent") {}.disabled(true)
        }

        CommandGroup(replacing: .help) {
            Button("Macquet Help") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/"))
            }
            .disabled(true)
        }
    }
}

// MARK: - Open panel

enum FilePicker {
    /// The Parquet content type, falling back to a filename-extension type on
    /// systems that don't know `parquet` natively.
    static var parquetType: UTType {
        UTType(importedAs: "org.apache.parquet", conformingTo: .data)
    }

    @MainActor
    static func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Choose a Parquet file, or a folder of shards."
        panel.prompt = "Open"
        panel.allowedContentTypes = [parquetType]
        panel.treatsFilePackagesAsDirectories = true

        guard panel.runModal() == .OK else { return }
        for url in panel.urls { AppRouter.shared.present(url) }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage(Prefs.wrapCellText) private var wrapCellText = false
    @AppStorage(Prefs.showRowNumbers) private var showRowNumbers = true
    @AppStorage(Prefs.pageSize) private var pageSize = 200

    var body: some View {
        Form {
            Section("Grid") {
                Toggle("Show physical row numbers", isOn: $showRowNumbers)
                Toggle("Wrap text in the inspector", isOn: $wrapCellText)
            }
            Section("Performance") {
                Picker("Rows per fetch", selection: $pageSize) {
                    Text("100").tag(100)
                    Text("200").tag(200)
                    Text("500").tag(500)
                    Text("1000").tag(1000)
                }
                Text("Larger pages mean fewer queries but a longer pause on each one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}

enum Prefs {
    static let wrapCellText = "wrapCellText"
    static let showRowNumbers = "showRowNumbers"
    static let pageSize = "pageSize"
}
