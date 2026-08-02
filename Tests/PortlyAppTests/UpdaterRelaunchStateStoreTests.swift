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

    func testConsumeAcceptsFreshLegacyState() throws {
        let url = temporaryURL()
        try Data(#"{"serverIDs":["srv_legacy"]}"#.utf8).write(to: url)

        XCTAssertEqual(UpdaterRelaunchStateStore(url: url).consume(), ["srv_legacy"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testConsumeDiscardsExpiredLegacyState() throws {
        let url = temporaryURL()
        let modifiedAt = Date(timeIntervalSince1970: 1_000)
        try Data(#"{"serverIDs":["srv_stale"]}"#.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)

        let later = modifiedAt.addingTimeInterval(301)
        XCTAssertNil(UpdaterRelaunchStateStore(url: url, now: { later }).consume())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testConsumeDiscardsMalformedState() throws {
        let url = temporaryURL()
        try Data("not-json".utf8).write(to: url)

        XCTAssertNil(UpdaterRelaunchStateStore(url: url).consume())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("portly-updater-state-\(UUID().uuidString).json")
    }
}
