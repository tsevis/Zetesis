import AppKit
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
            case .relevance: String(localized: "Relevance")
            case .hits: String(localized: "Matches")
            case .title: String(localized: "Title")
            case .added: String(localized: "Date added")
            }
        }
    }

    static let recentCount = 200
    static let minimumQueryLength = 2
    static let typingPause: Duration = .milliseconds(220)
    /// A search by meaning reads the whole query, so it waits for a longer pause in the typing.
    static let meaningTypingPause: Duration = .milliseconds(600)
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
    private var declaredTopics: [String] = []
    private var searchTask: Task<Void, Never>?
    private var bestPages: [Int64: [PageHit]] = [:]
    /// Counts the searches shown, so passages fetched for an earlier one are not kept for this one
    /// (the same text searched by words and then by meaning, for instance).
    private(set) var searchGeneration = 0
    private let vectors = VectorStore()
    private let embedder = QueryEmbedder()
    private var quitObserver: NSObjectProtocol?
    /// llama-server and the model, when search by meaning is switched on in Settings and both are found.
    private(set) var meaningTools: EmbeddingTools.Found?

    var shelf: Shelf = .all
    var sortOrder: SortOrder = .relevance
    var selectedBookID: Int64?
    var searchText = "" {
        didSet { if searchText != oldValue { scheduleSearch() } }
    }
    /// The search field looks for pages by meaning rather than by their words.
    var searchesByMeaning = EmbeddingTools.searchesByMeaning {
        didSet {
            EmbeddingTools.searchesByMeaning = searchesByMeaning
            if searchesByMeaning != oldValue { scheduleSearch() }
        }
    }

    let updater = IndexUpdater()

    init() {
        updater.onFinish = { [weak self] in
            Task { await self?.reopen(force: true) }
        }
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [embedder] _ in embedder.stop() }
        Task.detached { QueryEmbedder.stopOrphans() }
        refreshMeaningTools()
        if let saved = LibraryLocation.library { open(saved) }
    }

    var canSearchByMeaning: Bool { meaningTools != nil }
    var isSearchingByMeaning: Bool { searchesByMeaning && canSearchByMeaning }

    /// Looks for llama-server and the model again (after Settings changed, or they were installed).
    func refreshMeaningTools() {
        meaningTools = EmbeddingTools.isPrepared ? EmbeddingTools.find() : nil
        if !canSearchByMeaning { embedder.stop() }
        if searchesByMeaning { scheduleSearch() }
    }

    var isQuerying: Bool { !outcome.text.isEmpty }
    var libraryIsReachable: Bool { library.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    var selectedBook: Book? { selectedBookID.flatMap { booksByID[$0] } }
    var bookCount: Int { booksByID.count }

    func open(_ folder: URL) {
        library = folder
        LibraryLocation.library = folder
        declaredTopics = DeclaredTopics.load(for: folder)
        listTopics()
        Task { await reopen(force: true) }
        updater.start(library: folder)
        // The LaunchAgent keeps the paths of the app it was installed from; refresh them in case it moved.
        if BackgroundAgent.isInstalled { Task { try? await BackgroundAgent.set(true, library: folder) } }
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
        case .all: String(localized: "All Books")
        case .recent: String(localized: "Recent")
        case .unchecked: String(localized: "Sorted Automatically")
        case .topic(let name): Topic.displayName(name)
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
        let meaning = isSearchingByMeaning ? meaningTools : nil
        searchTask = Task { [booksByID, averagePages, embedder] in
            try? await Task.sleep(for: meaning == nil ? Self.typingPause : Self.meaningTypingPause)
            guard !Task.isCancelled else { return }
            do {
                let result: SearchOutcome
                if let meaning {
                    let words = try await engine.search(text, books: booksByID, averagePages: averagePages)
                    let vector = try await embedder.embed(text, with: meaning)
                    guard !Task.isCancelled else { return }
                    let near = try await engine.searchByMeaning(text, vector: vector, books: booksByID)
                    result = Fusion.blend(words: words, meaning: near)
                } else {
                    result = try await engine.search(text, books: booksByID, averagePages: averagePages)
                }
                guard !Task.isCancelled else { return }
                bestPages = [:]
                searchGeneration += 1
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
        let generation = searchGeneration
        let pages = (try? await pages(of: book, limit: Self.bestPagesPerRow, engine: engine)) ?? []
        if generation == searchGeneration { bestPages[book] = pages }
        return pages
    }

    /// A result's pages: those with the words first (the best `limit`, or with `limit` nil every one in
    /// page order), then the pages nearest in meaning that are not among them.
    func pages(of book: Int64, limit: Int?, engine: SearchEngine) async throws -> [PageHit] {
        let cap = limit ?? SearchEngine.bookPageHitLimit
        var found: [PageHit] = []
        if !outcome.query.isEmpty, outcome.hits.contains(where: { $0.book.id == book && $0.matchesWords }) {
            if limit == nil {
                found = try await engine.allPages(book: book, query: outcome.query)
            } else {
                let ranked = outcome.wordPages <= SearchEngine.rankedPassageLimit
                found = try await engine.bestPages(book: book, query: outcome.query, limit: cap, ranked: ranked)
            }
        }
        if found.count < cap, let nearest = outcome.meaningPages?[book] {
            let shown = Set(found.map(\.id))
            found += try await engine.pages(ids: Array(nearest.filter { !shown.contains($0) }.prefix(cap - found.count)))
        }
        return found
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
            let engine = try SearchEngine(databaseURL: url, vectors: vectors)
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
        listTopics()
        if let selected = selectedBookID, booksByID[selected] == nil { selectedBookID = nil }
    }

    private func listTopics() {
        topics = TopicList.entries(bookTopics: booksByID.values.map(\.topic), declared: declaredTopics)
    }

    /// Makes a topic that has no book yet and shows it; a name already in use shows that topic.
    func addTopic(_ name: String) {
        guard let library, let name = TopicList.cleaned(name) else { return }
        if let known = TopicList.existing(name, in: topics.map(\.name)) {
            shelf = .topic(known)
            return
        }
        declare(declaredTopics + [name], in: library)
        shelf = .topic(name)
    }

    /// Removes a topic made by hand. One that has books stays: it goes when its books move.
    func removeTopic(_ name: String) {
        guard let library, !booksByID.values.contains(where: { $0.topic == name }) else { return }
        declare(declaredTopics.filter { $0 != name }, in: library)
        if shelf == .topic(name) { shelf = .all }
    }

    private func declare(_ names: [String], in library: URL) {
        declaredTopics = names
        DeclaredTopics.save(names, for: library)
        listTopics()
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
        guard let engine, let library else { throw SQLiteError(message: String(localized: "There is no index yet.")) }
        let scope = shelf == .all ? nil : shelfTitle
        return try await MarkdownExport.build(outcome: outcome, hits: visibleHits, titleMatches: visibleTitleMatches,
                                              scope: scope, library: library) { book in
            try await self.pages(of: book, limit: MarkdownExport.passagesPerBook, engine: engine)
        }
    }
}
