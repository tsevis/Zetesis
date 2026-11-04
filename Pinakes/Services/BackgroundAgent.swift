import Foundation

/// The LaunchAgent that keeps the index current while the app is closed (Engine/install_watcher.py).
enum BackgroundAgent {
    private static let agents = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents")

    static var isInstalled: Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: agents.path)) ?? []
        return names.contains { $0.hasPrefix("com.tsevis.pinakes.update.") }
    }

    static func set(_ on: Bool, library: URL) async throws {
        let engine = try EngineInstall.prepare()
        let python = try EngineInstall.python()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = python
            process.arguments = [engine.appending(path: "install_watcher.py").path] + (on ? [] : ["--remove"])
            process.environment = EngineInstall.environment(library: library)
            process.currentDirectoryURL = engine
            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: EngineInstall.Missing(
                        errorDescription: "Η αυτόματη ενημέρωση δεν άλλαξε (κωδικός \(finished.terminationStatus))."))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}
