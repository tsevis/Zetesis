import Foundation

/// A book dragged from the results list, carried as plain text so no custom type has to be declared.
enum BookDrag {
    private static let prefix = "zetesis-book:"

    static func payload(_ id: Int64) -> String { prefix + String(id) }

    /// The books in dropped text; anything that is not a dragged book is ignored.
    static func ids(in items: [String]) -> [Int64] {
        items.compactMap { item in
            item.hasPrefix(prefix) ? Int64(item.dropFirst(prefix.count)) : nil
        }
    }
}
