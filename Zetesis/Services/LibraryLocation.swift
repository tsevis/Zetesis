import Foundation

/// Where things are: the library folder the user chose, and the index the engine keeps for it.
enum LibraryLocation {
    static let supportFolder = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Zetesis", directoryHint: .isDirectory)
    static let log = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Zetesis.log")
    private static let libraryKey = "libraryPath"
    private static let topicFoldersKey = "topicFolders"
    /// Folder names the engine uses for topic symlinks inside a library (Engine/config.py).
    static let topicFolderNames = ["_ΘΕΜΑΤΑ", "_Topics"]

    static var library: URL? {
        get { UserDefaults.standard.string(forKey: libraryKey).map { URL(filePath: $0, directoryHint: .isDirectory) } }
        set { UserDefaults.standard.set(newValue?.path(percentEncoded: false), forKey: libraryKey) }
    }

    /// Whether the engine keeps a folder of topic symlinks inside the library. Until the user says,
    /// it does so only where such a folder is already there.
    static func keepsTopicFolders(in library: URL) -> Bool {
        if let chosen = UserDefaults.standard.object(forKey: topicFoldersKey) as? Bool { return chosen }
        return topicFolderNames.contains { FileManager.default.fileExists(atPath: library.appending(path: $0).path) }
    }

    static func setKeepsTopicFolders(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: topicFoldersKey)
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
