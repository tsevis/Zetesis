import XCTest

/// Page vectors arrive as the engine stores them (scale + int8 components). A wrong stride, a dropped
/// scale or a misread byte order ranks the wrong pages without any error, so the order is checked.
final class VectorSearchTests: XCTestCase {
    private func blob(scale: Float, _ values: [Int8]) -> [UInt8] {
        withUnsafeBytes(of: scale.bitPattern.littleEndian, Array.init) + values.map { UInt8(bitPattern: $0) }
    }

    func testPagesAreRankedByTheirScaledVectorsAndGroupedIntoBooks() {
        let first = PageID.range(of: 1).lowerBound, second = PageID.range(of: 2).lowerBound
        // Book 2's page has the larger integers but the smaller scale: without the scale it would win.
        let one = VectorSearch.block(book: 1, stamp: "a", rows: [
            (first, blob(scale: 0.01, [100, 0, 0, 0])),       // ≈ (1, 0, 0, 0)
            (first + 1, blob(scale: 0.01, [0, 100, 0, 0])),   // ≈ (0, 1, 0, 0)
        ], dims: 4)
        let two = VectorSearch.block(book: 2, stamp: "b", rows: [
            (second, blob(scale: 0.7071 / 127, [127, 127, 0, 0])),  // ≈ (0.71, 0.71, 0, 0)
            (second + 1, [1, 2, 3]),                               // not a vector: skipped
        ], dims: 4)
        let pages = VectorSearch.nearest([1, 0, 0, 0], in: [one, two], limit: 2, dims: 4)
        XCTAssertEqual(pages.map(\.id), [first, second])
        XCTAssertEqual(pages.first?.score ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(VectorSearch.books(from: pages).map(\.book), [1, 2])
    }
}

/// Search by meaning always has a nearest page, however unrelated: without a cut-off every book of the
/// library comes back. The cut-off is relative to the best page (scores differ a lot between queries)
/// and absolute (when even the best page is weak, meaning tells relevant from unrelated no better than chance).
final class MeaningCutoffTests: XCTestCase {
    private func page(_ n: Int64, _ score: Float) -> PageScore { PageScore(id: n, score: score) }

    func testPagesFarBelowTheBestOrUnderTheFloorAreDropped() {
        let pages = [page(1, 0.66), page(2, 0.60), page(3, 0.53), page(4, 0.41)]
        XCTAssertEqual(VectorSearch.relevant(pages).map(\.id), [1, 2])
        XCTAssertEqual(VectorSearch.relevant([page(5, 0.44), page(6, 0.40)]).map(\.id), [])
        XCTAssertEqual(VectorSearch.relevant([page(7, 0.50), page(8, 0.46), page(9, 0.44)]).map(\.id), [7, 8])
    }
}
