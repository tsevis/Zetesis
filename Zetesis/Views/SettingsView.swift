import SwiftUI

struct SettingsView: View {
    @Environment(LibraryModel.self) private var model
    @State private var backgroundUpdates = BackgroundAgent.isInstalled
    @State private var agentError: String?

    var body: some View {
        Form {
            Section("Βιβλιοθήκη") {
                LabeledContent("Φάκελος") {
                    Text(model.library?.path(percentEncoded: false) ?? "—").textSelection(.enabled)
                }
                Button("Αλλαγή φακέλου…") { FolderPicker.chooseLibrary(for: model) }
                LabeledContent("Βιβλία", value: model.bookCount.formatted())
                if let updated = model.lastUpdated {
                    LabeledContent("Τελευταία ενημέρωση", value: updated.formatted(date: .abbreviated, time: .shortened))
                }
                if let db = model.engine?.databaseURL {
                    LabeledContent("Ευρετήριο") {
                        Text(Self.size(of: db)).help(db.path)
                    }
                }
            }
            Section("Ενημέρωση") {
                Text("Όσο το Zetesis είναι ανοιχτό, κάθε νέο βιβλίο μπαίνει στο ευρετήριο μόλις τελειώσει η αντιγραφή του.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Ενημέρωση και όταν το Zetesis είναι κλειστό", isOn: $backgroundUpdates)
                    .onChange(of: backgroundUpdates) { _, on in setAgent(on) }
                    .disabled(model.library == nil)
                if let agentError { Text(agentError).foregroundStyle(.red).font(.caption) }
                Button("Ξαναχτίσε το ευρετήριο από την αρχή") { model.updater.run(now: true, full: true) }
                    .disabled(model.updater.isRunning || model.library == nil)
                Button("Άνοιγμα αρχείου καταγραφής") { NSWorkspace.shared.open(LibraryLocation.log) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
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
