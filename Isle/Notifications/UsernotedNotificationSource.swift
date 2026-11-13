import AppKit
import SQLite3

/// Optional fallback that reads delivered notifications from the usernoted
/// SQLite database. Off by default. Requires Full Disk Access on recent macOS,
/// and the schema is private and may change between releases.
///
/// Polls every 2 s for records newer than the highest `rec_id` seen at start.
final class UsernotedNotificationSource: NotificationSource {
    enum Status: Equatable {
        case stopped
        case running(path: String)
        case databaseNotFound
        case needsFullDiskAccess
        case error(String)

        var displayText: String {
            switch self {
            case .stopped: return "Off"
            case .running: return "Reading usernoted database"
            case .databaseNotFound: return "Database not found on this macOS version"
            case .needsFullDiskAccess: return "Needs Full Disk Access"
            case .error(let message): return "Error: \(message)"
            }
        }
    }

    let name = "usernoted database"

    private let queue = DispatchQueue(label: "com.wai.Isle.usernoted", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var database: OpaquePointer?
    private var lastRecordID: Int64 = 0
    private var _isRunning = false
    private var _handler: ((IslandNotification) -> Void)?
    private var _status: Status = .stopped
    /// Called on the main thread whenever `status` changes.
    var onStatusChange: ((Status) -> Void)?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isRunning
    }

    var status: Status {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }

    static var candidatePaths: [String] {
        var paths = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db").path
        ]
        let length = confstr(_CS_DARWIN_USER_DIR, nil, 0)
        if length > 0 {
            var buffer = [CChar](repeating: 0, count: length)
            if confstr(_CS_DARWIN_USER_DIR, &buffer, length) > 0 {
                let userDir = String(cString: buffer)
                paths.append((userDir as NSString).appendingPathComponent("com.apple.notificationcenter/db2/db"))
            }
        }
        return paths
    }

    func start(handler: @escaping (IslandNotification) -> Void) {
        lock.lock()
        _handler = handler
        _isRunning = true
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            guard self.openDatabase() else { return }
            self.lastRecordID = self.maxRecordID() ?? 0
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        lock.lock()
        _isRunning = false
        _handler = nil
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            if let database = self.database {
                sqlite3_close(database)
            }
            self.database = nil
            self.setStatus(.stopped)
        }
    }

    // MARK: Queue only

    private func setStatus(_ status: Status) {
        lock.lock()
        let changed = _status != status
        _status = status
        lock.unlock()
        guard changed else { return }
        FileLog.write("usernoted: \(status.displayText)")
        DispatchQueue.main.async { [weak self] in self?.onStatusChange?(status) }
    }

    private func openDatabase() -> Bool {
        let fileManager = FileManager.default
        var sawPermissionError = false
        for path in Self.candidatePaths {
            guard fileManager.fileExists(atPath: path) else {
                // fileExists returns false when a parent directory is unreadable (no Full Disk Access).
                let parent = (path as NSString).deletingLastPathComponent
                if !fileManager.isReadableFile(atPath: parent),
                   fileManager.fileExists(atPath: (parent as NSString).deletingLastPathComponent) {
                    sawPermissionError = true
                }
                continue
            }
            guard fileManager.isReadableFile(atPath: path) else {
                sawPermissionError = true
                continue
            }
            var handle: OpaquePointer?
            let uri = "file:\(path)?mode=ro"
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
            if sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK, let handle {
                sqlite3_busy_timeout(handle, 200)
                database = handle
                // Verify the expected schema is present.
                if maxRecordID() != nil {
                    setStatus(.running(path: path))
                    return true
                }
                sqlite3_close(handle)
                database = nil
                sawPermissionError = sawPermissionError || !fileManager.isReadableFile(atPath: path)
            } else {
                if let handle { sqlite3_close(handle) }
                sawPermissionError = true
            }
        }
        setStatus(sawPermissionError ? .needsFullDiskAccess : .databaseNotFound)
        return false
    }

    private func maxRecordID() -> Int64? {
        guard let database else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT IFNULL(MAX(rec_id), 0) FROM record", -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func poll() {
        guard isRunning, let database else { return }
        let sql = """
        SELECT r.rec_id, a.identifier, r.data
        FROM record r LEFT JOIN app a ON a.app_id = r.app_id
        WHERE r.rec_id > ? ORDER BY r.rec_id LIMIT 20
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(database))
            setStatus(.error(message))
            return
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, lastRecordID)

        var parsed: [IslandNotification] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let recordID = sqlite3_column_int64(statement, 0)
            lastRecordID = max(lastRecordID, recordID)
            let bundleID = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let byteCount = Int(sqlite3_column_bytes(statement, 2))
            guard byteCount > 0, let bytes = sqlite3_column_blob(statement, 2) else { continue }
            let data = Data(bytes: bytes, count: byteCount)
            if let notification = Self.parse(data: data, bundleID: bundleID) {
                parsed.append(notification)
            }
        }

        lock.lock()
        let handler = _handler
        lock.unlock()
        guard let handler, !parsed.isEmpty else { return }
        DispatchQueue.main.async {
            for notification in parsed {
                handler(notification)
            }
        }
    }

    /// The record blob is a binary plist: { app: bundleID, req: { titl, subt, body } }.
    static func parse(data: Data, bundleID: String?) -> IslandNotification? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        let request = plist["req"] as? [String: Any] ?? [:]
        let title = (request["titl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = request["subt"] as? String
        let body = request["body"] as? String
        let resolvedBundleID = bundleID ?? plist["app"] as? String
        let appName = resolvedBundleID.map(Self.displayName(forBundleID:)) ?? "Notification"
        let finalTitle = (title?.isEmpty == false ? title : nil) ?? appName
        guard !finalTitle.isEmpty || !(body ?? "").isEmpty else { return nil }
        return IslandNotification(
            bundleIdentifier: resolvedBundleID,
            appName: appName,
            title: finalTitle,
            subtitle: subtitle?.isEmpty == false ? subtitle : nil,
            body: body?.isEmpty == false ? body : nil,
            source: "usernoted"
        )
    }

    private static func displayName(forBundleID bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
