import Foundation
import SQLite3

/// 必要最小限の SQLite ラッパー
enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case null

    var int: Int64? { if case .int(let v) = self { v } else { nil } }
    var double: Double? {
        switch self {
        case .double(let v): v
        case .int(let v): Double(v)
        default: nil
        }
    }
    var text: String? { if case .text(let v) = self { v } else { nil } }
}

extension Optional where Wrapped == String {
    var sql: SQLValue { map { .text($0) } ?? .null }
}

extension Optional where Wrapped == Date {
    var sql: SQLValue { map { .double($0.timeIntervalSince1970) } ?? .null }
}

struct SQLiteError: LocalizedError {
    let message: String
    var errorDescription: String? { "SQLite: \(message)" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteDB {
    private var db: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLiteError(message: msg)
        }
        sqlite3_busy_timeout(db, 3000)
    }

    deinit { sqlite3_close(db) }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(db) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(message: msg)
        }
    }

    @discardableResult
    func run(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error() }
        return Int(sqlite3_changes(db))
    }

    func query(_ sql: String, _ params: [SQLValue] = []) throws -> [[SQLValue]] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [[SQLValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error() }
            let count = sqlite3_column_count(stmt)
            rows.append((0..<count).map { i in
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: .double(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(stmt, i)))
                default: .null
                }
            })
        }
        return rows
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ params: [SQLValue]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw error() }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    private func error() -> SQLiteError {
        SQLiteError(message: String(cString: sqlite3_errmsg(db)))
    }
}
