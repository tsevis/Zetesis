import XCTest

/// Word scores (BM25) and meaning scores (cosine) are on different scales: a blend that compares them,
/// or simply lists one search before the other, buries the books both searches agree on.
final class FusionTests: XCTestCase {
    private func book(_ id: Int64) -> Book {
        Book(id: id, key: "\(id)", title: "\(id)", author: "", topic: "", tags: [], autoTopic: false, files: [],
             markdown: [], folder: nil, images: 0, pages: 100, added: .distantPast)
    }

    private func outcome(_ hits: [BookHit], query: String, meaning: [Int64: [Int64]]?) -> SearchOutcome {
        SearchOutcome(text: "q", query: query, titleMatches: [], hits: hits, elapsed: 0, meaningPages: meaning)
    }

    func testBooksBothSearchesFindComeFirstAndWordMatchesWinTies() {
        let words = outcome([BookHit(book: book(1), pages: 5, score: 9, matchesWords: true),
                             BookHit(book: book(2), pages: 3, score: 4, matchesWords: true)],
                            query: "acanthus", meaning: nil)
        let meaning = outcome([BookHit(book: book(3), pages: 2, score: 0.9, matchesWords: false),
                               BookHit(book: book(2), pages: 4, score: 0.8, matchesWords: false),
                               BookHit(book: book(4), pages: 1, score: 0.7, matchesWords: false)],
                              query: "", meaning: [3: [30], 2: [20], 4: [40]])
        let blended = Fusion.blend(words: words, meaning: meaning)
        XCTAssertEqual(blended.hits.map(\.book.id), [2, 1, 3, 4])
        XCTAssertEqual(blended.hits.map(\.matchesWords), [true, true, false, false])
        XCTAssertEqual(blended.hits.map(\.pages), [3, 5, 2, 1])
        XCTAssertEqual(blended.query, "acanthus")
        XCTAssertEqual(blended.meaningPages?[4], [40])
    }
}
