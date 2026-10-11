//
//  ExternalOpenScheme.swift
//  md-preview
//
//  Resolves md-preview:// URLs — the custom scheme browsers and other apps
//  use to hand the app a file or folder to open, mirroring the shape of
//  cursor://file/<absolute path>. Kept free of AppKit so the SPM helper
//  tests can exercise it without a GUI host.
//

import Foundation

nonisolated enum ExternalOpenScheme {

    static let scheme = "md-preview"

    /// Translates an incoming open request into the URL to actually open.
    /// URLs of other schemes (file URLs, mostly) pass through untouched.
    /// The app's own scheme accepts
    ///
    ///     md-preview://file/Users/me/README.md
    ///     md-preview:///Users/me/README.md
    ///
    /// and resolves to the file the percent-decoded path names
    /// (`My%20Notes` → `My Notes`). Returns nil only for a malformed
    /// md-preview:// link — another host, an empty path — so the caller
    /// can tell one apart from a URL it can open.
    static func resolvedURL(opening url: URL) -> URL? {
        guard url.scheme?.caseInsensitiveCompare(scheme) == .orderedSame else {
            return url
        }

        let host = url.host ?? ""
        guard host.isEmpty || host.caseInsensitiveCompare("file") == .orderedSame
        else { return nil }

        let path = url.path
        guard path.count > 1, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// `md-preview://file/<absolute path>#fragment`, the form
    /// `resolvedURL(opening:)` reads back.
    static func url(forFile file: URL, fragment: String?) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "file"
        components.path = file.path
        if let fragment, !fragment.isEmpty {
            components.fragment = fragment
        }
        return components.url
    }

    /// LaunchServices refuses every open from the Quick Look extension's
    /// launch session, web links included (#492). The extension hands a
    /// Markdown link to the running app with this distributed notification
    /// instead; its object is the URL string. The name carries
    /// the app's bundle identifier, so a Debug and a release build do not
    /// both answer.
    static func quickLookOpenNotification(appBundleIdentifier: String) -> Notification.Name {
        Notification.Name(appBundleIdentifier + ".quick-look.open")
    }

    /// The links Quick Look hands to the app: web links, and md-preview://
    /// links (Quick Look's rewrite of links to Markdown files).
    static func isQuickLookHandOff(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == Self.scheme
    }

    /// The percent-decoded `#section` of an md-preview:// link.
    static func fragment(opening url: URL) -> String? {
        guard url.scheme?.caseInsensitiveCompare(scheme) == .orderedSame,
              let fragment = url.fragment?.removingPercentEncoding,
              !fragment.isEmpty
        else { return nil }
        return fragment
    }
}
