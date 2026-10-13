import Foundation

/// Keeps one reader ready while the user chooses a file. Taking it never waits
/// for readiness. No spare is created after a document opens.
@MainActor
final class OpenPanelPrewarming<Reader: AnyObject, Settings: Equatable> {
    private let makeReader: () -> Reader
    private let currentSettings: () -> Settings
    private let retentionAfterSelection: TimeInterval
    private var reader: Reader?
    private var settings: Settings?
    private var panel: UUID?
    private var expiry: DispatchWorkItem?

    init(retentionAfterSelection: TimeInterval = 10,
         settings: @escaping () -> Settings,
         makeReader: @escaping () -> Reader) {
        self.retentionAfterSelection = retentionAfterSelection
        self.currentSettings = settings
        self.makeReader = makeReader
    }

    @discardableResult
    func begin() -> UUID {
        expiry?.cancel()
        expiry = nil
        let current = currentSettings()
        if reader == nil || settings != current {
            reader = makeReader()
            settings = current
        }
        let token = UUID()
        panel = token
        return token
    }

    func finish(_ token: UUID, accepted: Bool) {
        // A document may already have taken the reader (New Document does so
        // before the panel closes), or another panel may have superseded it.
        guard panel == token else { return }
        guard accepted else {
            discard()
            return
        }
        // NSDocumentController creates the window after beginOpenPanel returns.
        // Bound retention if opening fails, selects a folder, or reuses a window.
        let expiry = DispatchWorkItem { [weak self] in
            guard self?.panel == token else { return }
            self?.discard()
        }
        self.expiry?.cancel()
        self.expiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + retentionAfterSelection, execute: expiry)
    }

    func take() -> Reader {
        let candidate = settings == currentSettings() ? reader : nil
        discard()
        return candidate ?? makeReader()
    }

    private func discard() {
        expiry?.cancel()
        expiry = nil
        reader = nil
        settings = nil
        panel = nil
    }
}
