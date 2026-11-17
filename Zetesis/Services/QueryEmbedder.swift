import Foundation

/// Turns a query into a bge-m3 vector. Runs its own llama-server on 127.0.0.1, behind a random key,
/// started at the first search by meaning and stopped after a while without one, or when the app quits.
actor QueryEmbedder {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static let idleStop: Duration = .seconds(600)
    static let startTimeout: Duration = .seconds(60)
    /// Tokens per request: a query longer than the physical batch is refused by llama-server.
    private static let context = "8192"
    /// Names the server so one left by a crashed Zetesis (its parent is then launchd) can be stopped.
    private static let alias = "zetesis-query"
    private static let poll: Duration = .milliseconds(250)

    private let running = RunningServer()
    /// The start in progress. Every caller awaits the same one, so a search typed while the model
    /// loads neither starts a second server nor talks to one that is not ready.
    private var starting: (tools: EmbeddingTools.Found, task: Task<RunningServer.Server, Error>)?
    private var idleTask: Task<Void, Never>?

    /// The query's vector, of unit length.
    func embed(_ text: String, with tools: EmbeddingTools.Found) async throws -> [Float] {
        let server = try await start(tools)
        armIdleStop()
        var request = URLRequest(url: server.url(path: "v1/embeddings"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(server.key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["input": [text]])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let vector = try JSONDecoder().decode(Reply.self, from: data).data.first?.embedding,
              vector.count == VectorSearch.dims
        else { throw Failure(errorDescription: String(localized: "Search by meaning got no answer from llama-server.")) }
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? vector.map { $0 / norm } : vector
    }

    /// Stops the server at once; safe from any thread (the app's quit notification).
    nonisolated func stop() { running.stop() }

    /// Stops a server left running by a Zetesis that crashed or was killed.
    nonisolated static func stopOrphans() {
        let pkill = Process()
        pkill.executableURL = URL(filePath: "/usr/bin/pkill")
        pkill.arguments = ["-P", "1", "-f", "alias \(alias)"]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        try? pkill.run()
        pkill.waitUntilExit()
    }

    private func start(_ tools: EmbeddingTools.Found) async throws -> RunningServer.Server {
        if let server = running.current, server.tools == tools { return server }
        if let starting, starting.tools == tools { return try await starting.task.value }
        running.stop()
        let task = Task { [running] in try await Self.launch(tools, into: running) }
        starting = (tools, task)
        defer { if starting?.task == task { starting = nil } }
        let server = try await task.value
        armIdleStop()
        return server
    }

    private func armIdleStop() {
        idleTask?.cancel()
        idleTask = Task { [running] in
            try? await Task.sleep(for: Self.idleStop)
            if !Task.isCancelled { running.stop() }
        }
    }

    /// Starts llama-server and registers it once it answers /health.
    private static func launch(_ tools: EmbeddingTools.Found, into running: RunningServer) async throws -> RunningServer.Server {
        stopOrphans()
        let port = try FreePort.find()
        let key = UUID().uuidString
        let process = Process()
        process.executableURL = tools.server
        process.arguments = ["-m", tools.model.path(percentEncoded: false), "--embedding", "--pooling", "cls",
                             "--host", "127.0.0.1", "--port", String(port), "--api-key", key,
                             "-c", context, "-b", context, "-ub", context, "-ngl", "99", "--alias", alias]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let server = RunningServer.Server(process: process, port: port, key: key, tools: tools)
        let clock = ContinuousClock()
        let deadline = clock.now + startTimeout
        while clock.now < deadline, process.isRunning {
            if let (_, response) = try? await URLSession.shared.data(from: server.url(path: "health")),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                running.set(server)
                return server
            }
            try? await Task.sleep(for: poll)
        }
        if process.isRunning { process.terminate() }
        throw Failure(errorDescription: String(localized: "Search by meaning could not start llama-server."))
    }

    private struct Reply: Decodable {
        struct Item: Decodable { let embedding: [Float] }
        let data: [Item]
    }
}

/// The server process, behind a lock so the app's quit notification can stop it synchronously.
final class RunningServer: @unchecked Sendable {
    struct Server: @unchecked Sendable {
        let process: Process
        let port: Int
        let key: String
        let tools: EmbeddingTools.Found

        func url(path: String) -> URL {
            var parts = URLComponents()
            parts.scheme = "http"
            parts.host = "127.0.0.1"
            parts.port = port
            parts.path = "/" + path
            return parts.url ?? URL(filePath: "/")
        }
    }

    private let lock = NSLock()
    private var server: Server?

    var current: Server? { lock.withLock { server?.process.isRunning == true ? server : nil } }

    /// Registers a new server, stopping the one it replaces.
    func set(_ new: Server) {
        let old = lock.withLock { () -> Server? in
            defer { server = new }
            return server
        }
        if let process = old?.process, process.isRunning, process !== new.process { process.terminate() }
    }

    func stop() {
        let old = lock.withLock { () -> Server? in
            defer { server = nil }
            return server
        }
        if let process = old?.process, process.isRunning { process.terminate() }
    }
}

/// A TCP port on 127.0.0.1 that nothing listens on at the moment.
enum FreePort {
    static func find() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw QueryEmbedder.Failure(errorDescription: String(localized: "No free port for llama-server.")) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw QueryEmbedder.Failure(errorDescription: String(localized: "No free port for llama-server.")) }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
