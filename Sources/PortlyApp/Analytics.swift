import Foundation
import PortlyCore

actor PortlyAnalytics {
    static let shared = PortlyAnalytics()

    enum Event: String {
        case firstSeen = "app-first-seen"
        case launched = "app-launched"
    }

    struct Metadata: Equatable {
        let version: String
        let macOS: String
        let architecture: String
    }

    private struct RequestBody: Encodable {
        let type = "event"
        let payload: Payload
    }

    private struct Payload: Encodable {
        let hostname: String
        let url: String
        let website: String
        let name: String
        let data: [String: String]
    }

    private static let endpoint = URL(string: "https://analytics.melvynx.dev/api/send")!
    private static let websiteID = "f643140d-b584-4501-aa0c-6d97e7673fe3"
    private static let hostname = "portly.melvynx.dev"
    private static let firstSeenRecordedKey = "analytics.first-seen-recorded"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Portly Safari/605.1.15"

    private let endpointURL: URL
    private let websiteID: String
    private let defaults: UserDefaults
    private let sendRequest: @Sendable (URLRequest) async throws -> HTTPURLResponse
    private let metadata: Metadata
    private var firstSeenDeliveryInFlight = false

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)

        self.endpointURL = Self.endpoint
        self.websiteID = Self.websiteID
        self.defaults = .standard
        self.sendRequest = { request in
            let (_, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            return response
        }
        self.metadata = Self.currentMetadata
    }

    init(
        endpointURL: URL,
        websiteID: String,
        defaults: UserDefaults,
        sendRequest: @escaping @Sendable (URLRequest) async throws -> HTTPURLResponse,
        metadata: Metadata
    ) {
        self.endpointURL = endpointURL
        self.websiteID = websiteID
        self.defaults = defaults
        self.sendRequest = sendRequest
        self.metadata = metadata
    }

    func trackLaunch() async {
        if !defaults.bool(forKey: Self.firstSeenRecordedKey), !firstSeenDeliveryInFlight {
            firstSeenDeliveryInFlight = true
            let delivered = await send(.firstSeen)
            if delivered {
                defaults.set(true, forKey: Self.firstSeenRecordedKey)
            }
            firstSeenDeliveryInFlight = false
        }

        _ = await send(.launched)
    }

    func makeRequest(for event: Event) throws -> URLRequest {
        let body = RequestBody(
            payload: Payload(
                hostname: Self.hostname,
                url: "/app",
                website: websiteID,
                name: event.rawValue,
                data: [
                    "version": metadata.version,
                    "macos": metadata.macOS,
                    "architecture": metadata.architecture,
                ]
            )
        )

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func send(_ event: Event) async -> Bool {
        do {
            let request = try makeRequest(for: event)
            let response = try await sendRequest(request)
            return (200..<300).contains(response.statusCode)
        } catch {
            return false
        }
    }

    private static var currentMetadata: Metadata {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return Metadata(
            version: portlyVersion,
            macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            architecture: architecture
        )
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "other"
        #endif
    }
}
