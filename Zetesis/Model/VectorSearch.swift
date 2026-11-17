import Accelerate

/// One page and how close its vector is to the query (cosine similarity).
struct PageScore: Hashable, Sendable {
    let id: Int64
    let score: Float
}

/// A book and its pages among the nearest ones, best first.
struct BookScore: Hashable, Sendable {
    let book: Int64
    let pages: [Int64]
    let score: Float
}

/// The page vectors of one book, as the engine stores them (Engine/embed.py): each one a little-endian
/// float32 scale followed by `dims` int8 components, so that component ≈ int8 × scale.
struct VectorBlock: Sendable {
    let book: Int64
    let stamp: String
    let ids: [Int64]
    let scales: [Float]
    let components: [Int8]
}

/// Search by meaning over page vectors.
enum VectorSearch {
    static let dims = 1024

    /// How much a book's second and third pages add to its best one: several close pages beat one.
    static let followingPageWeights: [Float] = [1, 0.5, 0.25]

    /// Decodes a book's stored vectors; rows that are not vectors of `dims` components are skipped.
    static func block(book: Int64, stamp: String, rows: [(id: Int64, blob: [UInt8])], dims: Int = dims) -> VectorBlock {
        let valid = rows.filter { $0.blob.count == 4 + dims }
        let scales = valid.map { row in
            Float(bitPattern: row.blob[0..<4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        }
        var components: [Int8] = []
        components.reserveCapacity(valid.count * dims)
        for row in valid {
            row.blob[4...].withUnsafeBytes { components.append(contentsOf: $0.bindMemory(to: Int8.self)) }
        }
        return VectorBlock(book: book, stamp: stamp, ids: valid.map(\.id), scales: scales, components: components)
    }

    /// The `limit` pages whose vectors are closest to `query` (unit length), best first.
    static func nearest(_ query: [Float], in blocks: [VectorBlock], limit: Int, dims: Int = dims) -> [PageScore] {
        guard query.count == dims, limit > 0 else { return [] }
        var best: [PageScore] = []
        for block in blocks where !block.ids.isEmpty {
            for (id, score) in zip(block.ids, scores(of: block, query: query, dims: dims)) {
                guard best.count < limit || score > best[best.count - 1].score else { continue }
                let at = best.firstIndex { $0.score < score } ?? best.count
                best.insert(PageScore(id: id, score: score), at: at)
                if best.count > limit { best.removeLast() }
            }
        }
        return best
    }

    /// Books ranked by their nearest pages: the best one, plus less for the next two.
    static func books(from pages: [PageScore]) -> [BookScore] {
        let grouped = Dictionary(grouping: pages) { PageID.book(of: $0.id) }
        return grouped.map { book, hits in
            let ordered = hits.sorted { $0.score > $1.score }
            let score = zip(ordered, followingPageWeights).reduce(Float(0)) { $0 + $1.0.score * $1.1 }
            return BookScore(book: book, pages: ordered.map(\.id), score: score)
        }.sorted { ($0.score, $0.book) > ($1.score, $1.book) }
    }

    /// Cosine similarity of every vector in the block with the query: int8 rows to float, one matrix
    /// product, then each row's scale.
    private static func scores(of block: VectorBlock, query: [Float], dims: Int) -> [Float] {
        let rows = block.ids.count
        var matrix = [Float](repeating: 0, count: rows * dims)
        vDSP.convertElements(of: block.components, to: &matrix)
        var products = [Float](repeating: 0, count: rows)
        vDSP_mmul(matrix, 1, query, 1, &products, 1, vDSP_Length(rows), 1, vDSP_Length(dims))
        return vDSP.multiply(products, block.scales)
    }
}
