import SwiftUI

struct SidebarView: View {
    @Environment(LibraryModel.self) private var model
    @State private var newTopic = ""
    @State private var isNamingTopic = false
    /// The topic a dragged book hovers over.
    @State private var dropTarget: String?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.shelf) {
            Section("Library") {
                row(String(localized: "All Books"), systemImage: "books.vertical", shelf: .all)
                row(String(localized: "Recent"), systemImage: "clock", shelf: .recent)
                row(String(localized: "Sorted Automatically"), systemImage: "sparkles", shelf: .unchecked)
            }
            Section {
                ForEach(model.topics, id: \.name) { topic in
                    let isDropTarget = dropTarget == topic.name
                    row(Topic.displayName(topic.name), systemImage: isDropTarget ? "folder.fill.badge.plus" : "folder",
                        shelf: .topic(topic.name))
                        .background {
                            if isDropTarget {
                                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.25)).padding(-4)
                            }
                        }
                        .dropDestination(for: String.self) { items, _ in
                            model.fileDropped(BookDrag.ids(in: items), under: topic.name)
                        } isTargeted: { isOver in
                            if isOver { dropTarget = topic.name } else if dropTarget == topic.name { dropTarget = nil }
                        }
                        .contextMenu {
                            if topic.count == 0 {
                                Button("Remove Topic") { model.removeTopic(topic.name) }
                            }
                        }
                }
            } header: {
                topicsHeader
            }
        }
        .listStyle(.sidebar)
        .alert("New Topic", isPresented: $isNamingTopic) {
            TextField("Topic name", text: $newTopic)
            Button("Create") { model.addTopic(newTopic) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("To file books under it, drag them onto it from the list of books.")
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                IndexStatus()
                TsevisMark()
            }
            .padding(10)
        }
    }

    private var topicsHeader: some View {
        HStack {
            Text("Topics")
            Spacer()
            Button("New Topic", systemImage: "plus") {
                newTopic = ""
                isNamingTopic = true
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .disabled(model.library == nil)
            .help("New Topic")
        }
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
                if let progress = model.updater.describing, progress.done < progress.total {
                    Text("Book \(progress.done + 1) of \(progress.total)").foregroundStyle(.secondary)
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
