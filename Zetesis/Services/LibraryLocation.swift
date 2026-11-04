import Foundation

/// Where things are: the library folder the user chose, and the index the engine keeps for it.
enum LibraryLocation {
    static let supportFolder = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Zetesis", directoryHint: .isDirectory)
    static let log = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Zetesis.log")
    private static let libraryKey = "libraryPath"

    static var library: URL? {
        get { UserDefaults.standard.string(forKey: libraryKey).map { URL(filePath: $0, directoryHint: .isDirectory) } }
        set { UserDefaults.standard.set(newValue?.path(percentEncoded: false), forKey: libraryKey) }
    }

    /// The index in use for `library`, found through the pointer file the engine writes next to it
    /// (Engine/config.py, POINTER), so the app never has to agree with Python on how paths hash.
    static func index(for library: URL) -> URL? {
        let wanted = normalized(library)
        let pointers = (try? FileManager.default.contentsOfDirectory(at: supportFolder, includingPropertiesForKeys: nil))
            ?? []
        for pointer in pointers where pointer.pathExtension == "json" {
            guard let data = try? Data(contentsOf: pointer),
                  let info = try? JSONDecoder().decode(Pointer.self, from: data),
                  normalized(URL(filePath: info.library)) == wanted else { continue }
            let db = supportFolder.appending(path: info.db)
            return FileManager.default.fileExists(atPath: db.path) ? db : nil
        }
        return nil
    }

    static func url(_ relative: String, in library: URL) -> URL {
        library.appending(path: relative)
    }

    private static func normalized(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private struct Pointer: Decodable {
        let db: String
        let library: String
    }
}
