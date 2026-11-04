import SQLite3
import XCTest

/// Anything typed in the search field must become a query FTS5 accepts: a syntax error would
/// show as a failed search instead of results.
final class QueryParserTests: XCTestCase {
    func testTypedTextBecomesQuotedTerms() {
        XCTAssertEqual(QueryParser.ftsQuery("golden ratio"), #""golden" "ratio""#)
        XCTAssertEqual(QueryParser.ftsQuery(#""golden ratio" patt*"#), #""golden ratio" "patt"*"#)
        XCTAssertEqual(QueryParser.ftsQuery("islamic -persian"), #""islamic" NOT "persian""#)
        XCTAssertEqual(QueryParser.ftsQuery("a OR OR b"), #""a" OR "b""#)
        XCTAssertEqual(QueryParser.ftsQuery("-only"), "")
    }

    /// The index holds accent-folded text (Engine/textfold.py) because FTS5 keeps the Greek tonos;
    /// an unfolded query term would find nothing.
    func testGreekAccentsAreFoldedLikeTheIndex() {
        XCTAssertEqual(QueryParser.ftsQuery("ιστορία Ἑλλάδος"), #""ιστορια" "Ελλαδος""#)
        XCTAssertEqual(QueryParser.ftsQuery("μαΐστρος*"), #""μαιστρος"*"#)
    }

    func testAwkwardInputNeverBreaksFTS5() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE VIRTUAL TABLE t USING fts5(x, prefix='3'); "
                                        + "INSERT INTO t VALUES('golden ratio and patterns')", nil, nil, nil), SQLITE_OK)
        let inputs = [#"""#, "*", "OR", "a OR", "NOT a", "(x", "x:y", "^a", "NOT NOT", "a - b", "a OR NOT b",
                      #""a""b"#, "a* *b", "AND", "a AND", "NEAR(a b)", "{x}", "a+b", "όλα ΟR", "''", "-", "--x"]
        for input in inputs {
            let query = QueryParser.ftsQuery(input)
            guard !query.isEmpty else { continue }
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT rowid FROM t WHERE t MATCH ?", -1, &stmt, nil), SQLITE_OK)
            sqlite3_bind_text(stmt, 1, query, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            let rc = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            XCTAssertTrue(rc == SQLITE_ROW || rc == SQLITE_DONE,
                          "\(input) → \(query): \(String(cString: sqlite3_errmsg(db)))")
        }
    }
}
