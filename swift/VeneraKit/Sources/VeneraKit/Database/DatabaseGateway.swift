import Foundation
import SQLite3

// MARK: - 值类型

/// SQLite 值。与原版 sqlite3 Dart 包的动态取值语义对齐。
public enum SQLiteValue: Equatable, Sendable {
    case null
    case int(Int)
    case double(Double)
    case text(String)
    case blob(Data)

    public var intValue: Int? {
        switch self {
        case .int(let v): return Int(v)
        case .double(let v): return Int(v)
        case .text(let v): return Int(v)
        case .null: return nil
        default: return nil
        }
    }

    public var int64Value: Int64? {
        switch self {
        case .int(let v): return Int64(v)
        case .double(let v): return Int64(v)
        case .text(let v): return Int64(v)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        case .text(let v): return Double(v)
        default: return nil
        }
    }

    public var textValue: String? {
        switch self {
        case .text(let v): return v
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        default: return nil
        }
    }

    public var blobValue: Data? {
        switch self {
        case .blob(let v): return v
        case .text(let v): return Data(v.utf8)
        default: return nil
        }
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public static func from(_ any: Any?) -> SQLiteValue {
        switch any {
        case nil, is NSNull: return .null
        case let v as Int: return .int(v)
        case let v as Int32: return .int(Int(v))
        case let v as Int64: return .int(Int(v))
        case let v as Double: return .double(v)
        case let v as Bool: return .int(v ? 1 : 0)
        case let v as String: return .text(v)
        case let v as Data: return .blob(v)
        case let v as [UInt8]: return .blob(Data(v))
        default: return .text(String(describing: any!))
        }
    }
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let message: String
    public let code: Int32
    public init(code: Int32, message: String) {
        self.code = code
        self.message = message
    }
    public var description: String { "SQLiteError[\(code)]: \(message)" }
}

// MARK: - 单库连接

/// 单个 SQLite 文件连接。PRAGMA 与原版 sqlite_connection.dart 一致：
/// foreign_keys=ON, journal_mode=WAL, wal_autocheckpoint=200,
/// synchronous=NORMAL, busy_timeout=5000。
public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    public let path: String
    private var lock = NSRecursiveLock()

