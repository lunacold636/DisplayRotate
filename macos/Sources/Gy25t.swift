import Foundation

// MARK: - 方向与旋转

enum SensorDirection: Int, CaseIterable {
    case up = 0, right = 1, down = 2, left = 3, unknown = 9

    var label: String {
        switch self {
        case .up: return "上"
        case .right: return "右"
        case .down: return "下"
        case .left: return "左"
        case .unknown: return "--"
        }
    }
}

enum DisplayRotation: Int, CaseIterable {
    case r0 = 0, r90 = 90, r180 = 180, r270 = 270

    var degrees: Int { rawValue }

    var label: String { "\(rawValue)°" }

    static func from(degrees: Double) -> DisplayRotation {
        let rounded = Int(degrees.rounded())
        switch rounded {
        case 90: return .r90
        case 180: return .r180
        case 270: return .r270
        default: return .r0
        }
    }
}

/// 传感器方向 → 屏幕旋转 的固定映射（与 Windows 版一致：按循环序建立）
enum RotationMap {
    /// dirs 顺序固定为 上/右/下/左，对应 0/90/180/270
    static func build(landscape: SensorDirection) -> [SensorDirection: DisplayRotation] {
        let dirs: [SensorDirection] = [.up, .right, .down, .left]
        let rots: [DisplayRotation] = [.r0, .r90, .r180, .r270]
        guard let base = dirs.firstIndex(of: landscape) else { return [:] }
        var map: [SensorDirection: DisplayRotation] = [:]
        for i in 0..<4 {
            map[dirs[(base + i) % 4]] = rots[i]
        }
        return map
    }
}

// MARK: - GY-25T 协议解析

/// 移植自 Gy25t.cs：组帧/校验/加速度解析/方向判定，行为保持一致（线程安全）。
final class Gy25tParser {
    private enum Const {
        static let accWindow = 20
        static let xUp = -1   // 安装方向约定：X 轴 -1g = 上
        static let xDown = 1  // 安装方向约定：X 轴 +1g = 下
        static let confirmFrames = 20
    }

    private let lock = NSLock()
    private var rx: [UInt8] = []
    private var accX = [Int](repeating: 0, count: Const.accWindow)
    private var accY = [Int](repeating: 0, count: Const.accWindow)
    private var accZ = [Int](repeating: 0, count: Const.accWindow)
    private var accIndex = 0
    private var accCount = 0
    private var countMap: [SensorDirection: Int] = [:]

    private var _lastDirection: SensorDirection = .unknown
    private var _isReady = false
    private var _avgX = 0
    private var _avgY = 0
    private var _avgZ = 0
    private var _lastAccTime: Date = .distantPast
    private var _pendingCommand: [UInt8]?

    var lastDirection: SensorDirection {
        lock.lock()
        defer { lock.unlock() }
        return _lastDirection
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isReady
    }

    var avgX: Int {
        lock.lock()
        defer { lock.unlock() }
        return _avgX
    }

    var avgY: Int {
        lock.lock()
        defer { lock.unlock() }
        return _avgY
    }

    var avgZ: Int {
        lock.lock()
        defer { lock.unlock() }
        return _avgZ
    }

    var lastAccTime: Date {
        lock.lock()
        defer { lock.unlock() }
        return _lastAccTime
    }

