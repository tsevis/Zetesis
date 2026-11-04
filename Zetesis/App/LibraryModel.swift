import Foundation
import Observation

/// What the window shows: the library's books, the current search and its results.
@MainActor @Observable
final class LibraryModel {
    enum Shelf: Hashable {
        case all, recent, unchecked
        case topic(String)
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case relevance, hits, title, added
        var id: Self { self }

        var label: String {
            switch self {
            case .relevance: "Σχετικότητα"
            case .hits: "Ευρήματα"
            case .title: "Τίτλος"
            case .added: "Προσθήκη"
            }
        }
    }

    static let recentCount = 200
    static let minimumQueryLength = 2
    static let typingPause: Duration = .milliseconds(220)
    static let bestPagesPerRow = 2

    private(set) var library: URL?
    private(set) var engine: SearchEngine?
    private(set) var booksByID: [Int64: Book] = [:]
    private(set) var booksByTitle: [Book] = []
    private(set) var topics: [(name: String, count: Int)] = []
    private(set) var lastUpdated: Date?
    private(set) var outcome: SearchOutcome = .empty
    private(set) var isSearching = false
    private(set) var errorMessage: String?
    private var averagePages = 1.0
    private var recentIDs: Set<Int64> = []
    private var searchTask: Task<Void, Never>?
    private var bestPages: [Int64: [PageHit]] = [:]

    var shelf: Shelf = .all
    var sortOrder: SortOrder = .relevance
    var selectedBookID: Int64?
    var searchText = "" {
        didSet { if searchText != oldValue { scheduleSearch() } }
    }

    let updater = IndexUpdater()

    init() {
        updater.onFinish = { [weak self] in
            Task { await self?.reopen(force: true) }
        }
        if let saved = LibraryLocation.library { open(saved) }
    }

    var isQuerying: Bool { !outcome.query.isEmpty }
    var libraryIsReachable: Bool { library.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    var selectedBook: Book? { selectedBookID.flatMap { booksByID[$0] } }
    var bookCount: Int { booksByID.count }

    func open(_ folder: URL) {
        library = folder
        LibraryLocation.library = folder
        Task { await reopen(force: true) }
        updater.start(library: folder)
    }

    // MARK: - Lists

    /// Matching books in the current shelf, in the chosen order.
    var visibleHits: [BookHit] {
        let hits = outcome.hits.filter { isOnShelf($0.book) }
        switch sortOrder {
        case .relevance: return hits
        case .hits: return hits.sorted { $0.pages > $1.pages }
        case .title: return hits.sorted { $0.book.title.localizedStandardCompare($1.book.title) == .orderedAscending }
        case .added: return hits.sorted { $0.book.added > $1.book.added }
        }
    }

    var visibleTitleMatches: [Book] { outcome.titleMatches.filter(isOnShelf) }

    /// The shelf's books when nothing is searched.
    var shelfBooks: [Book] {
        let books = booksByTitle.filter(isOnShelf)
        switch sortOrder {
        case .added: return books.sorted { $0.added > $1.added }
        case .hits: return books.sorted { $0.pages > $1.pages }
        case .relevance, .title: return shelf == .recent ? books.sorted { $0.added > $1.added } : books
        }
    }

    /// Books on a shelf: matching ones while searching, all of them otherwise.
    func count(on shelf: Shelf) -> Int {
        if isQuerying { return outcome.hits.count { isOn(shelf, $0.book) } }
        if case .all = shelf { return booksByID.count }
        return booksByID.values.count { isOn(shelf, $0) }
    }

    func isOnShelf(_ book: Book) -> Bool { isOn(shelf, book) }

    private func isOn(_ shelf: Shelf, _ book: Book) -> Bool {
        switch shelf {
        case .all: true
        case .recent: recentIDs.contains(book.id)
        case .unchecked: book.autoTopic
        case .topic(let name): book.topic == name
        }
    }

    var shelfTitle: String {
        switch shelf {
        case .all: "Όλα τα βιβλία"
        case .recent: "Πρόσφατα"
        case .unchecked: "Αυτόματη ταξινόμηση"
        case .topic(let name): name
        }
    }

    // MARK: - Search

    private func scheduleSearch() {
        searchTask?.cancel()
        engine?.interruptSearch()
        let text = searchText
        let words = text.split(whereSeparator: \.isWhitespace)
        guard let engine, words.contains(where: { $0.count >= Self.minimumQueryLength }) else {
            outcome = .empty
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [booksByID, averagePages] in
            try? await Task.sleep(for: Self.typingPause)
            guard !Task.isCancelled else { return }
            do {
                let result = try await engine.search(text, books: booksByID, averagePages: averagePages)
                guard !Task.isCancelled else { return }
                bestPages = [:]
                outcome = result
                errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            isSearching = false
        }
    }

    /// The best passages of a result row, fetched once per search.
    func bestPages(for book: Int64) async -> [PageHit] {
        if let cached = bestPages[book] { return cached }
        guard let engine, isQuerying else { return [] }
        let query = outcome.query
        let ranked = outcome.totalPages <= SearchEngine.rankedPassageLimit
        let pages = (try? await engine.bestPages(book: book, query: query, limit: Self.bestPagesPerRow,
                                                 ranked: ranked)) ?? []
        if query == outcome.query { bestPages[book] = pages }
        return pages
    }

    // MARK: - Index

    /// Opens the index for the current library (again, when `force` or when the engine pointed to a new file).
    func reopen(force: Bool) async {
        guard let library else { return }
        guard let url = LibraryLocation.index(for: library) else {
            engine = nil
            return
        }
        if !force, engine?.databaseURL == url { return }
        do {
            let engine = try SearchEngine(databaseURL: url)
            let books = try await engine.loadBooks()
            self.engine = engine
            install(books)
            lastUpdated = await engine.lastUpdated()
            errorMessage = nil
            if !searchText.isEmpty { scheduleSearch() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func install(_ books: [Book]) {
        booksByID = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })
        booksByTitle = books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        averagePages = books.isEmpty ? 1 : Double(books.reduce(0) { $0 + $1.pages }) / Double(books.count)
        recentIDs = Set(books.sorted { $0.added > $1.added }.prefix(Self.recentCount).map(\.id))
        var counts: [String: Int] = [:]
        for book in books { counts[book.topic, default: 0] += 1 }
        topics = counts.map { (name: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
        if let selected = selectedBookID, booksByID[selected] == nil { selectedBookID = nil }
    }

    /// Sets a book's topic by hand (no longer automatic) and lets the engine re-index it.
    func setTopic(_ topic: String, for book: Book) {
        guard let library else { return }
        Task {
            do {
                try await TopicEditor.set(topic: topic, key: book.key, library: library)
                // Shown at once; the engine's update then writes it to the index.
                booksByID[book.id] = book.with(topic: topic)
                install(Array(booksByID.values))
                updater.run(now: true)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func exportMarkdown() async throws -> String {
        guard let engine, let library else { throw SQLiteError(message: "Δεν υπάρχει ευρετήριο.") }
        let scope = shelf == .all ? nil : shelfTitle
        return try await MarkdownExport.build(outcome: outcome, hits: visibleHits, titleMatches: visibleTitleMatches,
                                              scope: scope, library: library, engine: engine)
    }
}