    public init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if !FileManager.default.fileExists(atPath: directory) {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        let result = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let opened = handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteError(code: result, message: String(cString: sqlite3_errmsg(handle ?? nil)))
        }
        self.handle = opened
        applyPragmas()
        // sqlite3_open 惰性打开；损坏文件要到首条语句才报错，此处主动探测。
        try lock.withLock {
            let probe = try prepare("select count(*) from sqlite_master;", [])
            defer { sqlite3_finalize(probe) }
            guard sqlite3_step(probe) == SQLITE_ROW else {
                throw SQLiteError(code: sqlite3_extended_errcode(opened), message: String(cString: sqlite3_errmsg(opened)))
            }
        }
    }

    deinit {
        close()
    }

    /// 显式关闭句柄（换库/恢复场景必须真正关闭，仅靠引用计数不够）。
    public func close() {
        lock.lock()
        if let handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
        lock.unlock()
    }

    private func applyPragmas() {
        executeRaw("PRAGMA foreign_keys = ON;")
        executeRaw("PRAGMA journal_mode = WAL;")
        executeRaw("PRAGMA wal_autocheckpoint = 200;")
        executeRaw("PRAGMA synchronous = NORMAL;")
        executeRaw("PRAGMA busy_timeout = 5000;")
    }

    public func executeRaw(_ sql: String) {
        var error: UnsafeMutablePointer<CChar>?
        sqlite3_exec(handle, sql, nil, nil, &error)
        if let error {
            let message = String(cString: error)
            sqlite3_free(error)
            Log.error("SQLite", "Failed to execute: \(sql.prefix(120)) - \(message)")
        }
    }

    public func execute(_ sql: String, _ parameters: [SQLiteValue] = []) throws {
        try lock.withLock {
            let statement = try prepare(sql, parameters)
            defer { sqlite3_finalize(statement) }
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE || result == SQLITE_ROW else {
                throw SQLiteError(code: sqlite3_extended_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    /// 查询返回行数组（列名 → 值）。
    public func select(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        try lock.withLock {
            let statement = try prepare(sql, parameters)
            defer { sqlite3_finalize(statement) }
            var rows: [[String: SQLiteValue]] = []
            let columnCount = sqlite3_column_count(statement)
            var columnNames: [String] = []
            for index in 0..<columnCount {
                columnNames.append(String(cString: sqlite3_column_name(statement, index)))
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                var row: [String: SQLiteValue] = [:]
                row.reserveCapacity(Int(columnCount))
                for index in 0..<columnCount {
                    row[columnNames[Int(index)]] = readColumn(statement, Int32(index))
                }
                rows.append(row)
            }
            return rows
        }
    }

    /// 查询返回第一行第一列（对应 Dart 的 selectSingleValue 场景）。
    public func selectValue(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> SQLiteValue? {
        try select(sql, parameters).first.flatMap { row in
            row.values.first
        }
    }

    /// 查询返回第一行。
    public func selectFirst(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> [String: SQLiteValue]? {
        try select(sql, parameters).first
    }

    /// WAL 检查点（TRUNCATE）：导出/恢复前调用，确保 -wal 内容并入主文件。
    public func checkpoint() {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }
        var log: Int32 = 0
        var checkpointed: Int32 = 0
        sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_TRUNCATE, &log, &checkpointed)
    }

    public func transaction(_ work: () throws -> Void) throws {
        try lock.withLock {
            try execute("BEGIN")
            do {
                try work()
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    public func tableColumns(_ table: String) throws -> [String] {
        let rows = try select("PRAGMA table_info(\(table));")
        return rows.compactMap { $0["name"]?.textValue }
    }

    public func tableExists(_ table: String) throws -> Bool {
        let rows = try select("SELECT name FROM sqlite_master WHERE type='table' AND name=?;", [.text(table)])
        return !rows.isEmpty
    }

    private func prepare(_ sql: String, _ parameters: [SQLiteValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw SQLiteError(code: sqlite3_extended_errcode(handle), message: "prepare failed: \(String(cString: sqlite3_errmsg(handle))) for \(sql.prefix(200))")
        }
        var index: Int32 = 1
        for parameter in parameters {
            switch parameter {
            case .null:
                sqlite3_bind_null(statement, index)
            case .int(let value):
                sqlite3_bind_int64(statement, index, Int64(value))
            case .double(let value):
                sqlite3_bind_double(statement, index, value)
            case .text(let value):
                sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            case .blob(let value):
                let count = Int32(value.count)
                if count > 0 {
                    _ = value.withUnsafeBytes { bytes in
                        sqlite3_bind_blob(statement, index, bytes.baseAddress, count, SQLITE_TRANSIENT)
                    }
                } else {
                    sqlite3_bind_zeroblob(statement, index, 0)
                }
            }
            index += 1
        }
        return statement
    }

    private func readColumn(_ statement: OpaquePointer?, _ index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: return .int(Int(sqlite3_column_int64(statement, index)))
        case SQLITE_FLOAT: return .double(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: text))
        case SQLITE_BLOB:
            guard let blob = sqlite3_column_blob(statement, index) else { return .null }
            let size = Int(sqlite3_column_bytes(statement, index))
            if size == 0 { return .blob(Data()) }
            return .blob(Data(bytes: blob, count: size))
        default: return .null
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

// MARK: - 网关（连接注册表）

/// 连接管理器：每个数据库文件持有唯一连接（对齐原版 DatabaseGateway），
/// 提供恢复/换库与独占访问。
public final class DatabaseGateway: @unchecked Sendable {
    public static let shared = DatabaseGateway()

    private let lock = NSLock()
    private var connections: [String: SQLiteDatabase] = [:]
    /// 递归锁：importAppData 的独占窗口内会再调 restoreDatabaseFiles。
    private let exclusiveLock = NSRecursiveLock()

    public init() {}

    public func openManaged(_ path: String) throws -> SQLiteDatabase {
        exclusiveLock.lock()
        defer { exclusiveLock.unlock() }
        lock.lock()
        if let existing = connections[path] {
            lock.unlock()
            return existing
        }
        lock.unlock()
        let connection = try SQLiteDatabase(path: path)
        lock.lock()
        connections[path] = connection
        lock.unlock()
        return connection
    }

    public func closeManaged(_ path: String) {
        lock.lock()
        let connection = connections.removeValue(forKey: path)
        lock.unlock()
        connection?.close()
    }

    /// 打开连接；损坏时把旧文件挪开并重建（对齐 cookie 库的自愈行为）。
    public func openManagedRecovering(_ path: String) -> SQLiteDatabase {
        do {
            return try openManaged(path)
        } catch {
            Log.error("SQLite", "Failed to open \(path), recreating: \(error)")
            Self.backupAsideCorruptDatabase(path)
            do {
                return try openManaged(path)
            } catch {
                Log.error("SQLite", "Failed to recreate \(path): \(error)")
                fatalError("Unable to open database: \(path)")
            }
        }
    }

    /// 导入/恢复期间的独占窗口。
    public func runExclusive<T>(_ work: () throws -> T) rethrows -> T {
        exclusiveLock.lock()
        defer { exclusiveLock.unlock() }
        return try work()
    }

    /// 关闭连接 → 原子替换文件 → 重新打开（对齐 restoreDatabaseFiles）。
    public func restoreDatabaseFiles(_ mapping: [String: String]) throws {
        try runExclusive {
            // 目标与源连接都必须先关闭，否则移动中的 WAL 文件会引发 I/O 错误。
            for target in mapping.keys {
                closeManaged(target)
            }
            for source in mapping.values {
                closeManaged(source)
            }
            let fileManager = FileManager.default
            for (target, source) in mapping {
                // 清理 WAL/SHM 侧车文件
                for suffix in ["-wal", "-shm"] {
                    FileIO.deleteIgnoringErrors(target + suffix)
                    FileIO.deleteIgnoringErrors(source + suffix)
                }
                if fileManager.fileExists(atPath: target) {
                    try? fileManager.removeItem(atPath: target)
                }
                if fileManager.fileExists(atPath: source) {
                    try fileManager.moveItem(atPath: source, toPath: target)
                }
            }
        }
    }

    /// 损坏库改名挪开（保留现场便于排查）。
    public static func backupAsideCorruptDatabase(_ path: String) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else { return }
        let timestamp = Int(Date().timeIntervalSince1970)
        let backup = "\(path).corrupt.\(timestamp)"
        try? fileManager.moveItem(atPath: path, toPath: backup)
        for suffix in ["-wal", "-shm"] {
            try? fileManager.moveItem(atPath: path + suffix, toPath: backup + suffix)
        }
        Log.info("SQLite", "Corrupt database moved aside: \(path) -> \(backup)")
    }
}
