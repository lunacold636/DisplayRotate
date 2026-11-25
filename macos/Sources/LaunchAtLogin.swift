import Foundation

/// 开机自启：写入 ~/Library/LaunchAgents 的 LaunchAgent。
/// 只写文件、不立即 bootstrap，避免开启开关时立刻拉起第二个实例。
enum LaunchAtLogin {
    private static let label = "com.luyanjia.DisplayRotate.agent"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [executable, "--autostart"],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive",
                "LimitLoadToSessionType": "Aqua",
            ]
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try data.write(to: plistURL, options: .atomic)
            Log.info("已写入开机自启配置：\(plistURL.path)")
        } else {
            bootout()
            try? FileManager.default.removeItem(at: plistURL)
            Log.info("已移除开机自启配置")
        }
    }

    /// 卸载可能已注册的任务（未注册时会失败，忽略即可）
    static func bootout() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
