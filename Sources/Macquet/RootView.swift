import MacquetCore
import SwiftUI
import UniformTypeIdentifiers

/// Chooses between the welcome screen and a viewer, and keeps one ``TableModel``
/// alive for the window's lifetime.
struct RootView: View {
    let fileURL: URL?

    var body: some View {
        Group {
            if let fileURL {
                ViewerView(model: TableModel(url: fileURL))
                    .id(fileURL)
            } else {
                WelcomeView()
                    .documentWindow(fileURL: nil, subtitle: "")
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
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

// MARK: - Viewer

struct ViewerView: View {
    @StateObject var model: TableModel

    @State private var showsInspector = true
    @State private var showsConsole = false
    @State private var consoleHeight: CGFloat = 240
    @State private var jumpTarget = ""
    @State private var showsJumpField = false

    var body: some View {
        NavigationSplitView {
            SchemaSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 400)
        } detail: {
            content
        }
        .navigationTitle(model.url.lastPathComponent)
        .documentWindow(fileURL: model.url, subtitle: model.subtitle)
        .task { await model.open() }
        .searchable(
            text: $model.searchField,
            placement: .toolbar,
            prompt: searchPrompt
        )
        .toolbar { toolbarContent }
        .inspector(isPresented: $showsInspector) {
            RowInspector(model: model)
                .inspectorColumnWidth(min: 280, ideal: 380, max: 620)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var searchPrompt: String {
        if let column = model.spec.searchColumn { return "Search \(column)" }
        return "Search all columns"
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .opening:
            LoadingView(url: model.url)
        case .failed(let message):
            FailureView(url: model.url, message: message)
        case .ready:
            VStack(spacing: 0) {
                if model.fileChangedOnDisk { changedBanner }
                if model.spec.isFiltered { filterBar }
                DataGridView(model: model)
                if showsConsole {
                    Divider()
                    SQLConsole(model: model)
                        .frame(height: consoleHeight)
                }
                Divider()
                StatusBar(model: model, showsJumpField: $showsJumpField, jumpTarget: $jumpTarget)
            }
        }
    }

    private var changedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
            Text("This file changed on disk.")
            Button("Reload") { Task { await model.reload() } }
                .buttonStyle(.link)
            Spacer()
            Button {
                model.dismissChangeNotice()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.yellow.opacity(0.16))
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(.tint)
            Text(filterDescription)
                .font(.callout)
                .lineLimit(1)
            Spacer()
            Button("Clear") { Task { await model.clearFilters() } }
                .buttonStyle(.link)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.10))
    }

    private var filterDescription: String {
        var parts: [String] = []
        if !model.spec.searchText.isEmpty {
            let scope = model.spec.searchColumn ?? "all columns"
            parts.append("“\(model.spec.searchText)” in \(scope)")
        }
        if !model.spec.whereClause.isEmpty {
            parts.append("WHERE \(model.spec.whereClause)")
        }
        return parts.joined(separator: " · ")
            + " — \(Format.count(model.visibleRowCount)) of \(Format.count(model.totalRowCount)) rows"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            Button {
                Task { await model.reload() }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .help("Re-read the file from disk (⌘R)")
            .keyboardShortcut("r")

            Button {
                Finder.reveal(model.url)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .help("Reveal in Finder (⇧⌘R)")
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                ForEach(ParquetTable.ExportFormat.allCases, id: \.self) { format in
                    Button("Export as \(format.rawValue)…") {
                        Task { await model.export(format: format) }
                    }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export the current view")

            Button {
                showsConsole.toggle()
            } label: {
                Label("SQL", systemImage: "terminal")
            }
            .help("Toggle the SQL console (⌘T)")
            .keyboardShortcut("t")

            Button {
                showsInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Toggle the row inspector (⌥⌘I)")
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @ObservedObject var model: TableModel
    @Binding var showsJumpField: Bool
    @Binding var jumpTarget: String
    @FocusState private var jumpFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            if model.isFetching {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "tablecells")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 11))
            }

            Text("\(Format.count(model.visibleRowCount)) rows")
                .font(.system(size: 11))
            if model.spec.isFiltered {
                Text("(filtered from \(Format.count(model.totalRowCount)))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 12)

            Text("\(model.visibleColumns.count) of \(model.schema.count) columns")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if let selected = model.selectedRowIndex {
                Divider().frame(height: 12)
                Text("row \(Format.count(selected))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if showsJumpField {
                HStack(spacing: 4) {
                    Text("Go to row")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("0", text: $jumpTarget)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .focused($jumpFocused)
                        .onSubmit { jump() }
                }
            }

            Button {
                showsJumpField.toggle()
                if showsJumpField { jumpFocused = true }
            } label: {
                Image(systemName: "arrow.right.to.line")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Jump to a row (⌘L)")
            .keyboardShortcut("l")
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.bar)
    }

    private func jump() {
        guard let target = Int(jumpTarget.filter(\.isNumber)) else { return }
        model.jump(toRow: target)
        showsJumpField = false
    }
}

// MARK: - Placeholder states

struct LoadingView: View {
    let url: URL

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Reading \(url.lastPathComponent)…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FailureView: View {
    let url: URL
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text(url.lastPathComponent)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 440)
            Button("Reveal in Finder") { Finder.reveal(url) }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
