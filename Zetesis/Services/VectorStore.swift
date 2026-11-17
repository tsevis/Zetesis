import Foundation

/// The page vectors of the library, kept in memory across index reloads and brought up to date before
/// each search by meaning: only books described (again) since the last search are read. Page ids stay
/// the same when the index is rebuilt (see Engine/build_index.py), so a new index file costs nothing.
///
/// A book is kept for as long as its `embedded` row is unchanged; the engine deletes that row whenever
/// it deletes the book's pages. Each book is kept as soon as it is read, so a refresh interrupted by
/// the next keystroke resumes where it stopped instead of starting over.
final class VectorStore: @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [Int64: VectorBlock] = [:]

    /// Brings the vectors in line with the index, then finds the pages nearest to `query`.
    func nearest(_ query: [Float], limit: Int, in db: SQLiteConnection) throws -> [PageScore] {
        try lock.withLock {
            try refresh(from: db)
            return VectorSearch.nearest(query, in: Array(blocks.values), limit: limit)
        }
    }

    /// Called with the lock held.
    private func refresh(from db: SQLiteConnection) throws {
        guard case .int(1) = try db.scalar("SELECT count(*) FROM sqlite_master WHERE name = 'embedded'") else {
            blocks = [:]
            return
        }
        var described: [Int64: String] = [:]
        try db.query("SELECT book, stamp || '|' || model FROM embedded") { described[$0.int(0)] = $0.text(1) }
        blocks = blocks.filter { described[$0.key] == $0.value.stamp }
        for (book, stamp) in described where blocks[book] == nil {
            let range = PageID.range(of: book)
            var rows: [(id: Int64, blob: [UInt8])] = []
            try db.query("SELECT id, v FROM vectors WHERE id BETWEEN ? AND ?",
                         [.int(range.lowerBound), .int(range.upperBound)]) { rows.append(($0.int(0), $0.bytes(1))) }
            blocks[book] = VectorSearch.block(book: book, stamp: stamp, rows: rows)
        }
    }
}
