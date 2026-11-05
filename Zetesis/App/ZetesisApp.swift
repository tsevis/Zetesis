import SwiftUI

@main
struct ZetesisApp: App {
    @State private var model = LibraryModel()
    /// The splash screen, shown at every launch and again from About Zetesis.
    @State private var isAboutPresented = true

    var body: some Scene {
        Window("Zetesis", id: "main") {
            AboutPresentation(isPresented: isAboutPresented, dismiss: { isAboutPresented = false }) {
                ContentView()
            }
            .environment(model)
            .frame(minWidth: 960, minHeight: 600)
        }
        .commands {
            // Replaces the standard About panel with the splash screen.
            CommandGroup(replacing: .appInfo) {
                Button("About Zetesis") { isAboutPresented = true }
            }
            CommandGroup(after: .newItem) {
                Button("Update Index") { model.updater.run(now: true) }
                    .keyboardShortcut("r")
                    .disabled(model.library == nil)
            }
        }

        WindowGroup("Reader", id: ReaderTarget.windowID, for: ReaderTarget.self) { $target in
            if let target {
                ReaderView(target: target)
                    .environment(model)
                    .frame(minWidth: 760, minHeight: 560)
            }
        }
        .defaultSize(width: 1100, height: 820)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// What a reader window shows: a book, the search whose hits it lists, and the page to open at.
struct ReaderTarget: Codable, Hashable {
    static let windowID = "reader"
    let bookID: Int64
    let query: String
    let terms: [String]
    let page: Int
    let rowid: Int64?
}
