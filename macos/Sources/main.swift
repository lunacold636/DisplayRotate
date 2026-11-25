import AppKit

/// 单实例：对 ~/Library/Application Support/DisplayRotate/.instance.lock 加排他锁
enum SingleInstance {
    private static var descriptor: Int32 = -1

    static func acquire() -> Bool {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DisplayRotate", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(".instance.lock").path
        descriptor = open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return true }
        return flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }
}

let arguments = CommandLine.arguments

if arguments.contains("--selftest") {
    SelfTest.run(includeRotation: arguments.contains("--rotate-test"))
}

guard SingleInstance.acquire() else {
    FileHandle.standardError.write(Data("DisplayRotate 已在运行。\n".utf8))
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate(arguments: arguments)
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
