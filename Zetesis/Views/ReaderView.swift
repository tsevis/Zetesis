import PDFKit
import SwiftUI

/// A book open at a page, with the search's hits in a sidebar and the matched words highlighted.
struct ReaderView: View {
    @Environment(LibraryModel.self) private var model
    let target: ReaderTarget
    @State private var hits: [PageHit] = []
    @State private var current: PageHit.ID?
    @State private var page: Int

    init(target: ReaderTarget) {
        self.target = target
        _page = State(initialValue: target.page)
        _current = State(initialValue: target.rowid)
    }

    private var book: Book? { model.booksByID[target.bookID] }
    private var currentHit: PageHit? { hits.first { $0.id == current } }

    var body: some View {
        NavigationSplitView {
            List(hits, selection: $current) { hit in
                VStack(alignment: .leading, spacing: 2) {
                    Text("σελ. \(hit.page)").font(.callout.bold())
                    Text(hit.snippet.attributed).font(.caption).lineLimit(4)
                }
                .tag(hit.id)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 260)
            .overlay {
                if hits.isEmpty { Text("Χωρίς αναζήτηση").foregroundStyle(.secondary) }
            }
        } detail: {
            if let book, let library = model.library {
                if currentHit?.isPDFPage ?? true, let pdf = book.mainPDF,
                   FileManager.default.fileExists(atPath: LibraryLocation.url(pdf, in: library).path) {
                    PDFReader(url: LibraryLocation.url(pdf, in: library), page: page, terms: target.terms)
                } else if let rowid = current ?? hits.first?.id {
                    TextPage(rowid: rowid, terms: target.terms)
                } else {
                    ContentUnavailableView("Δεν υπάρχει αρχείο για ανάγνωση", systemImage: "doc.questionmark")
                }
            } else {
                ContentUnavailableView("Ο δίσκος της βιβλιοθήκης δεν είναι συνδεδεμένος", systemImage: "externaldrive")
            }
        }
        .navigationTitle(book?.title ?? "Zetesis")
        .navigationSubtitle(hits.isEmpty ? "σελ. \(page)" : "\(hits.count) σελίδες με ευρήματα · σελ. \(page)")
        .onChange(of: current) { _, id in
            if let hit = hits.first(where: { $0.id == id }) { page = hit.page }
        }
        // Keyed on the index: a window restored at launch opens before the index does.
        .task(id: model.engine?.databaseURL) {
            guard let engine = model.engine, !target.query.isEmpty else { return }
            hits = (try? await engine.allPages(book: target.bookID, query: target.query)) ?? []
        }
    }
}

/// PDFKit at a page, with every occurrence of the search terms on that page highlighted.
struct PDFReader: NSViewRepresentable {
    let url: URL
    let page: Int
    let terms: [String]

    final class Coordinator {
        var url: URL?
        var page = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        let state = context.coordinator
        if state.url != url {
            view.document = PDFDocument(url: url)
            state.url = url
            state.page = 0
        }
        guard state.page != page, let document = view.document,
              let pdfPage = document.page(at: min(max(page - 1, 0), document.pageCount - 1)) else { return }
        state.page = page
        let selections = Self.matches(of: terms, on: pdfPage)
        view.highlightedSelections = selections
        view.go(to: pdfPage)
        if let first = selections.first {
            view.go(to: first.bounds(for: pdfPage), on: pdfPage)
        }
    }

    /// Diacritic- and case-insensitive, like the search, so "μαιανδρος" finds "μαίανδρος".
    static func matches(of terms: [String], on page: PDFPage) -> [PDFSelection] {
        guard let text = page.string, !terms.isEmpty else { return [] }
        var selections: [PDFSelection] = []
        for term in terms where !term.isEmpty {
            var searchRange = text.startIndex..<text.endIndex
            while let found = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
                if let selection = page.selection(for: NSRange(found, in: text)) {
                    selection.color = NSColor.systemYellow.withAlphaComponent(0.55)
                    selections.append(selection)
                }
                searchRange = found.upperBound..<text.endIndex
            }
        }
        return selections
    }
}

/// For books without a PDF (md, EPUB, text): the indexed text of the page, highlighted.
struct TextPage: View {
    @Environment(LibraryModel.self) private var model
    let rowid: Int64
    let terms: [String]
    @State private var text = AttributedString()

    var body: some View {
        ScrollView {
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: 720, alignment: .leading)
                .padding(32)
        }
        .task(id: "\(rowid)#\(model.engine?.databaseURL.path ?? "")") {
            let raw = (try? await model.engine?.pageText(rowid: rowid)) ?? ""
            text = Self.highlight(raw, terms: terms)
        }
    }

    static func highlight(_ raw: String, terms: [String]) -> AttributedString {
        var result = AttributedString(raw)
        for term in terms where !term.isEmpty {
            var searchRange = raw.startIndex..<raw.endIndex
            while let found = raw.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
                if let range = Range(found, in: result) {
                    result[range].backgroundColor = Color.yellow.opacity(0.4)
                    result[range].inlinePresentationIntent = .stronglyEmphasized
                }
                searchRange = found.upperBound..<raw.endIndex
            }
        }
        return result
    }
}
