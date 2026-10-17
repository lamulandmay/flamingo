import Foundation
import SQLite3

/// A SQLite failure, with the engine's own message.
public struct IndexError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public var description: String { "sqlite \(code): \(message)" }
    public var errorDescription: String? { description }
    /// The file isn't a usable database (as opposed to busy, locked, or a disk error).
    var isCorrupt: Bool { code & 0xff == SQLITE_CORRUPT || code & 0xff == SQLITE_NOTADB }
    var isBusy: Bool { code & 0xff == SQLITE_BUSY || code & 0xff == SQLITE_LOCKED }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

protocol SQLBindable {
    func bind(to stmt: OpaquePointer, at index: Int32) -> Int32
}

extension String: SQLBindable {
    /// Explicit byte length, so an embedded NUL can't cut the value short.
    func bind(to stmt: OpaquePointer, at index: Int32) -> Int32 {
        var s = self
        return s.withUTF8 { buf in
            guard let base = buf.baseAddress, !buf.isEmpty else { return sqlite3_bind_text(stmt, index, "", 0, SQLITE_TRANSIENT) }
            return base.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                sqlite3_bind_text(stmt, index, $0, Int32(buf.count), SQLITE_TRANSIENT)
            }
        }
    }
}
extension Int: SQLBindable {
    func bind(to stmt: OpaquePointer, at index: Int32) -> Int32 { sqlite3_bind_int64(stmt, index, Int64(self)) }
}
extension Double: SQLBindable {
    func bind(to stmt: OpaquePointer, at index: Int32) -> Int32 { sqlite3_bind_double(stmt, index, self) }
}
extension Data: SQLBindable {
    func bind(to stmt: OpaquePointer, at index: Int32) -> Int32 {
        withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
    }
}

/// One connection. Not thread-safe; `IndexStore` serializes access with locks.
final class Database {
    let handle: OpaquePointer
    private var cache: [String: Statement] = [:]

    init(path: String, readOnly: Bool = false) throws {
        var h: OpaquePointer?
        let rc = sqlite3_open_v2(path, &h, (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let h else {
            let message = h.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close_v2(h)
            throw IndexError(code: rc, message: message)
        }
        handle = h
        sqlite3_busy_timeout(h, 10_000)
    }

    deinit {
        cache.removeAll()
        sqlite3_close_v2(handle)
    }

    var lastError: IndexError { IndexError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle))) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw IndexError(code: rc, message: message)
        }
    }

    /// Prepared statements are cached by SQL text and reset on reuse. If the cached one is
    /// mid-query (a row closure running the same SQL), a fresh uncached one is returned.
    func prepare(_ sql: String) throws -> Statement {
        if let s = cache[sql] {
            if !s.busy { s.reset(); return s }
            return try compile(sql, persistent: false)
        }
        // Scoped queries vary by folder. Keep cached statement memory bounded as users
        // navigate a large vault; in-flight statements remain retained by their caller.
        if cache.count >= 128 { cache = cache.filter { $0.value.busy } }
        let s = try compile(sql, persistent: true)
        cache[sql] = s
        return s
    }

    private func compile(_ sql: String, persistent: Bool) throws -> Statement {
        var stmt: OpaquePointer?
        let flags = persistent ? UInt32(SQLITE_PREPARE_PERSISTENT) : 0
        guard sqlite3_prepare_v3(handle, sql, -1, flags, &stmt, nil) == SQLITE_OK, let stmt else {
            throw lastError
        }
        return Statement(stmt, db: self)
    }

    func run(_ sql: String, _ values: (any SQLBindable)?...) throws {
        try prepare(sql).run(values)
    }

    func query<T>(_ sql: String, _ values: (any SQLBindable)?..., row: (Row) throws -> T) throws -> [T] {
        try prepare(sql).query(values, row: row)
    }

    func scalarInt(_ sql: String, _ values: (any SQLBindable)?...) throws -> Int {
        try prepare(sql).query(values) { $0.int(0) }.first ?? 0
    }

    /// `BEGIN IMMEDIATE`, or a savepoint when already inside a transaction.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        let nested = sqlite3_get_autocommit(handle) == 0
        try exec(nested ? "SAVEPOINT nested" : "BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec(nested ? "RELEASE nested" : "COMMIT")
            return result
        } catch {
            try? exec(nested ? "ROLLBACK TO nested; RELEASE nested" : "ROLLBACK")
            throw error
        }
    }

    /// A consistent snapshot across several reads (WAL readers see one commit throughout).
    func snapshot<T>(_ body: () throws -> T) throws -> T {
        guard sqlite3_get_autocommit(handle) != 0 else { return try body() }
        try exec("BEGIN DEFERRED")
        defer { try? exec("COMMIT") }
        return try body()
    }

    func userVersion() throws -> Int { try scalarInt("PRAGMA user_version") }
}

final class Statement {
    let handle: OpaquePointer
    unowned let db: Database
    private(set) var busy = false

    init(_ handle: OpaquePointer, db: Database) { self.handle = handle; self.db = db }
    deinit { sqlite3_finalize(handle) }

    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    func bind(_ values: [(any SQLBindable)?]) throws {
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            let rc = v.map { $0.bind(to: handle, at: idx) } ?? sqlite3_bind_null(handle, idx)
            if rc != SQLITE_OK { throw db.lastError }
        }
    }

    func run(_ values: [(any SQLBindable)?]) throws {
        busy = true
        defer { reset(); busy = false }
        try bind(values)
        let rc = sqlite3_step(handle)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw db.lastError }
    }

    func query<T>(_ values: [(any SQLBindable)?], row: (Row) throws -> T) throws -> [T] {
        busy = true
        defer { reset(); busy = false }
        try bind(values)
        var out: [T] = []
        while true {
            let rc = sqlite3_step(handle)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw db.lastError }
            out.append(try row(Row(handle: handle)))
        }
        return out
    }
}

struct Row {
    let handle: OpaquePointer
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(handle, i) == SQLITE_NULL }
    func string(_ i: Int32) -> String { sqlite3_column_text(handle, i).map { String(cString: $0) } ?? "" }
    func optionalString(_ i: Int32) -> String? { isNull(i) ? nil : string(i) }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(handle, i)) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(handle, i) }
    func data(_ i: Int32) -> Data {
        let n = Int(sqlite3_column_bytes(handle, i))
        guard n > 0, let p = sqlite3_column_blob(handle, i) else { return Data() }
        return Data(bytes: p, count: n)
    }
}
