import SwiftUI

struct SidebarView: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.shelf) {
            Section("Βιβλιοθήκη") {
                row("Όλα τα βιβλία", systemImage: "books.vertical", shelf: .all)
                row("Πρόσφατα", systemImage: "clock", shelf: .recent)
                row("Αυτόματη ταξινόμηση", systemImage: "sparkles", shelf: .unchecked)
            }
            Section("Θέματα") {
                ForEach(model.topics, id: \.name) { topic in
                    row(topic.name, systemImage: "folder", shelf: .topic(topic.name))
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
                    Text("\(model.updater.booksExtracted) βιβλία διαβάστηκαν").foregroundStyle(.secondary)
                }
            } else if let updated = model.lastUpdated {
                Text("Ευρετήριο: \(updated.formatted(.relative(presentation: .named)))")
                    .foregroundStyle(.secondary)
            }
            if !model.libraryIsReachable {
                Label("Ο δίσκος της βιβλιοθήκης δεν είναι συνδεδεμένος", systemImage: "externaldrive.badge.xmark")
                    .foregroundStyle(.orange)
            }
            if let error = model.updater.lastError ?? model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).lineLimit(4)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
