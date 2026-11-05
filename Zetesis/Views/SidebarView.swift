import SwiftUI

struct SidebarView: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.shelf) {
            Section("Library") {
                row(String(localized: "All Books"), systemImage: "books.vertical", shelf: .all)
                row(String(localized: "Recent"), systemImage: "clock", shelf: .recent)
                row(String(localized: "Sorted Automatically"), systemImage: "sparkles", shelf: .unchecked)
            }
            Section("Topics") {
                ForEach(model.topics, id: \.name) { topic in
                    row(Topic.displayName(topic.name), systemImage: "folder", shelf: .topic(topic.name))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { IndexStatus().padding(10) }
    }

    private func row(_ title: String, systemImage: String, shelf: LibraryModel.Shelf) -> some View {
        let count = model.count(on: shelf)
        return Label(title, systemImage: systemImage)
            .badge(count)
            .foregroundStyle(model.isQuerying && count == 0 ? .secondary : .primary)
            .tag(shelf)
    }
}

/// What the engine is doing, or when the index was last brought up to date.
struct IndexStatus: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.updater.isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(model.updater.phase.label)
                }
                if model.updater.booksExtracted > 0 {
                    Text("\(model.updater.booksExtracted) books read").foregroundStyle(.secondary)
                }
                if let progress = model.updater.recognition {
                    Text("Scanned book \(progress.done + 1) of \(progress.total)").foregroundStyle(.secondary)
                }
            } else if let updated = model.lastUpdated {
                Text("Index: \(updated.formatted(.relative(presentation: .named)))")
                    .foregroundStyle(.secondary)
            }
            if !model.libraryIsReachable {
                Label("The library’s disk is not connected", systemImage: "externaldrive.badge.xmark")
                    .foregroundStyle(.orange)
            }
            if model.updater.greekBooksWaiting > 0 {
                Label("\(model.updater.greekBooksWaiting) Greek books wait for Tesseract", systemImage: "text.viewfinder")
                    .foregroundStyle(.orange)
                Text("To read scanned Greek books, install it in Terminal:").foregroundStyle(.secondary)
                Text(verbatim: "brew install tesseract tesseract-lang")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            if let error = model.updater.lastError ?? model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).lineLimit(4)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
