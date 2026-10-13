import Foundation

/// Immutable directory data transferred to the outline view. Only expanded
/// folders and the selected file's ancestors are read; disclosure queries do
/// not touch the filesystem or enumerate every collapsed sibling directory.
nonisolated struct ProjectNavigatorSnapshot: Sendable {
    let url: URL
    let isDirectory: Bool
    let children: [ProjectNavigatorSnapshot]?

    @concurrent
    static func load(root: URL, expanded: Set<URL>, selected: URL?) async throws -> Self {
        try read(root.standardizedFileURL, expanded: expanded, selected: selected?.standardizedFileURL)
    }

    private static func read(_ url: URL, expanded: Set<URL>, selected: URL?) throws -> Self {
        try Task.checkCancellation()
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        var children: [Self] = []
        for entry in entries {
            try Task.checkCancellation()
            let entry = entry.standardizedFileURL
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory || ProjectFileIndex.markdownExtensions.contains(entry.pathExtension.lowercased()) else {
                continue
            }
            let containsSelection = selected.map {
                $0.pathComponents.starts(with: entry.pathComponents)
            } ?? false
            if isDirectory && (expanded.contains(entry) || containsSelection) {
                children.append(try read(entry, expanded: expanded, selected: selected))
            } else {
                children.append(Self(url: entry, isDirectory: isDirectory, children: nil))
            }
        }
        children.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        try Task.checkCancellation()
        return Self(url: url, isDirectory: true, children: children)
    }
}
