import AppKit
import ImageIO
import MacquetCore
import SwiftUI

/// Developer hook for capturing the real window to a PNG.
///
///     Macquet --capture <file.parquet> <output.png> [delaySeconds]
///
/// The app draws its own view hierarchy with `cacheDisplay`, so this works on
/// machines where screen recording isn't permitted, and — unlike
/// `ImageRenderer` — it captures scrolling content, lists and all.
enum Snapshot {

    struct Request {
        let input: URL?
        let output: URL
        let delay: TimeInterval
        /// Optional state to drive before capturing, e.g. `select:12`,
        /// `search:landlord`, `sort:severity`, `sidebar:file`.
        let scenario: String?
    }

    static func parseArguments() -> Request? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--capture"),
            arguments.count > flag + 2
        else { return nil }

        let inputPath = arguments[flag + 1]
        let input = inputPath == "-" ? nil : URL(fileURLWithPath: inputPath)
        let output = URL(fileURLWithPath: arguments[flag + 2])
        let delay = arguments.count > flag + 3 ? (Double(arguments[flag + 3]) ?? 3.0) : 3.0

        var scenario: String?
        if let index = arguments.firstIndex(of: "--scenario"), arguments.count > index + 1 {
            scenario = arguments[index + 1]
        }
        return Request(input: input, output: output, delay: delay, scenario: scenario)
    }

    @MainActor
    static func run(_ request: Request) {
        Task { @MainActor in
            // Let SwiftUI build its first window: `AppRouter` only learns how to
            // open windows once a `RootView` has appeared.
            try? await Task.sleep(nanoseconds: 800_000_000)

            // macOS restores the previous session's windows on launch, and those
            // restored windows are never drawn here — capturing one yields a
            // blank image. Close them before opening the subject.
            for window in NSApp.windows where window.isVisible {
                window.close()
            }

            if let input = request.input {
                AppRouter.shared.present(input)
            } else {
                AppRouter.shared.presentEmptyWindow()
            }

            try? await Task.sleep(nanoseconds: UInt64(request.delay * 1_000_000_000))
            await applyScenario(request.scenario)
            capture(to: request.output, matching: request.input)
            exit(0)
        }
    }

    @MainActor
    private static func applyScenario(_ scenario: String?) async {
        guard let model = TableModel.mostRecentlyOpened else {
            print("  scenario: no model")
            return
        }
        guard let scenario else { return }
        let parts = scenario.split(separator: ":", maxSplits: 1).map(String.init)
        guard let command = parts.first else { return }
        let argument = parts.count > 1 ? parts[1] : ""

        switch command {
        case "select":
            model.select(rowIndex: Int(argument) ?? 0)
        case "search":
            model.searchField = argument
        case "sort":
            await model.setSort(column: argument, direction: .descending)
        case "focus":
            // `row.column` — exercises the same entry point the tap handler uses.
            let pieces = argument.split(separator: ".", maxSplits: 1).map(String.init)
            if pieces.count == 2, let row = Int(pieces[0]),
                let column = model.schema.first(where: { $0.name == pieces[1] }) {
                model.focusCell(row: row, column: column)
            }
        case "jump":
            model.jump(toRow: Int(argument) ?? 0)
        case "hide":
            if let column = model.schema.first(where: { $0.name == argument }) {
                model.toggleVisibility(of: column)
            }
        default:
            break
        }
        // Filters re-count and re-fetch; give that a beat to settle.
        try? await Task.sleep(nanoseconds: 1_800_000_000)
    }

    @MainActor
    private static func capture(to output: URL, matching input: URL?) {
        var candidates = NSApp.windows.filter {
            $0.isVisible && $0.contentView != nil && $0.frame.width > 300
        }
        if let input {
            let wanted = input.standardizedFileURL
            let matches = candidates.filter { $0.representedURL?.standardizedFileURL == wanted }
            if !matches.isEmpty { candidates = matches }
        }
        for window in candidates {
            print(
                "  window: \"\(window.title)\" \(Int(window.frame.width))×"
                    + "\(Int(window.frame.height)) represented=\(window.representedURL?.lastPathComponent ?? "-")")
        }

        // A document window is the one carrying a represented URL; the welcome
        // window has none. Fall back to the largest if nothing is open yet.
        let documentWindow = candidates.first { $0.representedURL != nil }
        let largest = candidates.max {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }
        guard let window = documentWindow ?? largest, let view = window.contentView else {
            FileHandle.standardError.write(Data("capture: no window found\n".utf8))
            exit(1)
        }

        window.makeKeyAndOrderFront(nil)
        view.displayIfNeeded()

        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            FileHandle.standardError.write(Data("capture: couldn't allocate bitmap\n".utf8))
            exit(1)
        }
        view.cacheDisplay(in: view.bounds, to: representation)

        guard let png = representation.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("capture: PNG encoding failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: output)
            print("wrote \(output.path) (\(Int(view.bounds.width))×\(Int(view.bounds.height)))")
        } catch {
            FileHandle.standardError.write(
                Data("capture: \(error.localizedDescription)\n".utf8))
            exit(1)
        }

        // `cacheDisplay` re-runs the view drawing path, which misses content
        // that only exists in the layer tree. Write a layer-rendered copy too
        // so the two can be compared when something looks missing.
        writeLayerRender(of: view, to: output.deletingPathExtension()
            .appendingPathExtension("layer.png"))
    }

    @MainActor
    private static func writeLayerRender(of view: NSView, to output: URL) {
        guard let layer = view.layer else { return }
        let scale = view.window?.backingScaleFactor ?? 2
        let width = Int(view.bounds.width * scale)
        let height = Int(view.bounds.height * scale)
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        context.scaleBy(x: scale, y: scale)
        // CALayer's coordinate origin is bottom-left in a CGContext.
        context.translateBy(x: 0, y: view.bounds.height)
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)

        guard let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithURL(
                output as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        print("wrote \(output.path) (layer render)")
    }
}
