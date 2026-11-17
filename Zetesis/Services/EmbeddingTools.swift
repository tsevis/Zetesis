import Foundation

/// What search by meaning needs: llama.cpp's llama-server and the bge-m3 model (GGUF). Both are looked
/// for in the usual places and never downloaded; the engine gets their paths from the app.
enum EmbeddingTools {
    struct Found: Sendable, Equatable {
        let server: URL
        let model: URL
    }

    static let installCommand = "brew install llama.cpp"
    static let downloadCommand = "hf download ggml-org/bge-m3-Q8_0-GGUF bge-m3-q8_0.gguf"
    private static let modelFile = "bge-m3-q8_0.gguf"
    private static let preparedKey = "preparesSearchByMeaning"
    private static let modeKey = "searchesByMeaning"
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let serverCandidates = [
        home.appending(path: ".local/bin/llama-server").path, "/opt/homebrew/bin/llama-server",
        "/usr/local/bin/llama-server",
    ]

    /// Settings: the engine describes every page (hours, once, for a large library).
    static var isPrepared: Bool {
        get { UserDefaults.standard.bool(forKey: preparedKey) }
        set { UserDefaults.standard.set(newValue, forKey: preparedKey) }
    }

    /// The search field: by meaning rather than by words.
    static var searchesByMeaning: Bool {
        get { UserDefaults.standard.bool(forKey: modeKey) }
        set { UserDefaults.standard.set(newValue, forKey: modeKey) }
    }

    static func find() -> Found? {
        let fm = FileManager.default
        guard let server = serverCandidates.first(where: fm.isExecutableFile(atPath:)),
              let model = modelCandidates().first(where: { fm.fileExists(atPath: $0.path) })
        else { return nil }
        return Found(server: URL(filePath: server), model: model)
    }

    /// Zetesis' own folder first, then the caches of Hugging Face's `hf` and of llama.cpp.
    private static func modelCandidates() -> [URL] {
        let fm = FileManager.default
        let own = LibraryLocation.supportFolder.appending(path: "Models/\(modelFile)")
        let snapshots = home.appending(path: ".cache/huggingface/hub/models--ggml-org--bge-m3-Q8_0-GGUF/snapshots")
        let hub = ((try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appending(path: modelFile) }
        let llamaCache = home.appending(path: "Library/Caches/llama.cpp")
        let cached = ((try? fm.contentsOfDirectory(at: llamaCache, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(modelFile) }
        return [own] + hub + cached
    }
}
