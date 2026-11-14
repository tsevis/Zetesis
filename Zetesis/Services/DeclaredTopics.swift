import Foundation

/// Topics made by hand in the sidebar, kept per library. The engine learns of a topic only when a
/// book is filed under it (topics.json), so the empty ones are remembered here.
enum DeclaredTopics {
    private static let key = "declaredTopics"

    static func load(for library: URL) -> [String] {
        all()[id(of: library)] ?? []
    }

    static func save(_ topics: [String], for library: URL) {
        let merged = all().merging([id(of: library): topics]) { _, new in new }
        UserDefaults.standard.set(merged, forKey: key)
    }

    private static func all() -> [String: [String]] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
    }

    private static func id(of library: URL) -> String {
        library.standardizedFileURL.path(percentEncoded: false)
    }
}
