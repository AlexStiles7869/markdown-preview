import AppKit
import SwiftUI
import XCTest
@testable import MarkdownHelpers

@MainActor
final class InspectorLifecycleTests: XCTestCase {
    private func hostingView(_ controller: InspectorViewController) -> NSHostingView<InspectorView>? {
        controller.view.subviews.compactMap { $0 as? NSHostingView<InspectorView> }.first
    }

    func testCollapsedInspectorKeepsLatestDocumentWithoutBuildingForm() async throws {
        let controller = InspectorViewController()
        controller.loadViewIfNeeded() // AppKit can load the collapsed split pane.
        controller.display(markdown: "old", url: URL(fileURLWithPath: "/old.md"))
        controller.display(markdown: "# Latest\n\none two", url: URL(fileURLWithPath: "/latest.md"))
        XCTAssertNil(hostingView(controller))

        controller.setPresented(true)
        let host = try XCTUnwrap(hostingView(controller))
        XCTAssertEqual(host.rootView.metadata.fileName, "latest.md")
        XCTAssertEqual(host.rootView.metadata.wordCount, 4)
        XCTAssertEqual(host.rootView.metadata.headingCount, 1)
    }

    func testReopeningReusesFormAndRefreshesHiddenEditsAndRename() async throws {
        let controller = InspectorViewController()
        controller.display(markdown: "one", url: URL(fileURLWithPath: "/before.md"))
        controller.setPresented(true)
        let original = try XCTUnwrap(hostingView(controller))
        controller.setPresented(false)
        controller.display(markdown: "one two three", url: URL(fileURLWithPath: "/after.md"))
        XCTAssertEqual(original.rootView.metadata.fileName, "before.md")
        XCTAssertEqual(original.rootView.metadata.wordCount, 1)

        controller.setPresented(true)
        controller.setPresented(true) // Toggle and split-state observation may both notify.
        XCTAssertTrue(hostingView(controller) === original)
        XCTAssertEqual(controller.view.subviews.count, 1)
        XCTAssertEqual(original.rootView.metadata.fileName, "after.md")
        XCTAssertEqual(original.rootView.metadata.wordCount, 3)
    }

    func testInspectorPresentedBeforeDocumentUpdatesWhenDocumentArrives() async throws {
        let controller = InspectorViewController()
        controller.setPresented(true) // Restored split state can precede document delivery.
        let host = try XCTUnwrap(hostingView(controller))
        controller.display(markdown: "live update", url: nil)
        XCTAssertTrue(hostingView(controller) === host)
        XCTAssertEqual(host.rootView.metadata.wordCount, 2)
        XCTAssertNil(host.rootView.metadata.fileURL)
        controller.display(markdown: "live update again", url: URL(fileURLWithPath: "/saved.md"))
        XCTAssertEqual(host.rootView.metadata.fileName, "saved.md")
        XCTAssertEqual(host.rootView.metadata.wordCount, 3)
    }
}
