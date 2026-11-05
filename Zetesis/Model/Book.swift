import Foundation

/// One book of the library, as the index knows it.
struct Book: Identifiable, Hashable, Sendable {
    let id: Int64
    let key: String
    let title: String
    let author: String
    let topic: String
    let tags: [String]
    /// The topic was guessed by the engine from similar books, not checked by a person.
    let autoTopic: Bool
    /// Book files (PDF, EPUB, …) relative to the library folder.
    let files: [String]
    let markdown: [String]
    /// The folder with the md version and its images, relative to the library folder.
    let folder: String?
    let images: Int
    let pages: Int
    let added: Date

    var mainPDF: String? { files.first { $0.lowercased().hasSuffix(".pdf") } }

    /// The same book filed under another topic, set by hand.
    func with(topic: String) -> Book {
        Book(id: id, key: key, title: title, author: author, topic: topic, tags: tags, autoTopic: false,
             files: files, markdown: markdown, folder: folder, images: images, pages: pages, added: added)
    }
    var mainFile: String? { mainPDF ?? files.first }
}

/// A book with matching pages for the current search.
struct BookHit: Identifiable, Hashable, Sendable {
    let book: Book
    let pages: Int
    let score: Double
    var id: Int64 { book.id }
}

/// One matching page, with the passage around the match.
struct PageHit: Identifiable, Hashable, Sendable {
    /// The page's rowid in the index.
    let id: Int64
    let page: Int
    /// Where the text came from: "pdf", "md", "epub" or "txt".
    let source: String
    let images: [String]
    let snippet: Snippet

    /// PDF and md page numbers are pages of the PDF; EPUB and text numbers are chapters or chunks.
    var isPDFPage: Bool { source == "pdf" || source == "md" }
}

/// Topic names come from the library; the engine's empty name means "not sorted yet".
enum Topic {
    static func displayName(_ name: String) -> String {
        name.isEmpty ? String(localized: "Unsorted") : name
    }
}

struct SearchOutcome: Sendable {
    let text: String
    let query: String
    /// Books whose title, author, topic or tags match.
    let titleMatches: [Book]
    /// Books with matching pages, best first.
    let hits: [BookHit]
    let elapsed: TimeInterval

    var totalPages: Int { hits.reduce(0) { $0 + $1.pages } }
    static let empty = SearchOutcome(text: "", query: "", titleMatches: [], hits: [], elapsed: 0)
}