    /// 等待应答的指令（由外部写入）
    var pendingCommand: [UInt8]? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _pendingCommand
        }
        set {
            lock.lock()
            _pendingCommand = newValue
            lock.unlock()
        }
    }

    /// 收到匹配应答时回调
    var onAck: (() -> Void)?
    /// 连接就绪状态变化
    var onReadyChanged: ((Bool) -> Void)?
    /// 方向确认（同方向连续 20 帧）
    var onDirection: ((SensorDirection) -> Void)?

    /// 刷新最近有效帧时间（初始化完成或系统休眠唤醒后给予宽限期）
    func touchWatchdog() {
        lock.lock()
        _lastAccTime = Date()
        lock.unlock()
    }

    /// 看门狗判定离线时同步清除就绪状态，确保后续恢复数据帧时能再次触发 onReadyChanged(true)
    func markOffline() {
        lock.lock()
        _isReady = false
        lock.unlock()
    }

    func reset() {
        lock.lock()
        rx.removeAll()
        accX = [Int](repeating: 0, count: Const.accWindow)
        accY = [Int](repeating: 0, count: Const.accWindow)
        accZ = [Int](repeating: 0, count: Const.accWindow)
        accIndex = 0
        accCount = 0
        countMap.removeAll()
        _lastDirection = .unknown
        _avgX = 0; _avgY = 0; _avgZ = 0
        _lastAccTime = .distantPast
        _pendingCommand = nil
        let wasReady = _isReady
        _isReady = false
        lock.unlock()

        if wasReady {
            onReadyChanged?(false)
        }
    }

    /// 喂入原始字节；内部按帧切分处理，所有外部回调均在锁外触发。
    func feed(_ data: Data) {
        var ackCount = 0
        var becameReady = false
        var directions: [SensorDirection] = []

        lock.lock()
        rx.append(contentsOf: data)
        while rx.count >= 5 {
            guard let start = rx.firstIndex(of: 0xA4) else {
                rx.removeAll()
                break
            }
            if start > 0 { rx.removeFirst(start) }
            guard rx.count >= 4 else { break }

            let function = rx[1]
            let total: Int
            if function == 0x03 {
                total = 5 + Int(rx[3])
            } else if function == 0x06 || function == 0x86 || function == 0x83 {
                total = 5
            } else {
                rx.removeFirst()
                continue
            }

            guard rx.count >= total else { break }
            let frame = Array(rx[0..<total])
            rx.removeFirst(total)
            handleLocked(
                frame: frame,
                ackCount: &ackCount,
                becameReady: &becameReady,
                directions: &directions
            )
        }
        lock.unlock()

        if ackCount > 0 {
            for _ in 0..<ackCount { onAck?() }
        }
        if becameReady {
            onReadyChanged?(true)
        }
        for direction in directions {
            onDirection?(direction)
        }
    }

    private func handleLocked(
        frame: [UInt8],
        ackCount: inout Int,
        becameReady: inout Bool,
        directions: inout [SensorDirection]
    ) {
        guard frame.count >= 2, frame[0] == 0xA4, checksumOK(frame) else { return }
        if handleWriteFeedbackLocked(frame) {
            ackCount += 1
            return
        }
        // 加速度帧：A4 03 08 06 + X/Y/Z 各 2 字节 + 校验
        if frame.count == 11, frame[1] == 0x03, frame[2] == 0x08, frame[3] == 0x06 {
            handleAccelerationLocked(frame, becameReady: &becameReady, directions: &directions)
        }
    }

    private func checksumOK(_ frame: [UInt8]) -> Bool {
        guard frame.count >= 2 else { return false }
        var sum: UInt8 = 0
        for byte in frame.dropLast() { sum = sum &+ byte }
        return sum == frame[frame.count - 1]
    }

    private func handleWriteFeedbackLocked(_ frame: [UInt8]) -> Bool {
        guard let pending = _pendingCommand, pending.count >= 4, frame.count >= 4 else { return false }
        if frame[1] == 0x03 || frame[1] == 0x06 {
            if frame[1] == pending[1], frame[2] == pending[2], frame[3] == pending[3] {
                return true
            }
        } else if frame[1] == 0x86 || frame[1] == 0x83 {
            return true
        }
        return false
    }

    private func handleAccelerationLocked(
        _ frame: [UInt8],
        becameReady: inout Bool,
        directions: inout [SensorDirection]
    ) {
        _lastAccTime = Date()
        if !_isReady {
            _isReady = true
            becameReady = true
        }

        let ix = Int(Int16(bitPattern: UInt16(frame[4]) << 8 | UInt16(frame[5]))) / 100
        let iy = Int(Int16(bitPattern: UInt16(frame[6]) << 8 | UInt16(frame[7]))) / 100
        let iz = Int(Int16(bitPattern: UInt16(frame[8]) << 8 | UInt16(frame[9]))) / 100

        if accCount < Const.accWindow { accCount += 1 }
        accIndex = (accIndex + 1) % Const.accWindow
        accX[accIndex] = ix
        accY[accIndex] = iy
        accZ[accIndex] = iz

        guard accCount > 0 else { return }
        var sx = 0, sy = 0, sz = 0
        for i in 0..<accCount {
            sx += accX[i]; sy += accY[i]; sz += accZ[i]
        }
        let qx = Int((Double(sx) / Double(accCount) / 160.0).rounded())
        let qy = Int((Double(sy) / Double(accCount) / 160.0).rounded())
        _avgX = Int((Double(sx) / Double(accCount)).rounded())
        _avgY = Int((Double(sy) / Double(accCount)).rounded())
        _avgZ = Int((Double(sz) / Double(accCount)).rounded())

        let direction = Self.direction(x: qx, y: qy)
        let count = countMap[direction] ?? 0
        if count == 0 {
            countMap.removeAll()
            countMap[direction] = 1
        } else {
            if count == Const.confirmFrames {
                _lastDirection = direction
                if direction != .unknown {
                    directions.append(direction)
                }
            }
            if count < 100 { countMap[direction] = count + 1 }
        }
    }

    static func direction(x: Int, y: Int) -> SensorDirection {
        if y == 1 { return .right }
        if y == -1 { return .left }
        if x == Const.xUp { return .up }
        if x == Const.xDown { return .down }
        return .unknown
    }
}

// MARK: - 指令

enum Gy25tCommand {
    static let initialize: [[UInt8]] = [
        hex("00 06 03 01 0A"), // 查询模式
        hex("00 06 07 53 60"), // 水平模式
        hex("00 06 02 01 09"), // 50Hz 上报
        hex("00 03 08 06 11"), // 读取加速度寄存器
        hex("00 06 03 00 09"), // 自动模式（开始持续上报）
        hex("00 06 05 55 60"), // 保存设置
    ]

    static func hex(_ string: String) -> [UInt8] {
        let cleaned = string.replacingOccurrences(of: " ", with: "")
        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            if let value = UInt8(cleaned[index..<next], radix: 16) {
                bytes.append(value)
            }
            index = next
        }
        return bytes
    }
}
