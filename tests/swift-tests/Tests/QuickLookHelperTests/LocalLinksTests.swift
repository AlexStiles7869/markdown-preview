import XCTest
@testable import QuickLookHelpers

final class LocalLinksTests: XCTestCase {

    private let baseDir = URL(fileURLWithPath: "/tmp/ql-links/docs/", isDirectory: true)

    private func appURL(_ href: String) -> String? {
        LocalLinks.appURL(forHref: href, baseDirectory: baseDir)?.absoluteString
    }

    func testRelativeMarkdownLinkBecomesAppURL() {
        XCTAssertEqual(appURL("guides/setup.md"), "md-preview://file/tmp/ql-links/docs/guides/setup.md")
        XCTAssertEqual(appURL("./README.markdown"), "md-preview://file/tmp/ql-links/docs/README.markdown")
        XCTAssertEqual(appURL("Notes.MD"), "md-preview://file/tmp/ql-links/docs/Notes.MD")
    }

    func testParentAndAbsoluteMarkdownLinksResolve() {
        XCTAssertEqual(appURL("../other/a.md"), "md-preview://file/tmp/ql-links/other/a.md")
        XCTAssertEqual(appURL("/Users/me/b.md"), "md-preview://file/Users/me/b.md")
    }

    func testFragmentIsKeptAndQueryDropped() {
        XCTAssertEqual(appURL("setup.md#install-steps"), "md-preview://file/tmp/ql-links/docs/setup.md#install-steps")
        XCTAssertEqual(appURL("setup.md?plain=1#x"), "md-preview://file/tmp/ql-links/docs/setup.md#x")
        XCTAssertEqual(appURL("setup.md#"), "md-preview://file/tmp/ql-links/docs/setup.md")
    }

    func testEncodedCharactersRoundTrip() {
        let url = LocalLinks.appURL(forHref: "my%20notes/a&amp;b.md#caf%C3%A9", baseDirectory: baseDir)
        XCTAssertEqual(url?.path, "/tmp/ql-links/docs/my notes/a&b.md")
        XCTAssertEqual(url?.fragment, "caf%C3%A9")
        XCTAssertEqual(url.flatMap(ExternalOpenScheme.resolvedURL(opening:))?.path, "/tmp/ql-links/docs/my notes/a&b.md")
    }

    func testOtherLinksStayAsWritten() {
        for href in ["", "#section", "https://example.com/a.md", "mailto:a@b.c", "//host/a.md",
                     "file:///etc/a.md", "image.png", "script.command", "folder/", "a.md.zip"] {
            XCTAssertNil(appURL(href), href)
        }
    }

    func testRewriteReplacesOnlyMarkdownHrefsAndEscapesThem() {
        let html = ##"<a href="a&amp;b.md#x">A</a> <a href='it&#39;s.md'>B</a> <a href="#top">C</a> <a href="https://e.com">D</a>"##
        XCTAssertEqual(
            LocalLinks.rewrite(html: html, baseDirectory: baseDir),
            ##"<a href="md-preview://file/tmp/ql-links/docs/a&amp;b.md#x">A</a> <a href='md-preview://file/tmp/ql-links/docs/it&#39;s.md'>B</a> <a href="#top">C</a> <a href="https://e.com">D</a>"##
        )
    }
}
