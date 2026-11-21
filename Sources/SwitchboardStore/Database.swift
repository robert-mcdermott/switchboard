import Foundation
import SQLite3
import SwitchboardCore

/// A thin layer over the SQLite that ships with macOS. Not thread-safe; `LogStore` keeps
/// every call on one queue.
final class Database {
    struct SQLiteError: Error, CustomStringConvertible {
        var message: String
        var description: String { "SQLite: \(message)" }
    }

    enum Value {
        case integer(Int64)
        case real(Double)
        case text(String)
        case null
    }

    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK
        else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(handle)
            throw SQLiteError(message: message)
        }
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit {
        statements.values.forEach { sqlite3_finalize($0) }
        sqlite3_close(handle)
    }

    private func fail() -> SQLiteError {
        SQLiteError(message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")
    }

    /// Runs statements that return nothing and take no values.
    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw fail() }
    }

    /// A prepared statement, compiled once and kept.
    private func statement(_ sql: String) throws -> OpaquePointer {
        if let cached = statements[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return cached
        }
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw fail() }
        statements[sql] = prepared
        return prepared
    }

    private func bind(_ values: [Value], to statement: OpaquePointer) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .integer(let number): sqlite3_bind_int64(statement, index, number)
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
    }

    /// Runs one statement with values. Returns the number of rows it changed.
    @discardableResult
    func run(_ sql: String, _ values: [Value] = []) throws -> Int {
        let statement = try statement(sql)
        bind(values, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw fail() }
        return Int(sqlite3_changes(handle))
    }

    var lastInsertedRow: Int64 { sqlite3_last_insert_rowid(handle) }

    /// A row being read. Valid only inside the `query` callback.
    struct Row {
        let statement: OpaquePointer

        func integer(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func real(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }

        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
    }

    /// Calls `body` for each row. Return false from it to stop early.
    func query(_ sql: String, _ values: [Value] = [], _ body: (Row) -> Bool) throws {
        let statement = try statement(sql)
        bind(values, to: statement)
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw fail() }
            if !body(Row(statement: statement)) { break }
        }
        sqlite3_reset(statement)
    }

    func scalar(_ sql: String, _ values: [Value] = []) throws -> Int64 {
        var result: Int64 = 0
        try query(sql, values) { row in
            result = row.integer(0)
            return false
        }
        return result
    }
}

extension Database.Value {
    init(_ binding: SQLBinding) {
        switch binding {
        case .text(let text): self = .text(text)
        case .integer(let number): self = .integer(number)
        }
    }

    init(_ text: String?) {
        self = text.map { .text($0) } ?? .null
    }
}
