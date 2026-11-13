import Foundation

/// Runs AppleScript against Apple Music on a private serial queue so the main
/// thread never blocks on Apple Events. Scripts are compiled once and reused.
final class AppleScriptRunner {
    enum ScriptError: Error, Equatable {
        /// errAEEventNotPermitted (-1743): the user denied Automation access.
        case notAuthorized
        /// The target app is not running (we never launch it implicitly).
        case appNotRunning
        case compileFailed(String)
        case executionFailed(code: Int, message: String)
    }

    private let queue = DispatchQueue(label: "com.wai.Isle.applescript", qos: .userInitiated)
    private var compiled: [String: NSAppleScript] = [:]

    /// Executes `source` off the main thread and calls `completion` on the main queue.
    /// Pass `cache: false` for one-off scripts with interpolated values (e.g. seek positions).
    func run(_ source: String, cache: Bool = true,
             completion: @escaping (Result<NSAppleEventDescriptor, ScriptError>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.execute(source, cache: cache)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    /// Executes `source` off the main thread, ignoring the result.
    func runIgnoringResult(_ source: String, cache: Bool = true, then completion: @escaping (ScriptError?) -> Void) {
        run(source, cache: cache) { result in
            switch result {
            case .success: completion(nil)
            case .failure(let error): completion(error)
            }
        }
    }

    /// Runs on `queue` only.
    private func execute(_ source: String, cache: Bool) -> Result<NSAppleEventDescriptor, ScriptError> {
        let script: NSAppleScript
        if let cached = compiled[source] {
            script = cached
        } else {
            guard let created = NSAppleScript(source: source) else {
                return .failure(.compileFailed("Could not create script"))
            }
            var compileError: NSDictionary?
            if !created.compileAndReturnError(&compileError) {
                let message = compileError?[NSAppleScript.errorMessage] as? String ?? "Unknown compile error"
                return .failure(.compileFailed(message))
            }
            if cache {
                compiled[source] = created
            }
            script = created
        }

        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            if code == -1743 {
                return .failure(.notAuthorized)
            }
            // -600: application isn't running.
            if code == -600 {
                return .failure(.appNotRunning)
            }
            return .failure(.executionFailed(code: code, message: message))
        }
        return .success(descriptor)
    }
}

extension NSAppleEventDescriptor {
    /// 1-based list item as a string, or nil when missing/empty.
    func stringItem(_ index: Int) -> String? {
        guard index <= numberOfItems, let value = atIndex(index)?.stringValue, !value.isEmpty else { return nil }
        return value
    }

    func doubleItem(_ index: Int) -> Double? {
        guard index <= numberOfItems, let item = atIndex(index) else { return nil }
        let value = item.doubleValue
        return value.isFinite ? value : nil
    }
}
