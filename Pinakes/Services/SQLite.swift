import Foundation
import SQLite3

struct SQLiteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A read-only SQLite connection to the index. Used from one serial queue at a time (see SearchEngine);
/// only `interrupt()` may be called from elsewhere, which SQLite allows.
final class SQLiteConnection: @unchecked Sendable {
    private let db: OpaquePointer

    init(readOnly path: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI
        guard sqlite3_open_v2(path.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "δεν άνοιξε"
            sqlite3_close(handle)
            throw SQLiteError(message: "Το ευρετήριο δεν άνοιξε: \(message)")
        }
        db = handle
        sqlite3_busy_timeout(db, 2000)
        try registerInflate()
    }

    deinit { sqlite3_close_v2(db) }

    func interrupt() { sqlite3_interrupt(db) }

    /// Runs `sql`, calling `row` for each result row.
    func query(_ sql: String, _ bindings: [SQLValue] = [], row: (Row) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw lastError() }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in bindings.enumerated() { value.bind(stmt, Int32(i + 1)) }
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: try row(Row(stmt: stmt))
            case SQLITE_DONE: return
            case SQLITE_INTERRUPT: throw CancellationError()
            default: throw lastError()
            }
        }
    }

    func scalar(_ sql: String, _ bindings: [SQLValue] = []) throws -> Row.Value? {
        var value: Row.Value?
        try query(sql, bindings) { value = $0.value(0) }
        return value
    }

    private func lastError() -> SQLiteError { SQLiteError(message: String(cString: sqlite3_errmsg(db))) }

    /// unz(blob): page text is stored raw-deflate compressed (Engine/build_index.py, deflate()).
    private func registerInflate() throws {
        let rc = sqlite3_create_function_v2(db, "unz", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { ctx, _, args in
            guard let arg = args?[0], sqlite3_value_type(arg) == SQLITE_BLOB,
                  let bytes = sqlite3_value_blob(arg) else {
                sqlite3_result_null(ctx)
                return
            }
            let data = Data(bytes: bytes, count: Int(sqlite3_value_bytes(arg)))
            guard let text = try? (data as NSData).decompressed(using: .zlib) as Data else {
                sqlite3_result_error(ctx, "unz: corrupt page text", -1)
                return
            }
            text.withUnsafeBytes { raw in
                sqlite3_result_text(ctx, raw.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(raw.count),
                                    SQLiteConnection.transient)
            }
        }, nil, nil, nil)
        guard rc == SQLITE_OK else { throw lastError() }
    }

    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

enum SQLValue {
    case int(Int64)
    case text(String)

    func bind(_ stmt: OpaquePointer, _ index: Int32) {
        switch self {
        case .int(let v): sqlite3_bind_int64(stmt, index, v)
        case .text(let v): sqlite3_bind_text(stmt, index, v, -1, SQLiteConnection.transient)
        }
    }
}

struct Row {
    enum Value { case int(Int64), double(Double), text(String), null }

    let stmt: OpaquePointer

    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
    func optionalText(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }

    func value(_ i: Int32) -> Value {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER: .int(int(i))
        case SQLITE_FLOAT: .double(double(i))
        case SQLITE_NULL: .null
        default: .text(text(i))
        }
    }
}
