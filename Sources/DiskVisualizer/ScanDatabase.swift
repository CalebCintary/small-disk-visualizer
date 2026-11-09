import Foundation
import SQLite3

private let sqliteStatic = unsafeBitCast(0, to: sqlite3_destructor_type.self)
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Temporary files for this process. Removed on quit; leftovers from a crash are
/// swept at the next launch.
enum ScanStorage {
    private static let prefix = "DiskVisualizer-"

    static let directory: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func newDatabaseURL() -> URL {
        directory.appendingPathComponent("scan-\(UUID().uuidString).sqlite")
    }

    static func removeCurrent() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func removeStale() {
        let temp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            guard let pid = Int32(name.dropFirst(prefix.count)), pid != getpid() else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH {
                try? FileManager.default.removeItem(at: temp.appendingPathComponent(name))
            }
        }
    }
}

struct DatabaseError: Error, CustomStringConvertible {
    let description: String
}

/// Rows from one or more directories, stored compactly until the writer takes them.
struct RowBatch {
    private(set) var ids: [Int64] = []
    private(set) var parents: [Int64] = []
    private(set) var sizes: [Int64] = []
    private(set) var nameEnds: [Int] = []
    private(set) var nameBytes: [UInt8] = []

    var count: Int { ids.count }

    /// `id` is the directory id, or 0 for a file.
    mutating func append<Name: Collection>(id: Int64, parent: Int64, size: Int64, name: Name)
    where Name.Element == UInt8 {
        ids.append(id)
        parents.append(parent)
        sizes.append(size)
        nameBytes.append(contentsOf: name)
        nameEnds.append(nameBytes.count)
    }
}

/// On-disk scan result. Bulk loading happens first, without indexes or journaling;
/// the file is disposable, so durability would only cost speed.
final class ScanDatabase: @unchecked Sendable {
    /// More rows than a folder view can usefully show.
    private static let maxChildren = 5000

    private let url: URL
    private var db: OpaquePointer?
    private var insertDirectory: OpaquePointer?
    private var insertFile: OpaquePointer?

    init(url: URL) throws {
        self.url = url
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw DatabaseError(description: "Не удалось создать временную базу")
        }
        try execute(
            """
            PRAGMA page_size = 8192;
            PRAGMA journal_mode = OFF;
            PRAGMA synchronous = OFF;
            PRAGMA locking_mode = EXCLUSIVE;
            PRAGMA cache_size = -16000;
            CREATE TABLE dirs(id INTEGER PRIMARY KEY, parent INTEGER NOT NULL, name TEXT NOT NULL, size INTEGER NOT NULL);
            CREATE TABLE files(parent INTEGER NOT NULL, name TEXT NOT NULL, size INTEGER NOT NULL);
            """)
        insertDirectory = try prepare("INSERT INTO dirs(id, parent, name, size) VALUES (?1, ?2, ?3, ?4)")
        insertFile = try prepare("INSERT INTO files(parent, name, size) VALUES (?1, ?2, ?3)")
    }

    deinit { close() }

    private func close() {
        sqlite3_finalize(insertDirectory)
        sqlite3_finalize(insertFile)
        insertDirectory = nil
        insertFile = nil
        sqlite3_close(db)
        db = nil
    }

    func destroy() {
        close()
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ batch: RowBatch) throws {
        try execute("BEGIN")
        try batch.nameBytes.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: CChar.self).baseAddress
            var start = 0
            for index in 0..<batch.count {
                let end = batch.nameEnds[index]
                let name = base.map { $0 + start }
                let length = Int32(end - start)
                start = end

                let id = batch.ids[index]
                let statement = id == 0 ? insertFile : insertDirectory
                var column: Int32 = 1
                if id != 0 {
                    sqlite3_bind_int64(statement, column, id)
                    column += 1
                }
                sqlite3_bind_int64(statement, column, batch.parents[index])
                sqlite3_bind_text(statement, column + 1, name, length, sqliteStatic)
                sqlite3_bind_int64(statement, column + 2, batch.sizes[index])

                guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
                sqlite3_reset(statement)
            }
        }
        try execute("COMMIT")
    }

    /// `sizes` is indexed by directory id; index 0 is unused.
    func finish(directorySizes sizes: [Int64]) throws {
        let update = try prepare("UPDATE dirs SET size = ?1 WHERE id = ?2")
        defer { sqlite3_finalize(update) }

        try execute("BEGIN")
        for id in 1..<sizes.count {
            sqlite3_bind_int64(update, 1, sizes[id])
            sqlite3_bind_int64(update, 2, Int64(id))
            guard sqlite3_step(update) == SQLITE_DONE else { throw lastError() }
            sqlite3_reset(update)
        }
        try execute("COMMIT")
        try execute(
            """
            CREATE INDEX dirs_parent ON dirs(parent, size);
            CREATE INDEX files_parent ON files(parent, size);
            """)
    }

    /// `path` is the directory's full path; children come back largest first.
    func loadDirectory(id: Int64, path: String, name: String, size: Int64) -> FileNode {
        var children: [FileNode] = []
        if let statement = try? prepare(
            """
            SELECT id, name, size FROM dirs WHERE parent = ?1
            UNION ALL
            SELECT NULL, name, size FROM files WHERE parent = ?1
            ORDER BY 3 DESC LIMIT \(Self.maxChildren)
            """)
        {
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, id)
            let prefix = path.hasSuffix("/") ? path : path + "/"
            while sqlite3_step(statement) == SQLITE_ROW {
                let childName = String(cString: sqlite3_column_text(statement, 1))
                let childID = sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 0)
                children.append(
                    FileNode(
                        path: prefix + childName, name: childName, size: sqlite3_column_int64(statement, 2),
                        directoryID: childID, children: []))
            }
        }
        return FileNode(path: path, name: name, size: size, directoryID: id, children: children)
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        return statement
    }

    private func lastError() -> DatabaseError {
        DatabaseError(description: String(cString: sqlite3_errmsg(db)))
    }
}
