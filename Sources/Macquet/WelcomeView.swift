import SwiftUI
import UniformTypeIdentifiers

/// Shown when a window has no file: a drop target, your recents, and every
/// Parquet file on the Mac.
struct WelcomeView: View {
    @ObservedObject private var recents = RecentFiles.shared
    @StateObject private var library = ParquetLibrary()

    @State private var isDropTargeted = false
    @State private var source: Source = .library
    @State private var filter = ""

    enum Source: String, CaseIterable, Identifiable {
        case library = "On this Mac"
        case recent = "Recent"
        var id: String { rawValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            dropZone
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            browser
                .frame(width: 360)
        }
        .frame(minWidth: 760, minHeight: 460)
        .task { library.start() }
        .onDisappear { library.stop() }
    }

    // MARK: Drop zone

    private var dropZone: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.grid.3x3.square")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)

            VStack(spacing: 4) {
                Text("Macquet")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("A window into Parquet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("Drop a .parquet file here, or a folder of shards.")
                .font(.callout)
                .foregroundStyle(.tertiary)

            Button("Open…") { FilePicker.presentOpenPanel() }
                .controlSize(.large)
                .keyboardShortcut("o")
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [7, 5]))
                .padding(24)
        )
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            var handled = false
            for provider in providers where provider.canLoadObject(ofClass: URL.self) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in AppRouter.shared.present(url) }
                }
            }
            return handled
        }
    }

    // MARK: Browser

    private var browser: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $source) {
                ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            if source == .library {
                librarySearchField
            }

            Divider()

            switch source {
            case .library: libraryList
            case .recent: recentList
            }

            Divider()
            footer
        }
    }

    private var librarySearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("Filter by name or folder", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !filter.isEmpty {
                Button {
                    filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var libraryList: some View {
        let results = library.filtered(by: filter)
        if results.isEmpty {
            libraryEmptyState
        } else {
            List {
                ForEach(results) { entry in
                    Button {
                        AppRouter.shared.present(entry.url)
                    } label: {
                        LibraryRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Open") { AppRouter.shared.present(entry.url) }
                        Button("Reveal in Finder") { Finder.reveal(entry.url) }
                        Button("Copy Path") { Finder.copyPath(entry.url) }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var libraryEmptyState: some View {
        VStack(spacing: 8) {
            if library.isSearching && !library.hasSearched {
                ProgressView().controlSize(.small)
                Text("Looking for datasets…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if library.entries.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text("No Parquet files found")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(
                    "Nothing in Spotlight, your Downloads, or the model caches. "
                        + "Drop a file on the left to open it directly.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Nothing matches “\(filter)”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var recentList: some View {
        if recents.urls.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text("Nothing opened yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(recents.urls, id: \.self) { url in
                    Button {
                        AppRouter.shared.present(url)
                    } label: {
                        HStack(spacing: 8) {
                            Image(nsImage: Finder.fileIcon(for: url, size: 22))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(url.lastPathComponent)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(url.deletingLastPathComponent().path)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Reveal in Finder") { Finder.reveal(url) }
                        Button("Copy Path") { Finder.copyPath(url) }
                        Divider()
                        Button("Remove from Recents") { recents.forget(url) }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if source == .library {
                if library.isSearching {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                }
                Text(
                    "\(Format.count(library.entries.count)) datasets · "
                        + "\(Format.count(library.totalFileCount)) files")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    library.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Search again")
            } else {
                Text("\(recents.urls.count) recent")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { recents.clear() }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.bar)
    }
}

/// One Spotlight result: a single file, or a folder of shards.
private struct LibraryRow: View {
    let entry: ParquetLibrary.Entry

    private static let dateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        HStack(spacing: 8) {
            Image(
                systemName: entry.isShardGroup
                    ? "square.stack.3d.up.fill" : "tablecells"
            )
            .font(.system(size: 13))
            .foregroundStyle(entry.isShardGroup ? Color.accentColor : Color.secondary)
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(entry.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let provenance = entry.provenance {
                        Text(provenance)
                            .font(.system(size: 8, weight: .medium))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(Color.orange.opacity(0.18)))
                            .foregroundStyle(.orange)
                    }
                }
                HStack(spacing: 4) {
                    if entry.isShardGroup {
                        Text("\(entry.fileCount) shards")
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(Format.bytes(entry.totalSize))
                    Text("·")
                    Text(
                        Self.dateFormatter.localizedString(
                            for: entry.modified, relativeTo: .now))
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

                Text(entry.subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .help(entry.url.path)
    }
}
