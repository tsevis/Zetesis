import AppKit
import PDFKit
import QuickLook
import SwiftUI

/// The right column: one book, its files, and every page that matches the search.
struct BookDetailView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let book: Book
    @State private var pages: [PageHit] = []
    @State private var isLoading = false
    @State private var preview: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BookHeader(book: book, open: { open(page: 1, rowid: nil) })
                Divider()
                if model.isQuerying {
                    hitsList
                } else {
                    Text("Γράψε μια λέξη στην αναζήτηση για να δεις σε ποιες σελίδες αυτού του βιβλίου εμφανίζεται.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .quickLookPreview($preview)
        .task(id: "\(model.outcome.query)#\(book.id)") { await load() }
    }

    @ViewBuilder
    private var hitsList: some View {
        HStack {
            Text("Σελίδες με ευρήματα").font(.title3.bold())
            if isLoading { ProgressView().controlSize(.small) }
            Spacer()
            Text("\(pages.count)\(pages.count == SearchEngine.bookPageHitLimit ? "+" : "")")
                .foregroundStyle(.secondary)
        }
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(pages) { page in
                PageHitCard(page: page, library: model.library, preview: $preview) {
                    open(page: page.page, rowid: page.id)
                }
            }
        }
    }

    private func load() async {
        guard let engine = model.engine, model.isQuerying else {
            pages = []
            return
        }
        isLoading = true
        pages = (try? await engine.allPages(book: book.id, query: model.outcome.query)) ?? []
        isLoading = false
    }

    private func open(page: Int, rowid: Int64?) {
        let terms = QueryParser.highlightTerms(model.outcome.text).map(\.text)
        openWindow(id: ReaderTarget.windowID,
                   value: ReaderTarget(bookID: book.id, query: model.outcome.query, terms: terms, page: page, rowid: rowid))
    }
}

struct BookHeader: View {
    @Environment(LibraryModel.self) private var model
    let book: Book
    let open: () -> Void
    @State private var cover: NSImage?
    @State private var newTopic = ""
    @State private var isNamingTopic = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Group {
                if let cover {
                    Image(nsImage: cover).resizable().aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                        .overlay(Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.tertiary))
                }
            }
            .frame(width: 110, height: 150)
            .shadow(radius: 2, y: 1)

            VStack(alignment: .leading, spacing: 6) {
                Text(book.title).font(.title2.bold()).textSelection(.enabled)
                if !book.author.isEmpty { Text(book.author).font(.title3).foregroundStyle(.secondary) }
                HStack {
                    topicMenu
                    Text("\(book.pages) σελίδες").foregroundStyle(.secondary)
                    if book.images > 0 { Text("· \(book.images) εικόνες").foregroundStyle(.secondary) }
                }
                if !book.tags.isEmpty {
                    Text(book.tags.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                }
                actions.padding(.top, 4)
            }
        }
        .task(id: book.id) { cover = await Cover.image(for: book, library: model.library) }
        .alert("Νέο θέμα", isPresented: $isNamingTopic) {
            TextField("Όνομα θέματος", text: $newTopic)
            Button("Ορισμός") { if !newTopic.isEmpty { model.setTopic(newTopic, for: book) } }
            Button("Άκυρο", role: .cancel) {}
        }
    }

    private var topicMenu: some View {
        Menu {
            ForEach(model.topics, id: \.name) { topic in
                Button(topic.name) { model.setTopic(topic.name, for: book) }
            }
            Divider()
            Button("Νέο θέμα…") {
                newTopic = ""
                isNamingTopic = true
            }
            if book.autoTopic {
                Button("Σωστό, κράτησέ το") { model.setTopic(book.topic, for: book) }
            }
        } label: {
            TopicChip(book: book)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Αλλαγή θέματος")
    }

    private var actions: some View {
        HStack {
            Button("Ανάγνωση", systemImage: "book", action: open)
                .buttonStyle(.borderedProminent)
            if let file = book.mainFile, let library = model.library {
                Button("Preview", systemImage: "arrow.up.forward.app") {
                    NSWorkspace.shared.open(LibraryLocation.url(file, in: library))
                }
                Button("Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([LibraryLocation.url(file, in: library)])
                }
            }
            if let folder = book.folder, let library = model.library {
                Button("Φάκελος md", systemImage: "photo.on.rectangle") {
                    NSWorkspace.shared.open(LibraryLocation.url(folder, in: library))
                }
            }
        }
        .controlSize(.small)
        .disabled(!model.libraryIsReachable)
    }
}

/// One matching page: its number, the passage, and the page's images.
struct PageHitCard: View {
    let page: PageHit
    let library: URL?
    @Binding var preview: URL?
    let open: () -> Void
    static let thumbnails = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("σελ. \(page.page)", action: open).buttonStyle(.link).font(.callout.bold())
                if page.source != "pdf" { Text(page.source).font(.caption).foregroundStyle(.tertiary) }
            }
            Text(page.snippet.attributed).font(.callout).textSelection(.enabled)
            if let library, !page.images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(page.images.prefix(Self.thumbnails), id: \.self) { rel in
                            let url = LibraryLocation.url(rel, in: library)
                            AsyncImage(url: url) { image in
                                image.resizable().aspectRatio(contentMode: .fit)
                            } placeholder: {
                                Rectangle().fill(.quaternary)
                            }
                            .frame(height: 80)
                            .onTapGesture { preview = url }
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
    }
}

/// The first page of a book's PDF, rendered small and kept for the session.
enum Cover {
    @MainActor private static var cache: [Int64: NSImage] = [:]
    static let size = CGSize(width: 220, height: 300)

    @MainActor
    static func image(for book: Book, library: URL?) async -> NSImage? {
        if let cached = cache[book.id] { return cached }
        guard let pdf = book.mainPDF, let library else { return nil }
        let url = LibraryLocation.url(pdf, in: library)
        let image = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
            return page.thumbnail(of: size, for: .cropBox)
        }.value
        if let image { cache[book.id] = image }
        return image
    }
}
