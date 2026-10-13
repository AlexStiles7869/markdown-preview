//
//  ProjectNavigatorView.swift
//  md-preview
//

import Cocoa

private final class FileNode {
    let url: URL
    let isDirectory: Bool
    private var loadedChildren: [FileNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    var displayName: String { url.lastPathComponent }

    var cachedChildren: [FileNode]? { loadedChildren }

    convenience init(snapshot: ProjectNavigatorSnapshot) {
        self.init(url: snapshot.url, isDirectory: snapshot.isDirectory)
        loadedChildren = snapshot.children?.map(FileNode.init(snapshot:))
    }

    func children() -> [FileNode] { loadedChildren ?? [] }
}

final class ProjectNavigatorView: NSView {

    var onSelectFile: ((URL) -> Void)?

    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private var rootNode: FileNode?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0
    private var expandedURLs: Set<URL> = []
    private var applyingSnapshot = false
    private var revealSelectionAfterLoad = false
    /// The file whose document is actually open. Keep this separate from the
    /// outline's transient click selection so a pending Save/Don't Save/Cancel
    /// decision cannot make the navigator disagree with the editor.
    private var currentFileURL: URL?
    // One watcher per loaded directory; kept in sync with which FileNodes
    // currently have a populated children cache.
    private var watchers: [URL: DirectoryWatcher] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    isolated deinit {
        loadTask?.cancel()
        cancelAllWatchers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        addSubview(scrollView)

        outlineView.style = .sourceList
        outlineView.headerView = nil
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)
        outlineView.indentationPerLevel = 14
        outlineView.refusesFirstResponder = true

        let contextMenu = NSMenu()
        contextMenu.delegate = self
        outlineView.menu = contextMenu

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView.documentView = outlineView

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    func setRoot(_ url: URL?) {
        loadTask?.cancel()
        loadGeneration &+= 1
        cancelAllWatchers()
        rootNode = url.map { FileNode(url: $0.standardizedFileURL, isDirectory: true) }
        expandedURLs = Set(rootNode.map { [$0.url] } ?? [])
        applyingSnapshot = true
        outlineView.reloadData()
        if let rootNode { outlineView.expandItem(rootNode) }
        applyingSnapshot = false
        refreshTree()
    }

    // MARK: - Folder watching

    private func syncWatchers() {
        var live: Set<URL> = []
        if let rootNode { collectLoadedDirectories(rootNode, into: &live) }
        for url in live where watchers[url] == nil {
            watchers[url] = DirectoryWatcher(url: url) { [weak self] in
                self?.handleFolderChange()
            }
        }
        for (url, watcher) in watchers where !live.contains(url) {
            watcher.cancel()
            watchers.removeValue(forKey: url)
        }
    }

    private func collectLoadedDirectories(_ node: FileNode, into set: inout Set<URL>) {
        guard node.isDirectory else { return }
        guard let kids = node.cachedChildren else { return }
        set.insert(node.url.standardizedFileURL)
        for child in kids where child.isDirectory {
            collectLoadedDirectories(child, into: &set)
        }
    }

    private func cancelAllWatchers() {
        for watcher in watchers.values { watcher.cancel() }
        watchers.removeAll()
    }

    private func handleFolderChange() {
        refreshTree()
    }

    /// Keep the displayed tree intact until a complete background read arrives.
    /// A newer root, selection, expansion, or watcher event invalidates the old
    /// result, even if cancellation cannot interrupt an in-flight system call.
    private func refreshTree() {
        guard let rootNode else { return }
        loadTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        let rootURL = rootNode.url
        let expanded = expandedURLs
        let selected = currentFileURL
        loadTask = Task { @concurrent [weak self] in
            guard let snapshot = try? await ProjectNavigatorSnapshot.load(
                root: rootURL, expanded: expanded, selected: selected
            ), !Task.isCancelled else { return }
            await self?.apply(snapshot, generation: generation)
        }
    }

