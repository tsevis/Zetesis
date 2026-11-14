import Foundation

/// The sidebar's topics: those the books have, and those made by hand that have no book yet.
enum TopicList {
    typealias Entry = (name: String, count: Int)

    /// Topics with the most books first, then by name; the empty ones made by hand come last.
    static func entries(bookTopics: [String], declared: [String]) -> [Entry] {
        let empty = Dictionary(declared.map { ($0, 0) }, uniquingKeysWith: { first, _ in first })
        let counts = bookTopics.reduce(into: empty) { counts, topic in counts[topic, default: 0] += 1 }
        return counts.map { (name: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }

    /// The name as it is stored, or nil when nothing but spaces was typed.
    static func cleaned(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The topic in `names` that `name` spells again, ignoring case, accents and outer spaces.
    static func existing(_ name: String, in names: [String]) -> String? {
        guard let wanted = cleaned(name) else { return nil }
        return names.first {
            $0.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }
}
