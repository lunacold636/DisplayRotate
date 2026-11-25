import Foundation

/// 设置存储：UserDefaults（对应 Windows 版的注册表）
enum Prefs {
    private static let store = UserDefaults.standard

    private enum Key {
        static let port = "port"
        static let portDescription = "portDescription"
        static let displayUUID = "displayUUID"
        static let autoStart = "autoStart"
        static let simulation = "simulation"
        static let landscapeDirection = "landscapeDirection"
        static let resetRotation = "resetRotation"
    }

    /// 上次使用的串口设备路径，例如 /dev/cu.usbserial-1130
    static var port: String {
        get { store.string(forKey: Key.port) ?? "" }
        set { store.set(newValue, forKey: Key.port) }
    }

    /// 设备描述（去掉端口号），串口号变化后据此重新识别传感器
    static var portDescription: String {
        get { store.string(forKey: Key.portDescription) ?? "" }
        set { store.set(newValue, forKey: Key.portDescription) }
    }

    /// 目标显示器 UUID（CGDirectDisplayID 会变，UUID 才稳定）
    static var displayUUID: String {
        get { store.string(forKey: Key.displayUUID) ?? "" }
        set { store.set(newValue, forKey: Key.displayUUID) }
    }

    static var autoStart: Bool {
        get { store.bool(forKey: Key.autoStart) }
        set { store.set(newValue, forKey: Key.autoStart) }
    }

    static var simulation: Bool {
        get { store.bool(forKey: Key.simulation) }
        set { store.set(newValue, forKey: Key.simulation) }
    }

    /// 一键复位的目标角度（度），默认 0°
    static var resetRotation: Int {
        get {
            if store.object(forKey: Key.resetRotation) == nil { return 0 }
            return store.integer(forKey: Key.resetRotation)
        }
        set { store.set(newValue, forKey: Key.resetRotation) }
    }

    /// 横屏 0° 时传感器朝上的是哪个方向（安装约定，默认 left，与 Windows 版一致）
    static var landscapeDirection: Int {
        get {
            if store.object(forKey: Key.landscapeDirection) == nil { return SensorDirection.left.rawValue }
            return store.integer(forKey: Key.landscapeDirection)
        }
        set { store.set(newValue, forKey: Key.landscapeDirection) }
    }
}
