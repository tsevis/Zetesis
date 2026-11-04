/// Page rowids carry their book: id = bookID << bits | n (see Engine/build_index.py, PAGE_BITS).
enum PageID {
    static let bits: Int64 = 17

    static func book(of rowid: Int64) -> Int64 { rowid >> bits }

    static func range(of book: Int64) -> ClosedRange<Int64> {
        let low = book << bits
        return low...(low | ((1 << bits) - 1))
    }
}
