import Foundation
import Network
import PortlyCore

/// Liveness probing. TCP connect by default (works for anything that binds a
/// port, including Convex and websocket-only servers). An optional HTTP check
/// catches the case where the port is bound but the app is broken.
enum HealthChecker {
    /// Connect to localhost with a hard timeout. Resolving localhost matters:
    /// recent Vite versions may bind only to ::1 while other servers use IPv4.
    static func tcpReachable(port: Int, timeout: TimeInterval = 2.0) -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }

        let connection = NWConnection(host: "localhost", port: endpointPort, using: .tcp)
        let semaphore = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "dev.portly.health-check")
        var reachable = false
        var finished = false

        connection.stateUpdateHandler = { state in
            guard !finished else { return }
            switch state {
            case .ready:
                reachable = true
                finished = true
                semaphore.signal()
            case .failed:
                finished = true
                semaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + timeout)
        connection.cancel()
        return reachable
    }

    /// Resolves the configured health URL against the port when it is a bare path.
    static func resolvedHealthURL(for server: ServerConfig) -> URL? {
        guard let raw = server.healthURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return URL(string: raw) }
        guard let port = server.port else { return nil }
        let path = raw.hasPrefix("/") ? raw : "/" + raw
        return URL(string: "http://localhost:\(port)\(path)")
    }

    static func httpHealthy(url: URL, expected: Int?, timeout: TimeInterval = 5.0, completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        URLSession(configuration: config).dataTask(with: request) { _, response, error in
            guard error == nil, let http = response as? HTTPURLResponse else {
                completion(false)
                return
            }
            if let expected {
                completion(http.statusCode == expected)
            } else {
                completion((200..<400).contains(http.statusCode))
            }
        }.resume()
    }

    /// Full check for one server, on a background queue.
    static func check(server: ServerConfig, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            if let port = server.port {
                guard tcpReachable(port: port) else {
                    completion(false)
                    return
                }
            }
            if let url = resolvedHealthURL(for: server) {
                httpHealthy(url: url, expected: server.healthStatus, completion: completion)
            } else {
                // No port and no health URL: nothing to probe, trust the process.
                completion(true)
            }
        }
    }
}
