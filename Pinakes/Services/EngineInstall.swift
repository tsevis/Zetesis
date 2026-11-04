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
            throw Missing(errorDescription: "Η μηχανή ευρετηρίου λείπει από την εφαρμογή.")
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
        throw Missing(errorDescription: "Χρειάζεται Python 3.10 ή νεότερη (π.χ. brew install python).")
    }

    static func environment(library: URL) -> [String: String] {
        ["PATH": toolPath, "HOME": NSHomeDirectory(), "PINAKES_LIBRARY": library.path(percentEncoded: false),
         "PYTHONDONTWRITEBYTECODE": "1", "LANG": "el_GR.UTF-8"]
    }
}
