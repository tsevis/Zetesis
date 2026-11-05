import Foundation

/// The Python engine, copied from the app bundle to Application Support so the LaunchAgent keeps a
/// stable path when the app is moved or updated.
enum EngineInstall {
    struct Missing: LocalizedError {
        let errorDescription: String?
    }

    static let folder = LibraryLocation.supportFolder.appending(path: "Engine", directoryHint: .isDirectory)
    private static let pythonCandidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
    private static let toolPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    /// Copies the bundled engine over the installed one and returns its folder.
    static func prepare() throws -> URL {
        guard let bundled = Bundle.main.url(forResource: "Engine", withExtension: nil) else {
            throw Missing(errorDescription: String(localized: "The indexing engine is missing from the app."))
        }
        let fm = FileManager.default
        try fm.createDirectory(at: LibraryLocation.supportFolder, withIntermediateDirectories: true)
        let staging = LibraryLocation.supportFolder.appending(path: "Engine.new", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: bundled, to: staging)
        if fm.fileExists(atPath: folder.path) {
            _ = try fm.replaceItemAt(folder, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: folder)
        }
        return folder
    }

    /// The first Python 3.10 or later found in the usual places.
    static func python() throws -> URL {
        for path in pythonCandidates where FileManager.default.isExecutableFile(atPath: path) {
            let check = Process()
            check.executableURL = URL(filePath: path)
            check.arguments = ["-c", "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)"]
            check.standardOutput = FileHandle.nullDevice
            check.standardError = FileHandle.nullDevice
            if (try? check.run()) != nil {
                check.waitUntilExit()
                if check.terminationStatus == 0 { return URL(filePath: path) }
            }
        }
        throw Missing(errorDescription: String(localized: "Python 3.10 or later is needed (for example: brew install python)."))
    }

    static func environment(library: URL) -> [String: String] {
        var env = ["PATH": toolPath, "HOME": NSHomeDirectory(), "ZETESIS_LIBRARY": library.path(percentEncoded: false),
                   "PYTHONDONTWRITEBYTECODE": "1", "LANG": "en_US.UTF-8",
                   "ZETESIS_TOPIC_FOLDERS": LibraryLocation.keepsTopicFolders(in: library) ? "1" : "0"]
        // The text-recognition helper built into the app (OCRTool), for scanned books.
        if let ocr = Bundle.main.url(forAuxiliaryExecutable: "zetesis-ocr") {
            env["ZETESIS_OCR"] = ocr.path(percentEncoded: false)
        }
        return env
    }
}
