import XCTest
@testable import MarkdownHelpers

final class OpenPanelPrewarmingTests: XCTestCase {
    private final class Reader {
        var ready = false
    }

    @MainActor
    func testTakesSameReaderWithoutWaitingForReadinessAndDoesNotReplenish() {
        var creations = 0
        let cache = OpenPanelPrewarming(settings: { 1 }) {
            creations += 1
            return Reader()
        }
        let panel = cache.begin()
        let reader = cache.take()
        XCTAssertFalse(reader.ready)
        XCTAssertEqual(creations, 1)
        // New Document consumes the view while the picker is still open and
        // then closes that picker with a cancel response.
        cache.finish(panel, accepted: false)
        XCTAssertFalse(reader.ready)
        XCTAssertFalse(cache.take() === reader)
        XCTAssertEqual(creations, 2)
    }

    @MainActor
    func testCancelReleasesTheUnusedReader() {
        weak var spare: Reader?
        let cache = OpenPanelPrewarming(settings: { 1 }) {
            let reader = Reader()
            spare = reader
            return reader
        }
        let panel = cache.begin()
        XCTAssertNotNil(spare)
        cache.finish(panel, accepted: false)
        XCTAssertNil(spare)
    }

    @MainActor
    func testSettingChangeReplacesPreparedReader() {
        var settings = 1
        weak var spare: Reader?
        var creations = 0
        let cache = OpenPanelPrewarming(settings: { settings }) {
            creations += 1
            let reader = Reader()
            spare = reader
            return reader
        }
        cache.begin()
        let oldReader = spare
        settings = 2
        let reader = cache.take()
        XCTAssertFalse(reader === oldReader)
        XCTAssertEqual(creations, 2)
    }

    @MainActor
    func testFinishingAnOlderPanelDoesNotDiscardTheCurrentSpare() {
        weak var spare: Reader?
        let cache = OpenPanelPrewarming(settings: { 1 }) {
            let reader = Reader()
            spare = reader
            return reader
        }
        let oldPanel = cache.begin()
        let newPanel = cache.begin()
        cache.finish(oldPanel, accepted: false)
        XCTAssertNotNil(spare)
        cache.finish(newPanel, accepted: false)
        XCTAssertNil(spare)
    }

    @MainActor
    func testAcceptedPanelKeepsReaderForDocumentConstructionThenExpiresUnusedReader() async throws {
        weak var spare: Reader?
        let cache = OpenPanelPrewarming(retentionAfterSelection: 0.02, settings: { 1 }) {
            let reader = Reader()
            spare = reader
            return reader
        }
        let panel = cache.begin()
        cache.finish(panel, accepted: true)
        XCTAssertNotNil(spare)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(spare)
    }

    @MainActor
    func testReopeningPickerCancelsOldExpiryAndKeepsOnlyOneReader() async throws {
        var creations = 0
        weak var spare: Reader?
        let cache = OpenPanelPrewarming(retentionAfterSelection: 0.02, settings: { 1 }) {
            creations += 1
            let reader = Reader()
            spare = reader
            return reader
        }
        let oldPanel = cache.begin()
        cache.finish(oldPanel, accepted: true)
        let newPanel = cache.begin()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(spare)
        XCTAssertEqual(creations, 1)
        cache.finish(newPanel, accepted: false)
        XCTAssertNil(spare)
    }
}
