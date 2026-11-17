import SwiftUI

/// The right column when several books are selected: how many, and where to file them.
struct SelectionView: View {
    @Environment(LibraryModel.self) private var model
    @State private var newTopic = ""
    @State private var isNamingTopic = false

    var body: some View {
        let books = model.selectedBooks
        ContentUnavailableView {
            Label("\(books.count) Books Selected", systemImage: "books.vertical")
        } description: {
            Text("Drag them onto a topic in the sidebar, or choose one here.")
        } actions: {
            Menu("Move to Topic") {
                ForEach(model.topics, id: \.name) { topic in
                    Button(Topic.displayName(topic.name)) { model.setTopic(topic.name, for: books) }
                }
                Divider()
                Button("New Topic…") {
                    newTopic = ""
                    isNamingTopic = true
                }
            }
            .fixedSize()
        }
        .alert("New Topic", isPresented: $isNamingTopic) {
            TextField("Topic name", text: $newTopic)
            Button("Set") {
                if let name = TopicList.cleaned(newTopic) { model.setTopic(name, for: books) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
