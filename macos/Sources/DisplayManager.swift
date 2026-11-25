import AppKit
import CoreGraphics

// MARK: - 显示器信息

struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let uuid: String
    let name: String
    let isBuiltin: Bool
    let isMain: Bool
    let rotation: DisplayRotation
    let pointSize: CGSize
    let pixelSize: CGSize

    /// 内置屏在 Apple Silicon 上不支持旋转；外接屏一律先当作可尝试
    var rotationSupported: Bool { !isBuiltin }

    var displayName: String {
        let scale = pointSize.width > 0 ? pixelSize.width / pointSize.width : 1
        let suffix = scale >= 1.5 ? " · HiDPI" : ""
        let tag = isBuiltin ? " · 内置" : ""
        return "\(name)  \(Int(pointSize.width))×\(Int(pointSize.height))\(suffix)\(tag)"
    }

    static func == (lhs: DisplayInfo, rhs: DisplayInfo) -> Bool {
        lhs.id == rhs.id && lhs.rotation == rhs.rotation && lhs.uuid == rhs.uuid
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - 显示管理

/// 显示器枚举与旋转。旋转走私有 API `SLSSetDisplayRotation`（SkyLight）。
final class DisplayManager {
    typealias SetRotationFn = @convention(c) (CGDirectDisplayID, Int32) -> Int32

    private var handle: UnsafeMutableRawPointer?
    private var setRotationFn: SetRotationFn?
    /// 系统显示配置变化（旋转、插拔、分辨率切换）时回调
    var onReconfiguration: (() -> Void)?

    private static let reconfigurationCallback: CGDisplayReconfigurationCallBack = { _, _, context in
        guard let context else { return }
        let manager = Unmanaged<DisplayManager>.fromOpaque(context).takeUnretainedValue()
        manager.onReconfiguration?()
    }

    init() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
        handle = dlopen(path, RTLD_LAZY)
        if let handle, let symbol = dlsym(handle, "SLSSetDisplayRotation") {
            setRotationFn = unsafeBitCast(symbol, to: SetRotationFn.self)
            Log.info("已加载 SLSSetDisplayRotation")
        } else {
            Log.error("未找到 SLSSetDisplayRotation，旋转功能不可用")
        }
        CGDisplayRegisterReconfigurationCallback(
            DisplayManager.reconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(
            DisplayManager.reconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        if let handle { dlclose(handle) }
    }

    var isRotationAvailable: Bool { setRotationFn != nil }

    // MARK: 枚举

    func activeDisplays() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        return ids.prefix(Int(count)).map { id in
            let mode = CGDisplayCopyDisplayMode(id)
            let pointSize = CGSize(width: mode?.width ?? 0, height: mode?.height ?? 0)
            let pixelSize = CGSize(width: mode?.pixelWidth ?? 0, height: mode?.pixelHeight ?? 0)

            return DisplayInfo(
                id: id,
                uuid: uuid(for: id),
                name: name(for: id),
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                isMain: CGDisplayIsMain(id) != 0,
                rotation: currentRotation(of: id),
                pointSize: pointSize,
                pixelSize: pixelSize
            )
        }
    }

    /// 当前旋转角度（公开 API，只读）
    func currentRotation(of id: CGDirectDisplayID) -> DisplayRotation {
        DisplayRotation.from(degrees: CGDisplayRotation(id))
    }

    /// 显示器 UUID，跨重启稳定，用于持久化选择
    func uuid(for id: CGDirectDisplayID) -> String {
        guard let unmanaged = CGDisplayCreateUUIDFromDisplayID(id) else { return "" }
        let cfUUID = unmanaged.takeRetainedValue()
        guard let cfString = CFUUIDCreateString(nil, cfUUID) else { return "" }
        return cfString as String
    }

    private func name(for id: CGDirectDisplayID) -> String {
        for screen in NSScreen.screens {
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            if number?.uint32Value == id {
                return screen.localizedName
            }
        }
        return "显示器"
    }

    // MARK: 旋转

    /// 设置旋转角度。返回是否被系统接受（0 = kCGErrorSuccess）。
    @discardableResult
    func setRotation(of id: CGDirectDisplayID, to rotation: DisplayRotation) -> Bool {
        guard let setRotationFn else { return false }
        let code = setRotationFn(id, Int32(rotation.degrees))
        if code != 0 {
            Log.error("设置旋转失败：display=0x\(String(id, radix: 16)) \(rotation.degrees)° → CGError \(code)")
            return false
        }
        return true
    }
}
