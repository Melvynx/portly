import Foundation
@testable import PortlyApp
import XCTest

final class UpdaterRelaunchStateStoreTests: XCTestCase {
    func testConsumeReturnsFreshStateOnlyOnce() throws {
        let url = temporaryURL()
        let date = Date(timeIntervalSince1970: 1_000)
        let store = UpdaterRelaunchStateStore(url: url, now: { date })

        try store.save(serverIDs: ["srv_two", "srv_one"])

        XCTAssertEqual(store.consume(), ["srv_two", "srv_one"])
        XCTAssertNil(store.consume())
    }

    func testConsumeDiscardsExpiredState() throws {
        let url = temporaryURL()
        let createdAt = Date(timeIntervalSince1970: 1_000)
        try UpdaterRelaunchStateStore(url: url, now: { createdAt })
            .save(serverIDs: ["srv_stale"])

        let later = createdAt.addingTimeInterval(301)
        let store = UpdaterRelaunchStateStore(url: url, now: { later })

        XCTAssertNil(store.consume())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testConsumeDiscardsLegacyOrMalformedState() throws {
        let url = temporaryURL()
        try Data(#"{"serverIDs":["srv_legacy"]}"#.utf8).write(to: url)

        XCTAssertNil(UpdaterRelaunchStateStore(url: url).consume())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("portly-updater-state-\(UUID().uuidString).json")
    }
}
