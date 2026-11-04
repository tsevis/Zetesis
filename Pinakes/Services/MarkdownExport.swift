import Foundation

/// A Markdown report of every book that matches a search, with its best passages and page links.
enum MarkdownExport {
    static let passagesPerBook = 3

    static func build(outcome: SearchOutcome, hits: [BookHit], titleMatches: [Book], scope: String?,
                      library: URL, engine: SearchEngine) async throws -> String {
        let date = Date().formatted(date: .numeric, time: .shortened)
        var out = ["# Αναζήτηση: \(outcome.text)", ""]
        var summary = "Εξαγωγή \(date)"
        if let scope { summary += " · \(scope)" }
        summary += " · \(hits.count) βιβλία με \(hits.reduce(0) { $0 + $1.pages }) σελίδες ευρημάτων"
        summary += " · \(titleMatches.count) βιβλία ταιριάζουν στον τίτλο/συγγραφέα/θέμα"
        out += [summary, ""]
        if !titleMatches.isEmpty {
            out += ["## Τίτλοι, συγγραφείς, θέματα", ""]
            out += titleMatches.map { titleLine($0, library: library) }
            out.append("")
        }
        if !hits.isEmpty {
            out += ["## Μέσα στα κείμενα", ""]
            let ranked = outcome.totalPages <= SearchEngine.rankedPassageLimit
            for (n, hit) in hits.enumerated() {
                try Task.checkCancellation()
                let pages = try await engine.bestPages(book: hit.book.id, query: outcome.query, limit: passagesPerBook,
                                                       ranked: ranked)
                out += section(n + 1, hit: hit, pages: pages, library: library)
            }
        }
        return out.joined(separator: "\n")
    }

    static func suggestedName(for text: String) -> String {
        let safe = text.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "Αναζήτηση - \(safe.prefix(60)).md"
    }

    private static func titleLine(_ book: Book, library: URL) -> String {
        let target = book.mainFile ?? book.folder ?? ""
        let author = book.author.isEmpty ? "" : " — \(book.author)"
        return "- [\(escape(book.title))](\(fileURL(target, library: library)))\(author) · *\(book.topic)*"
    }

    private static func section(_ n: Int, hit: BookHit, pages: [PageHit], library: URL) -> [String] {
        let book = hit.book
        var lines = ["### \(n). \(escape(book.title))", ""]
        var meta: [String] = []
        if !book.author.isEmpty { meta.append("**Συγγραφέας:** \(book.author)") }
        meta.append("**Θέμα:** \(book.topic)" + (book.autoTopic ? " (αυτόματο)" : ""))
        if !book.tags.isEmpty { meta.append("**Ετικέτες:** \(book.tags.joined(separator: ", "))") }
        meta.append("**Σελίδες με ευρήματα:** \(hit.pages)")
        lines += [meta.joined(separator: " · "), ""]
        var files = book.files.map { "[\(($0 as NSString).pathExtension.uppercased())](\(fileURL($0, library: library)))" }
        if let folder = book.folder { files.append("[φάκελος md/εικόνων](\(fileURL(folder, library: library)))") }
        if !files.isEmpty { lines += ["Αρχεία: " + files.joined(separator: " · "), ""] }
        for page in pages {
            let pdf = page.isPDFPage ? book.mainPDF : nil
            let place = pdf.map { "[σελ. \(page.page)](\(fileURL($0, library: library, page: page.page)))" }
                ?? "§\(page.page)"
            lines.append("- \(place): \(passage(page.snippet))")
        }
        return lines + [""]
    }

    private static func passage(_ snippet: Snippet) -> String {
        snippet.parts.map { part in
            let text = escape(part.text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression))
            return part.isMatch ? "**\(text)**" : text
        }.joined()
    }

    private static func escape(_ text: String) -> String {
        var out = ""
        for ch in text {
            if "\\`*_[]<>#|".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    private static func fileURL(_ relative: String, library: URL, page: Int? = nil) -> String {
        let url = LibraryLocation.url(relative, in: library).absoluteString
        return page.map { "\(url)#page=\($0)" } ?? url
    }
}
