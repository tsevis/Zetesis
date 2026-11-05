import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(LibraryModel.self) private var model
    @State private var isExporting = false
    @State private var exportError: String?

    var body: some View {
        @Bindable var model = model
        Group {
            if model.library == nil {
                Onboarding()
            } else {
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
                } content: {
                    ResultsView()
                        .navigationSplitViewColumnWidth(min: 340, ideal: 460)
                } detail: {
                    if let book = model.selectedBook {
                        BookDetailView(book: book)
                    } else {
                        ContentUnavailableView("Choose a Book", systemImage: "book.closed",
                                               description: Text("Pages with matches appear here."))
                    }
                }
                .searchable(text: $model.searchText, placement: .toolbar,
                            prompt: "Search the whole library")
                .toolbar { toolbar }
            }
        }
        .alert("The Export Failed", isPresented: .constant(exportError != nil)) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var model = model
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Sort", selection: $model.sortOrder) {
                ForEach(LibraryModel.SortOrder.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .help("Order of the books")

            Button {
                export()
            } label: {
                if isExporting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Export as Markdown", systemImage: "square.and.arrow.up")
                }
            }
            .help("Every book of the search in one .md file")
            .disabled(!model.isQuerying || isExporting)
            .keyboardShortcut("e")

            Button {
                model.updater.run(now: true)
            } label: {
                Label("Update", systemImage: "arrow.clockwise")
            }
            .help("Check for new books now")
            .disabled(model.updater.isRunning)
        }
    }

    private func export() {
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let markdown = try await model.exportMarkdown()
                let panel = NSSavePanel()
                panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
                panel.nameFieldStringValue = MarkdownExport.suggestedName(for: model.outcome.text)
                panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try markdown.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}

/// First launch: choose the library folder.
struct Onboarding: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Zetesis", systemImage: "books.vertical")
        } description: {
            Text("Choose the folder that holds your books: PDF, EPUB, DjVu, Word, text, Markdown folders. Nothing is moved or written there: Zetesis reads, sorts and searches inside them all.")
        } actions: {
            Button("Choose Folder…") { FolderPicker.chooseLibrary(for: model) }
                .buttonStyle(.borderedProminent)
        }
    }
}

enum FolderPicker {
    @MainActor
    static func chooseLibrary(for model: LibraryModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "The library folder")
        if panel.runModal() == .OK, let url = panel.url { model.open(url) }
    }
}
