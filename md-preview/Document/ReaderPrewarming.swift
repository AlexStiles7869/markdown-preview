import Cocoa

/// Start only when a file picker gives us useful lead time. Direct document
/// launches build their reader normally, without competing speculative work.
@MainActor
enum ReaderPrewarming {
    static let shared = OpenPanelPrewarming(
        settings: { ReaderRenderSettings.current },
        makeReader: { MarkdownWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720)) }
    )
}
