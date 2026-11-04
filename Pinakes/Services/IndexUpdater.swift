import CoreServices
import Foundation
import Observation

/// Runs the indexing engine (Resources/Engine, Python) and watches the library folder for changes.
@MainActor @Observable
final class IndexUpdater {
    enum Phase: String {
        case idle, waiting, inventory, text, classify, index, topics

        var label: String {
            switch self {
            case .idle: ""
            case .waiting: "Περιμένω να τελειώσει η αντιγραφή…"
            case .inventory: "Καταγραφή βιβλίων…"
            case .text: "Εξαγωγή κειμένου…"
            case .classify: "Ταξινόμηση νέων βιβλίων…"
            case .index: "Ενημέρωση ευρετηρίου…"
            case .topics: "Θεματικοί φάκελοι…"
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var isRunning = false
    private(set) var booksExtracted = 0
    private(set) var lastError: String?
    /// Called on the main actor after every run, whatever it printed: the index may have changed even
    /// when a run failed half-way, and reloading the book list is cheap.
    var onFinish: (() -> Void)?

    /// How long to wait before trying again when another update (the LaunchAgent's) holds the lock.
    static let busyRetry: Duration = .seconds(30)

    private var process: Process?
    private var rerunWanted = false
    private var wasBusy = false
    private var watcher: FolderWatcher?
    private var library: URL?
    private var tools: (engine: URL, python: URL)?

    func start(library: URL) {
        self.library = library
        watcher = FolderWatcher(folder: library) { [weak self] in self?.folderChanged() }
        run(now: true)
    }

    /// Brings the index up to date. `now` skips the engine's wait for copies to settle; `full` rebuilds.
    func run(now: Bool = true, full: Bool = false) {
        guard let library else { return }
        guard !isRunning else {
            rerunWanted = true
            return
        }
        // Set before anything that can spin the run loop, so a folder event cannot start a second run.
        isRunning = true
        booksExtracted = 0
        lastError = nil
        wasBusy = false
        do {
            let tools = try resolvedTools()
            let process = Process()
            process.executableURL = tools.python
            process.arguments = [tools.engine.appending(path: "update.py").path] + (now ? ["--now"] : [])
                + (full ? ["--full"] : [])
            process.currentDirectoryURL = tools.engine
            process.environment = EngineInstall.environment(library: library)
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            let reader = output.fileHandleForReading
            reader.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in self?.consume(text) }
            }
            process.terminationHandler = { [weak self] finished in
                reader.readabilityHandler = nil
                let rest = String(data: reader.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let status = finished.terminationStatus
                Task { @MainActor in
                    self?.consume(rest)
                    self?.finished(status: status)
                }
            }
            try process.run()
            self.process = process
        } catch {
            isRunning = false
            lastError = error.localizedDescription
        }
    }

    /// The engine is copied and Python located once per launch.
    private func resolvedTools() throws -> (engine: URL, python: URL) {
        if let tools { return tools }
        let resolved = (engine: try EngineInstall.prepare(), python: try EngineInstall.python())
        tools = resolved
        return resolved
    }

    private func consume(_ text: String) {
        guard isRunning else { return }
        for line in text.split(separator: "\n") {
            if line.hasPrefix("@phase "), let p = Phase(rawValue: String(line.dropFirst(7))) {
                phase = p
            } else if line == "@busy" {
                wasBusy = true
            } else if line.hasPrefix("κείμενο:") {
                booksExtracted += 1
            }
        }
    }

    private func finished(status: Int32) {
        isRunning = false
        phase = .idle
        process = nil
        if status != 0 {
            lastError = "Η ενημέρωση απέτυχε (κωδικός \(status)). Λεπτομέρειες: \(LibraryLocation.log.path)"
        }
        onFinish?()
        if rerunWanted {
            rerunWanted = false
            run(now: false)
        } else if wasBusy {
            Task { [weak self] in
                try? await Task.sleep(for: Self.busyRetry)
                self?.run(now: true)
            }
        }
    }

    private func folderChanged() {
        // The engine itself waits until the folder has been quiet for a while before indexing.
        run(now: false)
    }
}

/// Watches a folder tree with FSEvents, ignoring the engine's own folders.
final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let onChange: @MainActor () -> Void
    private static let ignored = ["/_SEARCH/", "/_ΘΕΜΑΤΑ/", "/.DS_Store"]
    private static let latency: CFTimeInterval = 5

    init(folder: URL, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let relevant = list.prefix(count).contains { path in !FolderWatcher.ignored.contains { path.contains($0) } }
            if relevant { MainActor.assumeIsolated { watcher.onChange() } }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