    private func apply(_ snapshot: ProjectNavigatorSnapshot, generation: UInt64) {
        guard generation == loadGeneration else { return }
        loadTask = nil
        rootNode = FileNode(snapshot: snapshot)
        applyingSnapshot = true
        outlineView.reloadData()
        if let rootNode {
            if expandedURLs.contains(rootNode.url) { outlineView.expandItem(rootNode) }
            reExpand(rootNode, expanded: expandedURLs)
        }
        selectCurrentFile(reveal: revealSelectionAfterLoad)
        revealSelectionAfterLoad = false
        applyingSnapshot = false
        syncWatchers()
    }

    private func reExpand(_ node: FileNode, expanded: Set<URL>) {
        guard node.isDirectory, outlineView.isItemExpanded(node) else { return }
        for child in node.children() where child.isDirectory {
            if expanded.contains(child.url.standardizedFileURL) {
                outlineView.expandItem(child)
                reExpand(child, expanded: expanded)
            }
        }
    }

    func setCurrentFile(_ url: URL?) {
        currentFileURL = url?.standardizedFileURL
        revealSelectionAfterLoad = !selectCurrentFile(reveal: true)
        // A pending read captured the previous selection/expansions. Replace
        // it even when this selection can already be shown from the cache.
        if revealSelectionAfterLoad || loadTask != nil { refreshTree() }
    }

    @discardableResult
    private func selectCurrentFile(reveal: Bool) -> Bool {
        guard let target = currentFileURL, let rootNode else {
            outlineView.deselectAll(nil)
            return true
        }
        var path: [FileNode] = []
        guard collectPath(to: target, from: rootNode, into: &path) else {
            outlineView.deselectAll(nil)
            return false
        }
        if reveal {
            for ancestor in [rootNode] + path.dropLast() {
                expandedURLs.insert(ancestor.url)
                outlineView.expandItem(ancestor)
            }
        }
        if let leaf = path.last {
            let row = outlineView.row(forItem: leaf)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
                refreshRowTextColors()
            }
        }
        return true
    }

    private func collectPath(to targetURL: URL,
                             from root: FileNode,
                             into path: inout [FileNode]) -> Bool {
        // Skip subtrees that can't contain the target.
        guard targetURL.isDescendantOrSame(of: root.url) else { return false }

        for child in root.children() {
            if child.url.standardizedFileURL == targetURL {
                path.append(child)
                return true
            }
            if child.isDirectory {
                path.append(child)
                if collectPath(to: targetURL, from: child, into: &path) { return true }
                path.removeLast()
            }
        }
        return false
    }

    @objc private func rowClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }
        if node.isDirectory {
            // Disclosure buttons handle their own clicks in AppKit; this
            // action covers the folder's name, icon, and remaining row area.
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        } else {
            let requestedURL = node.url.standardizedFileURL
            guard requestedURL != currentFileURL else { return }
            // `shouldSelectItem` keeps the highlight on the committed file,
            // so there's no AppKit selection to undo here — display(markdown:)
            // selects the requested file only after navigation succeeds.
            onSelectFile?(node.url)
        }
    }

    @objc private func showInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openInNewTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL,
              let controller = documentWindowController else { return }
        controller.openInNewTab(url)
    }

    @objc private func openInNewWindow(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL,
              let controller = documentWindowController else { return }
        controller.openInNewWindow(url)
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }

    @objc private func copyContents(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Task { @concurrent in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            await MainActor.run {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        }
    }
}

