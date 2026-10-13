import Foundation
import XCTest
@testable import MarkdownHelpers

final class ProjectNavigatorSnapshotTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for path in ["a-folder/child.md", "closed/deep/hidden.md", "nested/deeper/selected.md",
                     "file10.md", "file2.MD", "ignored.png", ".hidden.md"] {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        return root
    }

    @MainActor
    func testDirectoriesFirstNaturalSortAndMarkdownFiltering() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await ProjectNavigatorSnapshot.load(root: root, expanded: [], selected: nil)
        XCTAssertEqual(snapshot.children?.map { $0.url.lastPathComponent },
                       ["a-folder", "closed", "nested", "file2.MD", "file10.md"])
        XCTAssertTrue(snapshot.children!.prefix(3).allSatisfy { $0.children == nil })
    }

    @MainActor
    func testReadsExpandedFoldersButLeavesCollapsedSiblingsUnloaded() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await ProjectNavigatorSnapshot.load(
            root: root, expanded: [root.appendingPathComponent("a-folder")], selected: nil)
        let folder = try XCTUnwrap(snapshot.children?.first { $0.url.lastPathComponent == "a-folder" })
        XCTAssertEqual(folder.children?.map { $0.url.lastPathComponent }, ["child.md"])
        XCTAssertNil(snapshot.children?.first { $0.url.lastPathComponent == "closed" }?.children)
    }

    @MainActor
    func testSelectedFileLoadsOnlyItsAncestorChain() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("nested/deeper/selected.md")
        let snapshot = try await ProjectNavigatorSnapshot.load(root: root, expanded: [], selected: selected)
        let nested = try XCTUnwrap(snapshot.children?.first { $0.url.lastPathComponent == "nested" })
        XCTAssertEqual(nested.children?.first?.children?.first?.url, selected)
        XCTAssertNil(snapshot.children?.first { $0.url.lastPathComponent == "closed" }?.children)
    }

    @MainActor
    func testCancellationDoesNotPublishAnEmptyOrPartialSnapshot() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            return try await ProjectNavigatorSnapshot.load(root: root, expanded: [], selected: nil)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled loads must not replace the displayed tree")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor
    func testRefreshSeesRenamedAndRemovedFiles() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await ProjectNavigatorSnapshot.load(root: root, expanded: [], selected: nil)
        try FileManager.default.moveItem(at: root.appendingPathComponent("file2.MD"),
                                         to: root.appendingPathComponent("renamed.md"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("file10.md"))
        let snapshot = try await ProjectNavigatorSnapshot.load(root: root, expanded: [], selected: nil)
        XCTAssertEqual(snapshot.children?.filter { !$0.isDirectory }.map { $0.url.lastPathComponent }, ["renamed.md"])
    }
}
