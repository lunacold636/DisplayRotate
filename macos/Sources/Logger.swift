import Foundation

/// 轻量文件日志：~/Library/Logs/DisplayRotate/DisplayRotate.log
enum Log {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library")
        return base.appendingPathComponent("Logs/DisplayRotate", isDirectory: true)
    }()

    static var fileURL: URL { directory.appendingPathComponent("DisplayRotate.log") }

    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let maxBytes = 1_048_576

    static func info(_ message: String) { write("INFO", message) }

    static func error(_ message: String, _ error: Error? = nil) {
        if let error {
            write("ERROR", "\(message): \(error.localizedDescription)")
        } else {
            write("ERROR", message)
        }
    }

    private static func write(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        lock.lock()
        defer { lock.unlock() }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        rotateIfNeeded()

        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
        FileHandle.standardError.write(data)
    }

    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int, size > maxBytes else { return }
        let backup = directory.appendingPathComponent("DisplayRotate.log.1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: fileURL, to: backup)
    }
}
