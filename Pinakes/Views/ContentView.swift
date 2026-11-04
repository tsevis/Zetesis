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
                        ContentUnavailableView("Διάλεξε ένα βιβλίο", systemImage: "book.closed",
                                               description: Text("Οι σελίδες με ευρήματα εμφανίζονται εδώ."))
                    }
                }
                .searchable(text: $model.searchText, placement: .toolbar,
                            prompt: "Αναζήτηση σε όλη τη βιβλιοθήκη")
                .toolbar { toolbar }
            }
        }
        .alert("Η εξαγωγή απέτυχε", isPresented: .constant(exportError != nil)) {
            Button("Εντάξει") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var model = model
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Ταξινόμηση", selection: $model.sortOrder) {
                ForEach(LibraryModel.SortOrder.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .help("Σειρά των βιβλίων")

            Button {
                export()
            } label: {
                if isExporting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Export σε Markdown", systemImage: "square.and.arrow.up")
                }
            }
            .help("Όλα τα βιβλία της αναζήτησης σε ένα αρχείο .md")
            .disabled(!model.isQuerying || isExporting)
            .keyboardShortcut("e")

            Button {
                model.updater.run(now: true)
            } label: {
                Label("Ενημέρωση", systemImage: "arrow.clockwise")
            }
            .help("Έλεγχος για νέα βιβλία τώρα")
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
            Label("Pinakes", systemImage: "books.vertical")
        } description: {
            Text("Διάλεξε τον φάκελο με τα βιβλία σου (PDF, EPUB, φακέλους md). "
                 + "Τίποτα δεν μετακινείται: το Pinakes διαβάζει, ταξινομεί και ψάχνει μέσα σε όλα.")
        } actions: {
            Button("Επιλογή φακέλου…") { FolderPicker.chooseLibrary(for: model) }
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
        panel.prompt = "Επιλογή"
        panel.message = "Ο φάκελος της βιβλιοθήκης"
        if panel.runModal() == .OK, let url = panel.url { model.open(url) }
    }
}
