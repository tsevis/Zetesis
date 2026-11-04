import Foundation

/// Queries the index. Ranking runs on its own connection and queue so a new keystroke can interrupt
/// it; snippets, page lists and page text use a second one, so result rows fill in while a search runs.
final class SearchEngine: Sendable {
    static let titleMatchLimit = 200
    static let bookPageHitLimit = 1000
    private static let snippetTokens = 22

    let databaseURL: URL
    private let ranker: SQLiteConnection
    private let reader: SQLiteConnection
    private let rankQueue = DispatchQueue(label: "zetesis.rank", qos: .userInitiated)
    private let readQueue = DispatchQueue(label: "zetesis.read", qos: .userInitiated)

    init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        ranker = try SQLiteConnection(readOnly: databaseURL)
        reader = try SQLiteConnection(readOnly: databaseURL)
    }

    /// Stops the ranking query in progress, if any.
    func interruptSearch() { ranker.interrupt() }

    func loadBooks() async throws -> [Book] {
        try await run(on: readQueue) { [reader] in
            var books: [Book] = []
            try reader.query("SELECT id, key, title, author, topic, tags, auto_topic, files, md, folder, images, "
                             + "pages, added FROM books") { r in
                books.append(Book(id: r.int(0), key: r.text(1), title: r.text(2), author: r.text(3),
                                  topic: r.text(4), tags: Self.tags(r.text(5)), autoTopic: r.int(6) != 0,
                                  files: Self.strings(r.text(7)), markdown: Self.strings(r.text(8)),
                                  folder: r.optionalText(9), images: Int(r.int(10)), pages: Int(r.int(11)),
                                  added: Date(timeIntervalSince1970: r.double(12))))
            }
            return books
        }
    }

    func lastUpdated() async -> Date? {
        try? await run(on: readQueue) { [reader] in
            guard case .double(let t) = try reader.scalar("SELECT value FROM info WHERE name = 'updated'") else {
                return nil
            }
            return Date(timeIntervalSince1970: t)
        }
    }

    /// Every book with a matching page, ranked (see Ranking), plus the books whose metadata matches.
    func search(_ text: String, books: [Int64: Book], averagePages: Double) async throws -> SearchOutcome {
        let query = QueryParser.ftsQuery(text)
        guard !query.isEmpty else { return .empty }
        return try await run(on: rankQueue) { [ranker] in
            let started = Date()
            var counts: [(Int64, Int)] = []
            // Rowids arrive in ascending order, so a book's pages are consecutive: count runs.
            var current: Int64 = -1
            var run = 0
            try ranker.query("SELECT rowid FROM pages_fts WHERE pages_fts MATCH ?", [.text(query)]) { r in
                let book = PageID.book(of: r.int(0))
                if book != current {
                    if run > 0 { counts.append((current, run)) }
                    current = book
                    run = 0
                }
                run += 1
            }
            if run > 0 { counts.append((current, run)) }
            var titles: [Book] = []
            try ranker.query("SELECT rowid FROM meta_fts WHERE meta_fts MATCH ? ORDER BY rank LIMIT ?",
                             [.text(query), .int(Int64(Self.titleMatchLimit))]) { r in
                if let book = books[r.int(0)] { titles.append(book) }
            }
            let hits = counts.compactMap { id, n -> BookHit? in
                guard let book = books[id] else { return nil }
                return BookHit(book: book, pages: n,
                               score: Ranking.score(hits: n, pages: book.pages, averagePages: averagePages))
            }.sorted { ($0.score, $0.pages) > ($1.score, $1.pages) }
            return SearchOutcome(text: text, query: query, titleMatches: titles, hits: hits,
                                 elapsed: Date().timeIntervalSince(started))
        }
    }

    /// Above this many matching pages in the whole library, passages are taken in page order instead of
    /// by bm25, which counts the query's matches across the entire index on every call. Measured on a
    /// 10x copy of the library, 20 rows of passages: "the" (1.67M pages) 0.98s, geom* (178k) 0.67s,
    /// pattern (235k) 0.11s; in page order "the" took 0.02s.
    static let rankedPassageLimit = 50_000

    /// The best `limit` pages of one book for `query` (the first ones, for very common words).
    func bestPages(book: Int64, query: String, limit: Int, ranked: Bool) async throws -> [PageHit] {
        try await pageHits(book: book, query: query, order: ranked ? "rank" : "p.id", limit: limit)
    }

    /// Every matching page of one book, in page order (capped at bookPageHitLimit).
    func allPages(book: Int64, query: String) async throws -> [PageHit] {
        try await pageHits(book: book, query: query, order: "p.id", limit: Self.bookPageHitLimit)
    }

    func pageText(rowid: Int64) async throws -> String {
        try await run(on: readQueue) { [reader] in
            guard case .text(let text) = try reader.scalar("SELECT unz(z) FROM pages WHERE id = ?", [.int(rowid)])
            else { return "" }
            return text
        }
    }

    private func pageHits(book: Int64, query: String, order: String, limit: Int) async throws -> [PageHit] {
        guard !query.isEmpty else { return [] }
        let range = PageID.range(of: book)
        let sql = """
            SELECT p.id, p.page, p.src, p.images,
                   snippet(pages_fts, 0, char(2), char(3), '…', \(Self.snippetTokens))
            FROM pages_fts JOIN pages p ON p.id = pages_fts.rowid
            WHERE pages_fts MATCH ? AND pages_fts.rowid BETWEEN ? AND ?
            ORDER BY \(order) LIMIT ?
            """
        return try await run(on: readQueue) { [reader] in
            var hits: [PageHit] = []
            try reader.query(sql, [.text(query), .int(range.lowerBound), .int(range.upperBound), .int(Int64(limit))]) { r in
                hits.append(PageHit(id: r.int(0), page: Int(r.int(1)), source: r.text(2),
                                    images: Self.strings(r.text(3)), snippet: Snippet(marked: r.text(4))))
            }
            return hits
        }
    }

    private func run<T: Sendable>(on queue: DispatchQueue, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    private static func strings(_ json: String) -> [String] {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private static func tags(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
