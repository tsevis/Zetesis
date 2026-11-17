/// Words and meaning in one ranking: reciprocal rank fusion (Cormack, Clarke and Büttcher, 2009).
/// Each list adds 1 / (k + rank) to a book, so a book that both lists rank high comes first and a book
/// that only one finds still appears. The two lists' own scores, on different scales, are never mixed.
enum Fusion {
    static let k = 60.0

    /// A book with the words keeps their page count and passages; ties go to the books with the words.
    static func blend(words: SearchOutcome, meaning: SearchOutcome) -> SearchOutcome {
        let wordRank = Dictionary(uniqueKeysWithValues: words.hits.enumerated().map { ($1.book.id, $0 + 1) })
        let meaningRank = Dictionary(uniqueKeysWithValues: meaning.hits.enumerated().map { ($1.book.id, $0 + 1) })
        let found = words.hits + meaning.hits.filter { wordRank[$0.book.id] == nil }
        let hits = found.map { hit in
            let score = [wordRank[hit.book.id], meaningRank[hit.book.id]].compactMap { $0 }
                .reduce(0.0) { $0 + 1 / (k + Double($1)) }
            return BookHit(book: hit.book, pages: hit.pages, score: score, matchesWords: hit.matchesWords)
        }.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.matchesWords != b.matchesWords { return a.matchesWords }
            return (wordRank[a.book.id] ?? .max, meaningRank[a.book.id] ?? .max)
                < (wordRank[b.book.id] ?? .max, meaningRank[b.book.id] ?? .max)
        }
        // A text with nothing to search by words gives an empty word outcome: the text comes from meaning.
        return SearchOutcome(text: meaning.text, query: words.query, titleMatches: words.titleMatches, hits: hits,
                             elapsed: words.elapsed + meaning.elapsed, meaningPages: meaning.meaningPages)
    }
}
