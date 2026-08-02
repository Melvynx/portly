import Foundation

struct PortlyStatusEnvelope: Decodable {
    let ok: Bool
    let data: PortlyServiceStatus
}

struct PortlyServiceStatus: Decodable {
    let projects: [CompanionProject]
}

struct CompanionProject: Decodable, Identifiable {
    let id: String
    let name: String
    let color: String
    let servers: [CompanionServer]
}

struct CompanionServer: Decodable, Identifiable {
    let id: String
    let name: String
    let port: Int?
    let state: String
    let healthy: Bool
    let pid: Int?
    let cpuPercent: Double?
    let memoryBytes: UInt64?
    let residentMemoryBytes: UInt64?
    let processCount: Int?

    var isRunning: Bool {
        state == "running" || state == "starting" || state == "unhealthy"
    }
}

private struct PortlyActionTarget: Encodable {
    let server: String
}

enum PortlyServiceError: LocalizedError {
    case invalidResponse
    case serviceRejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Portly returned an invalid response."
        case .serviceRejected(let message):
            return message
        }
    }
}

enum PortlyServiceClient {
    static let serviceURL = URL(string: "http://127.0.0.1:7737")!

    static func status() async throws -> PortlyServiceStatus {
        let (data, response) = try await URLSession.shared.data(from: serviceURL.appendingPathComponent("status"))
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw PortlyServiceError.invalidResponse
        }
        let envelope = try JSONDecoder().decode(PortlyStatusEnvelope.self, from: data)
        guard envelope.ok else { throw PortlyServiceError.serviceRejected("Portly rejected the status request.") }
        return envelope.data
    }

    static func perform(_ action: String, serverID: String) async throws {
        var request = URLRequest(url: serviceURL.appendingPathComponent(action))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PortlyActionTarget(server: serverID))

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw PortlyServiceError.serviceRejected("Portly could not \(action.dropFirst()) this server.")
        }
    }
}
