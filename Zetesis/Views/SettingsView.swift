import SwiftUI

struct SettingsView: View {
    @Environment(LibraryModel.self) private var model
    @State private var backgroundUpdates = BackgroundAgent.isInstalled
    @State private var agentError: String?
    @State private var topicFolders = false

    var body: some View {
        Form {
            Section("Library") {
                LabeledContent("Folder") {
                    Text(model.library?.path(percentEncoded: false) ?? "—").textSelection(.enabled)
                }
                Button("Change Folder…") { FolderPicker.chooseLibrary(for: model) }
                LabeledContent("Books", value: model.bookCount.formatted())
                if let updated = model.lastUpdated {
                    LabeledContent("Last updated", value: updated.formatted(date: .abbreviated, time: .shortened))
                }
                if let db = model.engine?.databaseURL {
                    LabeledContent("Index") {
                        Text(Self.size(of: db)).help(db.path)
                    }
                }
            }
            Section("Updates") {
                Text("While Zetesis is open, every new book is indexed as soon as it has finished copying.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Also update while Zetesis is closed", isOn: $backgroundUpdates)
                    .onChange(of: backgroundUpdates) { _, on in setAgent(on) }
                    .disabled(model.library == nil)
                if let agentError { Text(agentError).foregroundStyle(.red).font(.caption) }
                Toggle("Keep topic folders in the library", isOn: $topicFolders)
                    .onChange(of: topicFolders) { _, on in setTopicFolders(on) }
                    .disabled(model.library == nil)
                Text("A folder of links, one subfolder per topic. Nothing is moved; switching it off leaves the folder as it is.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Rebuild the Index from Scratch") { model.updater.run(now: true, full: true) }
                    .disabled(model.updater.isRunning || model.library == nil)
                Button("Open Log") { NSWorkspace.shared.open(LibraryLocation.log) }
            }
        }
        .onAppear { topicFolders = model.library.map(LibraryLocation.keepsTopicFolders) ?? false }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setTopicFolders(_ on: Bool) {
        guard let library = model.library, on != LibraryLocation.keepsTopicFolders(in: library) else { return }
        LibraryLocation.setKeepsTopicFolders(on)
        // The LaunchAgent carries the choice in its environment, so it is written again.
        if backgroundUpdates { setAgent(true) }
        if on { model.updater.run(now: true) }
    }

    private func setAgent(_ on: Bool) {
        guard let library = model.library else { return }
        Task {
            do {
                try await BackgroundAgent.set(on, library: library)
                agentError = nil
            } catch {
                agentError = error.localizedDescription
                backgroundUpdates = BackgroundAgent.isInstalled
            }
        }
    }

    private static func size(of url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
