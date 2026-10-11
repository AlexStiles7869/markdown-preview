import WebKit
import XCTest
@testable import MarkdownHelpers

final class QuickLookLinkNavigationTests: XCTestCase {
    @MainActor
    func testWebLinksGoToTheAppAndCustomLinksPlayTheAlertSound() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ql-links-\(UUID().uuidString).md")
        try """
        [Custom](unlisted-app://open/item)

        [Web](https://example.com)

        [Unsafe](javascript:alert(1))
        """.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let controller = PreviewViewController()
        var handedOff: [URL] = []
        var rejected = 0
        controller.handOffToApp = { url in handedOff.append(url); return true }
        controller.rejectLink = { rejected += 1 }
        try await controller.preparePreviewOfFile(at: file)
        let view = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)
        defer { view.stopLoading() }
        let deadline = Date().addingTimeInterval(15)
        while view.isLoading && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(view.isLoading)
        // Quick Look cannot open URLs: a custom link only gets the alert
        // sound, a web link goes to the app. Neither navigates the page.
        for (index, expectedRejections, expectedHandOffs) in [(0, 1, 0), (1, 1, 1)] {
            _ = try await view.evaluateJavaScript("document.querySelectorAll('article a')[\(index)].click(); true")
            let clickDeadline = Date().addingTimeInterval(3)
            while rejected < expectedRejections || handedOff.count < expectedHandOffs, Date() < clickDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(rejected, expectedRejections)
            XCTAssertEqual(handedOff.count, expectedHandOffs)
            XCTAssertEqual(view.url?.absoluteString, "about:blank", "Links must not navigate the preview")
        }
        XCTAssertEqual(handedOff.last?.absoluteString, "https://example.com/")
        let unsafeHref = try await view.evaluateJavaScript("document.querySelectorAll('article a')[2].hasAttribute('href')")
        XCTAssertEqual(unsafeHref as? Bool, false)
    }

    @MainActor
    func testRelativeMarkdownLinksOpenInTheApp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ql-file-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("guides"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("README.md")
        try """
        [Setup](guides/setup.md#install) <a href='../Other Notes.md'>Raw</a> [Image](diagram.png)
        """.write(to: file, atomically: true, encoding: .utf8)
        let controller = PreviewViewController()
        var opened: [URL] = []
        var appIsRunning = true
        var rejected = 0
        controller.handOffToApp = { url in
            guard appIsRunning else { return false }
            opened.append(url)
            return true
        }
        controller.rejectLink = { rejected += 1 }
        try await controller.preparePreviewOfFile(at: file)
        let view = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)
        defer { view.stopLoading() }
        let deadline = Date().addingTimeInterval(15)
        while view.isLoading && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(view.isLoading)

        let folderPath = folder.standardizedFileURL.path
        let expected = [
            "md-preview://file\(folderPath)/guides/setup.md#install",
            "md-preview://file\(folder.deletingLastPathComponent().standardizedFileURL.path)/Other%20Notes.md",
        ]
        for (index, destination) in expected.enumerated() {
            _ = try await view.evaluateJavaScript("document.querySelectorAll('article a')[\(index)].click(); true")
            let clickDeadline = Date().addingTimeInterval(3)
            while opened.count <= index && Date() < clickDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(opened.last?.absoluteString, destination)
            XCTAssertEqual(view.url?.absoluteString, "about:blank")
        }
        XCTAssertEqual(rejected, 0)
        let imageHref = try await view.evaluateJavaScript("document.querySelectorAll('article a')[2].getAttribute('href')")
        XCTAssertEqual(imageHref as? String, "diagram.png", "Non-Markdown targets stay as written")

        // A non-Markdown file cannot open, and with the app closed nothing can.
        for (index, expectedRejections) in [(2, 1), (0, 2)] {
            if index == 0 { appIsRunning = false }
            _ = try await view.evaluateJavaScript("document.querySelectorAll('article a')[\(index)].click(); true")
            let clickDeadline = Date().addingTimeInterval(3)
            while rejected < expectedRejections && Date() < clickDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(rejected, expectedRejections)
        }
        XCTAssertEqual(opened.count, expected.count)
    }
}
