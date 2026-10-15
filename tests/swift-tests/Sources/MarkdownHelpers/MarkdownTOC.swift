//
//  MarkdownTOC.swift
//  md-preview
//

import Foundation
import Markdown

nonisolated struct TOCItem: Identifiable, Hashable, Sendable {
    let id: Int
    let level: Int
    let title: String
    let sourceLine: Int
    var children: [TOCItem]
}

nonisolated enum MarkdownTOC {

    static func parse(_ markdown: String) -> [TOCItem] {
        let headings = extractHeadings(from: markdown)
        return buildTree(headings)
    }

    private struct RawHeading {
        let level: Int
        let title: String
        let sourceLine: Int
    }

    private static func extractHeadings(from markdown: String) -> [RawHeading] {
        // Share the renderer's CommonMark parsing so container nesting and fence
        // delimiters cannot turn code-block contents into outline entries.
        let split = MarkdownFrontmatter.split(markdown)
        let body = split.body
        var collector = HeadingCollector(sourceLineOffset: split.bodyLineOffset)
        collector.visit(Document(parsing: body))
        return collector.headings
    }

    private struct HeadingCollector: MarkupWalker {
        let sourceLineOffset: Int
        var headings: [RawHeading] = []

        mutating func visitHeading(_ heading: Heading) {
            // Parsed headings are expected to have source locations.
            guard let range = heading.range else {
                preconditionFailure("Parsed Markdown heading is missing a source range")
            }
            // Keep empty headings too: IDs follow rendered heading order.
            headings.append(RawHeading(
                level: heading.level,
                title: Self.titleText(heading),
                sourceLine: range.lowerBound.line + sourceLineOffset
            ))
        }

        private static func titleText(_ markup: Markup) -> String {
            // InlineCode.plainText includes backticks; the outline shows its content.
            if let code = markup as? InlineCode { return code.code }
            if markup.childCount > 0 {
                return markup.children.map { titleText($0) }.joined()
            }
            return (markup as? InlineMarkup)?.plainText ?? ""
        }
    }

    private static func buildTree(_ headings: [RawHeading]) -> [TOCItem] {
        final class Node {
            let level: Int
            let id: Int
            let title: String
            let sourceLine: Int
            var children: [Node] = []
            init(level: Int, id: Int, title: String, sourceLine: Int) {
                self.level = level
                self.id = id
                self.title = title
                self.sourceLine = sourceLine
            }
            func toItem() -> TOCItem {
                TOCItem(id: id, level: level, title: title, sourceLine: sourceLine,
                        children: children.map { $0.toItem() })
            }
        }

        // Synthetic root is not included in the returned outline.
        let root = Node(level: 0, id: -1, title: "", sourceLine: 0)
        var stack: [Node] = [root]

        for (index, heading) in headings.enumerated() {
            while let top = stack.last, top.level >= heading.level {
                stack.removeLast()
            }
            let node = Node(level: heading.level, id: index,
                            title: heading.title, sourceLine: heading.sourceLine)
            stack.last?.children.append(node)
            stack.append(node)
        }

        return root.children.map { $0.toItem() }
    }
}
