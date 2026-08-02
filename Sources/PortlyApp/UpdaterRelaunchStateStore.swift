import Foundation

struct UpdaterRelaunchStateStore {
    private struct State: Codable {
        let serverIDs: [String]
        let createdAt: Date
    }

    private struct LegacyState: Codable {
        let serverIDs: [String]
    }

    let url: URL
    var now: () -> Date = Date.init

    func save(serverIDs: [String]) throws {
        let data = try JSONEncoder().encode(State(serverIDs: serverIDs, createdAt: now()))
        try data.write(to: url, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    func consume(maxAge: TimeInterval = 300) -> [String]? {
        let claimedURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).consumed-\(UUID().uuidString)")
        guard (try? FileManager.default.moveItem(at: url, to: claimedURL)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: claimedURL) }

        guard let data = try? Data(contentsOf: claimedURL) else { return nil }

        let serverIDs: [String]
        let createdAt: Date
        if let state = try? JSONDecoder().decode(State.self, from: data) {
            serverIDs = state.serverIDs
            createdAt = state.createdAt
        } else if let state = try? JSONDecoder().decode(LegacyState.self, from: data),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: claimedURL.path),
                  let modifiedAt = attributes[.modificationDate] as? Date
        {
            serverIDs = state.serverIDs
            createdAt = modifiedAt
        } else {
            return nil
        }

        let age = now().timeIntervalSince(createdAt)
        guard (0...maxAge).contains(age), !serverIDs.isEmpty else { return nil }
        return serverIDs
    }
}
