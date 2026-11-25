import Foundation

/// 无界面自检：验证私有 API、显示器枚举、协议解析、去抖与映射。
/// 用法：DisplayRotate --selftest [--rotate-test]
enum SelfTest {
    static func run(includeRotation: Bool) {
        var failures = 0

        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            let suffix = detail.isEmpty ? "" : "  — \(detail)"
            print((condition ? "PASS" : "FAIL") + "  " + name + suffix)
            if !condition { failures += 1 }
        }

        print("== DisplayRotate 自检 ==\n")

        let manager = DisplayManager()
        check("私有符号 SLSSetDisplayRotation 可用", manager.isRotationAvailable)

        let displays = manager.activeDisplays()
        check("枚举到活动显示器", !displays.isEmpty, "\(displays.count) 个")
        for display in displays {
            let kind = display.isBuiltin ? "内置" : "外接"
            print("      \(display.name) [\(kind)] \(Int(display.pointSize.width))×\(Int(display.pointSize.height))"
                + " 像素 \(Int(display.pixelSize.width))×\(Int(display.pixelSize.height))"
                + " 当前 \(display.rotation.label) 可旋转=\(display.rotationSupported)")
        }

        // 协议解析：Y 轴 -1g → 左
        let parser = Gy25tParser()
        var direction: SensorDirection?
        parser.onDirection = { direction = $0 }
        // 首帧窗口平均为 0（方向未知），之后连续同向 20 帧才确认 → 共需 22 帧
        for _ in 0..<22 { parser.feed(frame(x: 16, y: -162, z: 6)) }
        check("加速度帧解析出方向 = 左", direction == .left, "实际 \(direction?.label ?? "nil")")

        // 去抖：20 帧内不应触发
        let debounceParser = Gy25tParser()
        var events = 0
        debounceParser.onDirection = { _ in events += 1 }
        for _ in 0..<21 { debounceParser.feed(frame(x: 16, y: -162, z: 6)) }
        check("21 帧内未提前触发（去抖生效）", events == 0, "触发 \(events) 次")

        // 映射表
        let map = RotationMap.build(landscape: .left)
        check("映射 左 → 0°", map[.left] == .r0)
        check("映射 上 → 90°", map[.up] == .r90)
        check("映射 右 → 180°", map[.right] == .r180)
        check("映射 下 → 270°", map[.down] == .r270)

        // 串口枚举（无设备时应为空，不算失败）
        let ports = SerialEnumerator.devices()
        print("      发现串口：\(ports.isEmpty ? "无" : ports.map { $0.displayName }.joined(separator: ", "))")

        if includeRotation, let target = displays.first(where: { !$0.isBuiltin && $0.rotationSupported }) {
            print("\n== 旋转实测：\(target.name) ==")
            let before = manager.currentRotation(of: target.id)
            let applied = manager.setRotation(of: target.id, to: .r90)
            Thread.sleep(forTimeInterval: 1.2)
            let after = manager.currentRotation(of: target.id)
            _ = manager.setRotation(of: target.id, to: before)
            Thread.sleep(forTimeInterval: 1.2)
            let restored = manager.currentRotation(of: target.id)
            check("旋转到 90°", applied && after == .r90, "实际 \(after.label)")
            check("恢复原角度 \(before.label)", restored == before, "实际 \(restored.label)")

            // 一键复位链路：先转到 90°，再用引擎复位回基准 0°
            _ = manager.setRotation(of: target.id, to: .r90)
            Thread.sleep(forTimeInterval: 1.2)
            let engine = RotationEngine()
            engine.refreshDisplays()
            let resetOK = engine.resetRotation()
            Thread.sleep(forTimeInterval: 1.2)
            let afterReset = manager.currentRotation(of: target.id)
            let baseline = DisplayRotation(rawValue: Prefs.resetRotation) ?? .r0
            check("一键复位到 \(baseline.label)", resetOK && afterReset == baseline, "实际 \(afterReset.label)")
        }

        print(failures == 0 ? "\n全部通过" : "\n\(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }

    /// 构造一帧加速度数据；入参单位为 0.01g（1g ≈ 160）
    private static func frame(x: Int, y: Int, z: Int) -> Data {
        func int16(_ value: Int) -> [UInt8] {
            let raw = UInt16(bitPattern: Int16(clamping: value * 100))
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        }
        var bytes: [UInt8] = [0xA4, 0x03, 0x08, 0x06]
        bytes += int16(x)
        bytes += int16(y)
        bytes += int16(z)
        bytes.append(bytes.reduce(UInt8(0)) { $0 &+ $1 })
        return Data(bytes)
    }
}
