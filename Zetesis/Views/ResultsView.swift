import SwiftUI

/// The middle column: search results, or the shelf's books when nothing is searched.
struct ResultsView: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.engine == nil {
                FirstIndexing()
            } else if model.isQuerying {
                results
            } else {
                List(model.shelfBooks, selection: $model.selectedBookID) { book in
                    BookRow(book: book).tag(book.id)
                }
            }
        }
        .navigationTitle(model.shelfTitle)
        .navigationSubtitle(subtitle)
    }

    private var results: some View {
        @Bindable var model = model
        let hits = model.visibleHits
        let titles = model.visibleTitleMatches
        return List(selection: $model.selectedBookID) {
            if !titles.isEmpty {
                Section("Στον τίτλο, τον συγγραφέα ή το θέμα · \(titles.count)") {
                    ForEach(titles.prefix(12)) { BookRow(book: $0).tag($0.id) }
                }
            }
            Section("Μέσα στα κείμενα · \(hits.count) βιβλία") {
                ForEach(hits) { hit in
                    HitRow(hit: hit, query: model.outcome.query).tag(hit.book.id)
                }
            }
        }
        .overlay {
            if hits.isEmpty && titles.isEmpty && !model.isSearching {
                ContentUnavailableView.search(text: model.outcome.text)
            }
        }
    }

    private var subtitle: String {
        if model.isSearching { return "Αναζήτηση…" }
        if model.isQuerying {
            let hits = model.visibleHits
            let pages = hits.reduce(0) { $0 + $1.pages }
            let ms = Int((model.outcome.elapsed * 1000).rounded())
            return "\(pages.formatted()) σελίδες σε \(hits.count.formatted()) βιβλία · \(ms) ms"
        }
        return "\(model.shelfBooks.count.formatted()) βιβλία"
    }
}

struct BookRow: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(book.title).font(.headline).lineLimit(2)
            HStack(spacing: 6) {
                if !book.author.isEmpty { Text(book.author).foregroundStyle(.secondary).lineLimit(1) }
                TopicChip(book: book)
                Spacer(minLength: 0)
                Text("\(book.pages) σελ.").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

/// A matching book with its number of pages with hits and its two best passages.
struct HitRow: View {
    @Environment(LibraryModel.self) private var model
    let hit: BookHit
    let query: String
    @State private var pages: [PageHit] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(hit.book.title).font(.headline).lineLimit(2)
                Spacer(minLength: 4)
                Text("\(hit.pages)")
                    .font(.caption.monospacedDigit().bold())
                    .padding(.horizontal, 6)
                    .background(Capsule().fill(.quaternary))
                    .help("Σελίδες με ευρήματα")
            }
            HStack(spacing: 6) {
                if !hit.book.author.isEmpty {
                    Text(hit.book.author).foregroundStyle(.secondary).lineLimit(1)
                }
                TopicChip(book: hit.book)
            }
            ForEach(pages) { page in
                (Text("σελ. \(page.page)  ").foregroundStyle(.secondary) + Text(page.snippet.attributed))
                    .font(.callout)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 4)
        .task(id: "\(query)#\(hit.book.id)") {
            pages = await model.bestPages(for: hit.book.id)
        }
    }
}

/// Shown until the first index of a library exists.
struct FirstIndexing: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Πρώτη ευρετηρίαση", systemImage: "text.magnifyingglass")
        } description: {
            if model.updater.isRunning {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(model.updater.phase.label)
                    if model.updater.booksExtracted > 0 {
                        Text("\(model.updater.booksExtracted) βιβλία διαβάστηκαν")
                    }
                    Text("Μια μεγάλη βιβλιοθήκη θέλει χρόνο την πρώτη φορά· μετά ενημερώνονται μόνο τα νέα βιβλία.")
                        .font(.callout)
                }
            } else {
                Text(model.updater.lastError ?? "Δεν υπάρχει ακόμα ευρετήριο για αυτόν τον φάκελο.")
            }
        } actions: {
            if !model.updater.isRunning {
                Button("Ευρετηρίαση τώρα") { model.updater.run(now: true) }
            }
        }
    }
}
