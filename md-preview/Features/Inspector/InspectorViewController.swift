//
//  InspectorViewController.swift
//  md-preview
//

import Cocoa
import SwiftUI

final class InspectorViewController: NSViewController {

    private var host: NSHostingView<InspectorView>?
    private var pendingDocument: (markdown: String, url: URL?)?
    private var isPresented = false

    override func loadView() {
        // Keep the split item and its saved geometry without constructing the
        // SwiftUI form while the inspector is collapsed.
        view = NSView()
    }

    func display(markdown: String, url: URL?) {
        // Navigation, edits, and renames replace the pending input. Hidden
        // inspectors do not scan every document for metadata.
        pendingDocument = (markdown, url)
        if isPresented { updateContentIfNeeded() }
    }

    func setPresented(_ presented: Bool) {
        isPresented = presented
        if presented { updateContentIfNeeded() }
    }

    private func updateContentIfNeeded() {
        guard host == nil || pendingDocument != nil else { return }
        let metadata = pendingDocument.map {
            DocumentMetadata.make(url: $0.url, markdown: $0.markdown)
        } ?? DocumentMetadata()
        pendingDocument = nil
        let content = InspectorView(metadata: metadata)
        if let host {
            host.rootView = content
        } else {
            loadViewIfNeeded()
            let host = NSHostingView(rootView: content)
            host.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.topAnchor.constraint(equalTo: view.topAnchor),
                host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            self.host = host
        }
    }
}
