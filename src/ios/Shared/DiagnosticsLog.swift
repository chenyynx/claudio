import Foundation

/// [Claudio 2026-09-06 DEBUG-CAPTURE] Append-mode file logger for diagnosis.
///
/// Why this exists: AppLogger → NSLog (system log, needs Xcode Console.app to
/// read); CrashReporter → in-memory ring buffer (20 entries, dies on relaunch).
/// Neither is reachable from an iPhone alone — pp has no Mac in the loop. This
/// helper writes to a sandbox file at `Documents/claudio/claudio.log` so pp
/// can pull it from iPhone Files app → "On My iPhone" → Claudio →
/// claudio.log → long-press → Share to WeChat (允真通道).
///
/// Caller MUST NOT throw on write failure — diagnostic only, never affects
/// the main upload flow.
struct DiagnosticsLog {
    static let shared = DiagnosticsLog()

    private let url: URL?
    private let queue = DispatchQueue(label: "com.claudio.diagnostics")

    private init() {
        let fm = FileManager.default
        guard let docs = try? fm.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            self.url = nil
            return
        }
        let dir = docs.appendingPathComponent("claudio", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            self.url = nil
            return
        }
        self.url = dir.appendingPathComponent("claudio.log")
    }

    /// Append one line to the diagnostic log.
    ///
    /// - Parameters:
    ///   - tag: short label like "RemoteFileUpload" or "RemoteAgentProvider"
    ///   - message: free-form string (interpolation cost is paid only at call site)
    ///   - file: auto-captured source file (override only for tests)
    ///   - line: auto-captured source line (override only for tests)
    func write(_ tag: String, _ message: @autoclosure () -> String,
               file: String = #fileID, line: Int = #line) {
        let resolved = message()
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] [\(tag)] [\(file):\(line)] \(resolved)\n"
        guard let url = url, let data = line.data(using: .utf8) else { return }
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: data)
            } else {
                _ = try? data.write(to: url)
            }
        }
    }
}