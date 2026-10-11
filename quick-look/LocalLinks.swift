import Foundation

/// Quick Look loads the page without a base URL, so a relative link such as
/// `[setup](guides/setup.md)` has nothing to resolve against, and a `file:`
/// URL would be blocked by `ExternalLinkPolicy` anyway. Links to Markdown
/// files become `md-preview://file/<absolute path>#fragment` instead, which
/// opens the linked document in the app without a prompt.
///
/// A click is deliberate, unlike an image load, so links are not held to
/// the document folder (#337). Other files stay inert: opening them would
/// hand an arbitrary file, such as a script, to its default app.
enum LocalLinks {

    static func rewrite(html: String, baseDirectory: URL) -> String {
        let nsHtml = html as NSString
        let matches = hrefRegex.matches(
            in: html,
            range: NSRange(location: 0, length: nsHtml.length)
        )
        guard !matches.isEmpty else { return html }

        var output = ""
        output.reserveCapacity(html.count)
        var cursor = 0
        var changed = false
        for match in matches {
            output += nsHtml.substring(with: NSRange(
                location: cursor,
                length: match.range.location - cursor
            ))
            let href = nsHtml.substring(with: match.range(at: 3))
            if let url = appURL(forHref: href, baseDirectory: baseDirectory) {
                output += nsHtml.substring(with: match.range(at: 1))
                output += escapedAttribute(url.absoluteString)
                output += nsHtml.substring(with: match.range(at: 4))
                changed = true
            } else {
                output += nsHtml.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        guard changed else { return html }
        output += nsHtml.substring(from: cursor)
        return output
    }

    /// Returns nil for hrefs that should stay as written: URLs with a
    /// scheme, same-page `#fragment` links, protocol-relative `//host`
    /// links, and targets that are not Markdown files.
    static func appURL(forHref attribute: String, baseDirectory: URL) -> URL? {
        guard let href = InlineLocalAssets.localReference(attribute) else { return nil }

        var path = href
        var fragment: String?
        if let hash = path.firstIndex(of: "#") {
            fragment = String(path[path.index(after: hash)...])
            path = String(path[..<hash])
        }
        if let query = path.firstIndex(of: "?") {
            path = String(path[..<query])
        }
        guard let decodedPath = path.removingPercentEncoding, !decodedPath.isEmpty else { return nil }

        let file = URL(fileURLWithPath: decodedPath, relativeTo: baseDirectory.standardizedFileURL)
            .standardizedFileURL
        guard MarkdownAssetResolution.isMarkdownDocument(file) else { return nil }
        return ExternalOpenScheme.url(forFile: file, fragment: fragment.map { $0.removingPercentEncoding ?? $0 })
    }

    private static func escapedAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // Same shape as `InlineLocalAssets`' image regex: either quote style,
    // `data-href` skipped, group 3 is the value.
    private static let hrefRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"(<a\b[^>]*?\shref\s*=\s*(["']))([\s\S]*?)(\2)"#,
            options: [.caseInsensitive]
        )
    }()
}
