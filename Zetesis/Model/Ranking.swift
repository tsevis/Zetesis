/// Book-level BM25 from matching-page counts; the same formula as Engine/ranking.py.
///
/// A book's "term frequency" is its number of matching pages and its length its page count:
/// more hits help with diminishing returns, and a hit in a short book weighs more than in a long one.
enum Ranking {
    static let k1 = 1.2
    static let b = 0.75

    static func score(hits: Int, pages: Int, averagePages: Double) -> Double {
        let norm = k1 * (1 - b + b * Double(max(pages, 1)) / max(averagePages, 1))
        return Double(hits) * (k1 + 1) / (Double(hits) + norm)
    }
}
