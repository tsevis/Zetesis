import SwiftUI

extension Snippet {
    /// The passage with matched words in bold on a highlighter background.
    var attributed: AttributedString {
        parts.reduce(into: AttributedString()) { result, part in
            var piece = AttributedString(part.text)
            if part.isMatch {
                piece.inlinePresentationIntent = .stronglyEmphasized
                piece.backgroundColor = Color.yellow.opacity(0.35)
            }
            result += piece
        }
    }
}

/// A small coloured label with the book's topic; "auto" when the engine guessed it.
struct TopicChip: View {
    let book: Book

    var body: some View {
        HStack(spacing: 3) {
            Text(book.topic)
            if book.autoTopic {
                Image(systemName: "sparkles").help("Το θέμα δόθηκε αυτόματα")
            }
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
        .foregroundStyle(Color.accentColor)
    }
}
