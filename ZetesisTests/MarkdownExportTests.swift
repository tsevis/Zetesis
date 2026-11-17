import XCTest

/// A book found only by meaning has no page with the words: an export that counts its nearest pages as
/// "pages with matches" tells the reader the words are there when they are not.
@MainActor
final class MarkdownExportTests: XCTestCase {
    private func book(_ id: Int64) -> Book {
        Book(id: id, key: "\(id)", title: "Book \(id)", author: "", topic: "", tags: [], autoTopic: false, files: [],
             markdown: [], folder: nil, images: 0, pages: 100, added: .distantPast)
    }

    func testBooksFoundOnlyByMeaningAreNotCountedAsMatches() async throws {
        let hits = [BookHit(book: book(1), pages: 5, score: 2, matchesWords: true),
                    BookHit(book: book(2), pages: 3, score: 1, matchesWords: false)]
        let outcome = SearchOutcome(text: "q", query: "q", titleMatches: [], hits: hits, elapsed: 0,
                                    meaningPages: [2: [10, 11, 12]])
        let text = try await MarkdownExport.build(outcome: outcome, hits: hits, titleMatches: [], scope: nil,
                                                  library: URL(filePath: "/tmp/library")) { _ in [] }
        XCTAssertTrue(text.contains("Books with matches: 1 · matching pages: 5"), text)
        XCTAssertTrue(text.contains("Found by meaning only: 1"), text)
        XCTAssertTrue(text.contains("**Pages with matches:** 5"), text)
        XCTAssertTrue(text.contains("**Nearest pages by meaning:** 3"), text)
    }
}