extension ProjectNavigatorView: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }
        let url = node.url

        menu.addItem(makeMenuItem(title: NSLocalizedString("Show in Finder", comment: "Project navigator context menu"),
                                  symbol: "folder",
                                  action: #selector(showInFinder(_:)),
                                  url: url))

        if !node.isDirectory {
            menu.addItem(.separator())
            menu.addItem(makeMenuItem(title: NSLocalizedString("Open in New Tab", comment: "Project navigator context menu"),
                                      symbol: "macwindow",
                                      action: #selector(openInNewTab(_:)),
                                      url: url))
            menu.addItem(makeMenuItem(title: NSLocalizedString("Open in New Window", comment: "Project navigator context menu"),
                                      symbol: "macwindow.badge.plus",
                                      action: #selector(openInNewWindow(_:)),
                                      url: url))
            if let controller = documentWindowController {
                for item in controller.contextMenuEditorItems(for: url) {
                    menu.addItem(item)
                }
            }
            menu.addItem(.separator())
            menu.addItem(makeMenuItem(title: NSLocalizedString("Copy", comment: "Project navigator context menu"),
                                      symbol: "document.on.clipboard",
                                      action: #selector(copyContents(_:)),
                                      url: url))
        } else {
            menu.addItem(.separator())
        }

        menu.addItem(makeMenuItem(title: NSLocalizedString("Copy Path", comment: "Project navigator context menu"),
                                  symbol: "document.on.document",
                                  action: #selector(copyPath(_:)),
                                  url: url))
    }

    private func makeMenuItem(title: String,
                              symbol: String,
                              action: Selector,
                              url: URL) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = url
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    private var documentWindowController: DocumentWindowController? {
        outlineView.window?.windowController as? DocumentWindowController
    }

    /// Theme accent for the selected file row — the link color, matching
    /// the TOC outline's treatment. Nil without a link override.
    fileprivate var themeAccent: NSColor? {
        let isDark = effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return ThemeColorsSetting.current.color(.linkColor, isDark ? .dark : .light)
    }

    func refreshRowTextColors() {
        let accent = themeAccent ?? .controlAccentColor
        let selected = outlineView.selectedRow
        for row in 0..<outlineView.numberOfRows {
            guard let cell = outlineView.view(
                atColumn: 0, row: row, makeIfNecessary: false
            ) as? NSTableCellView, let textField = cell.textField else { continue }
            textField.textColor = row == selected ? accent : .labelColor
        }
    }
}

extension ProjectNavigatorView: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? FileNode { return node.children().count }
        return rootNode == nil ? 0 : 1
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? FileNode { return node.children()[index] }
        return rootNode!
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FileNode else { return false }
        return node.isDirectory && (node.cachedChildren?.isEmpty != true)
    }
}

extension ProjectNavigatorView: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("FileCell")
        let cell: NSTableCellView
        if let recycled = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = recycled
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            cell.addSubview(imageView)
            cell.imageView = imageView

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            textField.cell?.usesSingleLineMode = true
            textField.maximumNumberOfLines = 1
            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        cell.textField?.stringValue = node.displayName
        let icon = NSWorkspace.shared.icon(forFile: node.url.path)
        icon.size = NSSize(width: 16, height: 16)
        cell.imageView?.image = icon
        let row = outlineView.row(forItem: node)
        cell.textField?.textColor = row >= 0 && row == outlineView.selectedRow
            ? (themeAccent ?? .controlAccentColor)
            : .labelColor
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        QuietSelectionRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        return 24
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        refreshRowTextColors()
    }

    /// A click must not move the selection away from the committed file:
    /// the highlight only follows after navigation actually succeeds
    /// (`setCurrentFile`). Preventing the native selection here is what
    /// stops the O → X → O bounce on file switches. Directories stay
    /// selectable — they have no navigation side effect.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? FileNode else { return false }
        if node.isDirectory { return true }
        return node.url.standardizedFileURL == currentFileURL?.standardizedFileURL
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard !applyingSnapshot, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        expandedURLs.insert(node.url)
        if node.cachedChildren == nil { refreshTree() }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !applyingSnapshot, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        expandedURLs.remove(node.url)
        revealSelectionAfterLoad = false
        // Supersede a pending expansion read so it cannot reopen this folder.
        if loadTask != nil { refreshTree() }
    }
}

private final class DirectoryWatcher {
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var cancelled = false
    private var debounce: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        Task { @concurrent [weak self] in
            let fd = Darwin.open(url.path, O_EVTONLY)
            guard fd >= 0 else { return }
            await MainActor.run { [weak self] in
                guard let self, !self.cancelled else {
                    Darwin.close(fd)
                    return
                }
                self.start(fileDescriptor: fd)
            }
        }
    }

    private func start(fileDescriptor fd: Int32) {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleChange() }
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source
        source.resume()
        // Catch changes between the directory snapshot and asynchronous watch
        // registration; subsequent refreshes reuse this watcher.
        scheduleChange()
    }

    /// FS events arrive in bursts (Finder rewrites + xattr updates). Coalesce.
    private func scheduleChange() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    isolated deinit { source?.cancel() }

    func cancel() {
        cancelled = true
        debounce?.cancel()
        source?.cancel()
        source = nil
    }
}
