import Foundation

/// Changes a book's topic through the engine (Engine/set_topic.py), which waits for any update in
/// progress, so the app and the engine never write topics.json at the same time.
enum TopicEditor {
    static func set(topic: String, key: String, library: URL) async throws {
        let engine = try EngineInstall.prepare()
        let python = try EngineInstall.python()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = python
            process.arguments = [engine.appending(path: "set_topic.py").path, key, topic]
            process.environment = EngineInstall.environment(library: library)
            process.currentDirectoryURL = engine
            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: EngineInstall.Missing(
                        errorDescription: String(localized: "The topic was not changed (code \(finished.terminationStatus)).")))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}
