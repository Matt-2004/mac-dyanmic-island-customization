import Foundation

/// Minimal append-only diagnostics log at ~/Library/Logs/Isle/isle.log.
/// Never logs notification contents — only events and app names.
enum FileLog {
    private static let queue = DispatchQueue(label: "com.wai.Isle.filelog", qos: .utility)
    private static let maxSize: UInt64 = 1024 * 1024

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Isle/isle.log")
    }

    /// Unit tests run inside the app; keep their fake events out of the real log.
    private static let isDisabled = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static func write(_ message: String) {
        guard !isDisabled else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            let fileManager = FileManager.default
            let url = Self.url
            do {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > maxSize {
                    try? fileManager.removeItem(at: url)
                }
                guard let data = line.data(using: .utf8) else { return }
                if fileManager.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: url)
                }
            } catch {
                NSLog("Isle FileLog failed: \(error.localizedDescription)")
            }
        }
    }
}
