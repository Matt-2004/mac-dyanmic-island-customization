import ApplicationServices
import Foundation

/// Writes the Notification Center accessibility tree to
/// `~/Library/Logs/Isle/ax-dump.txt` so banner parsing can be tuned.
/// Only used when the user enables debug dump mode (the file contains
/// notification text). Call from the AX worker thread.
final class AXTreeDumper {
    static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Isle", isDirectory: true)
    }

    static var dumpFileURL: URL {
        logDirectory.appendingPathComponent("ax-dump.txt")
    }

    private let maxFileSize: UInt64 = 5 * 1024 * 1024
    private let maxDepth = 25
    private let maxNodes = 4000
    private var lastTreeSignature: Int?
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Renders `root` (the Notification Center app element) as indented text.
    func render(root: AXUIElement) -> String {
        var lines: [String] = []
        var count = 0
        walk(root, depth: 0, lines: &lines, count: &count)
        if count >= maxNodes {
            lines.append("… truncated after \(maxNodes) nodes")
        }
        return lines.joined(separator: "\n")
    }

    /// Appends a dump if the tree changed since the last one (or `force` is set).
    /// Returns true when something was written.
    @discardableResult
    func dumpIfChanged(root: AXUIElement, reason: String, extra: String? = nil, force: Bool = false) -> Bool {
        let tree = render(root: root)
        let signature = tree.hashValue
        guard force || signature != lastTreeSignature else { return false }
        lastTreeSignature = signature

        var text = "===== \(timestampFormatter.string(from: Date())) — \(reason) =====\n"
        text += tree
        text += "\n"
        if let extra {
            text += "--- parser ---\n\(extra)\n"
        }
        text += "\n"
        append(text)
        return true
    }

    private func walk(_ element: AXUIElement, depth: Int, lines: inout [String], count: inout Int) {
        guard count < maxNodes else { return }
        count += 1
        lines.append(String(repeating: "  ", count: depth) + describe(element))
        guard depth < maxDepth else {
            lines.append(String(repeating: "  ", count: depth + 1) + "… max depth")
            return
        }
        for child in AX.children(element) {
            walk(child, depth: depth + 1, lines: &lines, count: &count)
        }
    }

    private func describe(_ element: AXUIElement) -> String {
        var parts: [String] = [AX.role(element) ?? "?"]
        if let subrole = AX.subrole(element) { parts.append("subrole=\(subrole)") }
        if let identifier = AX.identifier(element) { parts.append("id=\(quoted(identifier))") }
        if let title = AX.string(element, kAXTitleAttribute) { parts.append("title=\(quoted(title))") }
        if let description = AX.string(element, kAXDescriptionAttribute) { parts.append("desc=\(quoted(description))") }
        if let value = AX.string(element, kAXValueAttribute) { parts.append("value=\(quoted(value))") }
        if let help = AX.string(element, kAXHelpAttribute) { parts.append("help=\(quoted(help))") }
        if let frame = AX.frame(element) {
            parts.append(String(format: "frame=(%.0f,%.0f %.0fx%.0f)", frame.minX, frame.minY, frame.width, frame.height))
        }
        let actions = AX.actions(element)
        if !actions.isEmpty {
            parts.append("actions=[\(actions.joined(separator: ","))]")
        }
        return parts.joined(separator: " ")
    }

    private func quoted(_ string: String) -> String {
        let flattened = string.replacingOccurrences(of: "\n", with: "⏎")
        let clipped = flattened.count > 200 ? String(flattened.prefix(200)) + "…" : flattened
        return "\"\(clipped)\""
    }

    private func append(_ text: String) {
        let fileManager = FileManager.default
        let url = Self.dumpFileURL
        do {
            try fileManager.createDirectory(at: Self.logDirectory, withIntermediateDirectories: true)
            if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? UInt64, size > maxFileSize {
                let rotated = Self.logDirectory.appendingPathComponent("ax-dump.1.txt")
                try? fileManager.removeItem(at: rotated)
                try fileManager.moveItem(at: url, to: rotated)
            }
            guard let data = text.data(using: .utf8) else { return }
            if fileManager.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            NSLog("Isle: failed to write AX dump: \(error.localizedDescription)")
        }
    }
}
