import Foundation
@testable import PortlyApp
import XCTest

final class AnalyticsTests: XCTestCase {
    func testRequestContainsOnlyAllowlistedMetadata() async throws {
        let defaults = makeDefaults()
        let analytics = makeAnalytics(defaults: defaults, recorder: RequestRecorder(statuses: []))

        let request = try await analytics.makeRequest(for: .launched)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        let data = try XCTUnwrap(payload["data"] as? [String: String])

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertEqual(json["type"] as? String, "event")
        XCTAssertEqual(payload["hostname"] as? String, "portly.melvynx.dev")
        XCTAssertEqual(payload["url"] as? String, "/app")
        XCTAssertEqual(payload["website"] as? String, "website-id")
        XCTAssertEqual(payload["name"] as? String, "app-launched")
        XCTAssertEqual(
            data,
            ["version": "9.8.7", "macos": "15.4.0", "architecture": "arm64"]
        )
    }

    func testFirstSeenIsRecordedOnceAfterSuccessfulDelivery() async throws {
        let defaults = makeDefaults()
        let recorder = RequestRecorder(statuses: [204, 204, 204])
        let analytics = makeAnalytics(defaults: defaults, recorder: recorder)

        await analytics.trackLaunch()
        await analytics.trackLaunch()

        let events = try await recorder.eventNames()
        XCTAssertEqual(events, ["app-first-seen", "app-launched", "app-launched"])
    }

    func testConcurrentLaunchesSendFirstSeenOnlyOnce() async throws {
        let defaults = makeDefaults()
        let recorder = RequestRecorder(statuses: [204, 204, 204], delayFirstRequest: true)
        let analytics = makeAnalytics(defaults: defaults, recorder: recorder)

        async let first: Void = analytics.trackLaunch()
        async let second: Void = analytics.trackLaunch()
        _ = await (first, second)

        let events = try await recorder.eventNames()
        XCTAssertEqual(events.filter { $0 == "app-first-seen" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "app-launched" }.count, 2)
    }

    func testTransportFailureRetriesFirstSeenOnNextLaunch() async throws {
        let defaults = makeDefaults()
        let recorder = RequestRecorder(statuses: [204, 204, 204], transportFailures: 1)
        let analytics = makeAnalytics(defaults: defaults, recorder: recorder)

        await analytics.trackLaunch()
        await analytics.trackLaunch()

        let events = try await recorder.eventNames()
        XCTAssertEqual(
            events,
            ["app-first-seen", "app-launched", "app-first-seen", "app-launched"]
        )
    }

    private func makeAnalytics(defaults: UserDefaults, recorder: RequestRecorder) -> PortlyAnalytics {
        PortlyAnalytics(
            endpointURL: URL(string: "https://example.test/api/send")!,
            websiteID: "website-id",
            defaults: defaults,
            sendRequest: { request in try await recorder.send(request) },
            metadata: .init(version: "9.8.7", macOS: "15.4.0", architecture: "arm64")
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "AnalyticsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

private actor RequestRecorder {
    private var statuses: [Int]
    private var transportFailures: Int
    private let delayFirstRequest: Bool
    private var requests: [URLRequest] = []

    init(statuses: [Int], transportFailures: Int = 0, delayFirstRequest: Bool = false) {
        self.statuses = statuses
        self.transportFailures = transportFailures
        self.delayFirstRequest = delayFirstRequest
    }

    func send(_ request: URLRequest) async throws -> HTTPURLResponse {
        requests.append(request)
        if delayFirstRequest, requests.count == 1 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if transportFailures > 0 {
            transportFailures -= 1
            throw URLError(.notConnectedToInternet)
        }
        let status = statuses.isEmpty ? 204 : statuses.removeFirst()
        return HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }

    func eventNames() throws -> [String] {
        try requests.map { request in
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let payload = try XCTUnwrap(json["payload"] as? [String: Any])
            return try XCTUnwrap(payload["name"] as? String)
        }
    }
}
