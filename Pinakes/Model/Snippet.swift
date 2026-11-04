import Foundation

/// A passage with its matched words marked, parsed from FTS5 snippet() output.
struct Snippet: Hashable, Sendable {
    struct Part: Hashable, Sendable {
        let text: String
        let isMatch: Bool
    }

    static let open: Character = "\u{02}"
    static let close: Character = "\u{03}"

    let parts: [Part]

    init(marked: String) {
        var parts: [Part] = []
        var current = ""
        var inMatch = false
        for ch in marked {
            if ch == Self.open || ch == Self.close {
                if !current.isEmpty { parts.append(Part(text: current, isMatch: inMatch)) }
                current = ""
                inMatch = ch == Self.open
            } else {
                current.append(ch == "\n" || ch == "\t" ? " " : ch)
            }
        }
        if !current.isEmpty { parts.append(Part(text: current, isMatch: inMatch)) }
        self.parts = parts
    }

    var plain: String { parts.map(\.text).joined() }
}
