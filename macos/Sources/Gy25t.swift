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
    /// dirs 顺序固定为 上/右/下/左
    /// - reversed = false：0/90/180/270（顺时针递增）
    /// - reversed = true ：0/270/180/90（逆时针递增，90° 与 270° 互换）
    static func build(landscape: SensorDirection, reversed: Bool = false) -> [SensorDirection: DisplayRotation] {
        let dirs: [SensorDirection] = [.up, .right, .down, .left]
        let rots: [DisplayRotation] = reversed
            ? [.r0, .r270, .r180, .r90]
            : [.r0, .r90, .r180, .r270]
        guard let base = dirs.firstIndex(of: landscape) else { return [:] }
        var map: [SensorDirection: DisplayRotation] = [:]
        for i in 0..<4 {
            map[dirs[(base + i) % 4]] = rots[i]
        }
        return map
    }
}

// MARK: - GY-25T 协议解析

/// 移植自 Gy25t.cs：组帧/校验/加速度解析/方向判定，行为保持一致。
final class Gy25tParser {
    private enum Const {
        static let accWindow = 20
        static let xUp = -1   // 安装方向约定：X 轴 -1g = 上
        static let xDown = 1  // 安装方向约定：X 轴 +1g = 下
        static let confirmFrames = 20
    }

    private var rx: [UInt8] = []
    private var accX = [Int](repeating: 0, count: Const.accWindow)
    private var accY = [Int](repeating: 0, count: Const.accWindow)
    private var accZ = [Int](repeating: 0, count: Const.accWindow)
    private var accIndex = 0
    private var accCount = 0
    private var countMap: [SensorDirection: Int] = [:]

    private(set) var lastDirection: SensorDirection = .unknown
    private(set) var isReady = false
    private(set) var avgX = 0
    private(set) var avgY = 0
    private(set) var avgZ = 0
    private(set) var lastAccTime: Date = .distantPast

    /// 等待应答的指令（由外部写入）
    var pendingCommand: [UInt8]?
    /// 收到匹配应答时回调
    var onAck: (() -> Void)?
    /// 连接就绪状态变化
    var onReadyChanged: ((Bool) -> Void)?
    /// 方向确认（同方向连续 20 帧）
    var onDirection: ((SensorDirection) -> Void)?

    func reset() {
        rx.removeAll()
        accX = [Int](repeating: 0, count: Const.accWindow)
        accY = [Int](repeating: 0, count: Const.accWindow)
        accZ = [Int](repeating: 0, count: Const.accWindow)
        accIndex = 0
        accCount = 0
        countMap.removeAll()
        lastDirection = .unknown
        avgX = 0; avgY = 0; avgZ = 0
        lastAccTime = .distantPast
        if isReady {
            isReady = false
            onReadyChanged?(false)
        }
    }

    /// 喂入原始字节；内部按帧切分处理。
    func feed(_ data: Data) {
        rx.append(contentsOf: data)
        while rx.count >= 5 {
            guard let start = rx.firstIndex(of: 0xA4) else {
                rx.removeAll()
                return
            }
            if start > 0 { rx.removeFirst(start) }
            guard rx.count >= 4 else { return }

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

            guard rx.count >= total else { return }
            let frame = Array(rx[0..<total])
            rx.removeFirst(total)
            handle(frame: frame)
        }
    }

    private func handle(frame: [UInt8]) {
        guard frame.count >= 2, frame[0] == 0xA4, checksumOK(frame) else { return }
        if handleWriteFeedback(frame) { return }
        // 加速度帧：A4 03 08 06 + X/Y/Z 各 2 字节 + 校验
        if frame.count == 11, frame[1] == 0x03, frame[2] == 0x08, frame[3] == 0x06 {
            handleAcceleration(frame)
        }
    }

    private func checksumOK(_ frame: [UInt8]) -> Bool {
        guard frame.count >= 2 else { return false }
        var sum: UInt8 = 0
        for byte in frame.dropLast() { sum = sum &+ byte }
        return sum == frame[frame.count - 1]
    }

    private func handleWriteFeedback(_ frame: [UInt8]) -> Bool {
        guard let pending = pendingCommand, pending.count >= 4, frame.count >= 4 else { return false }
        if frame[1] == 0x03 || frame[1] == 0x06 {
            if frame[1] == pending[1], frame[2] == pending[2], frame[3] == pending[3] {
                onAck?()
                return true
            }
        } else if frame[1] == 0x86 || frame[1] == 0x83 {
            onAck?()
            return true
        }
        return false
    }

    private func handleAcceleration(_ frame: [UInt8]) {
        lastAccTime = Date()
        if !isReady {
            isReady = true
            onReadyChanged?(true)
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
        avgX = Int((Double(sx) / Double(accCount)).rounded())
        avgY = Int((Double(sy) / Double(accCount)).rounded())
        avgZ = Int((Double(sz) / Double(accCount)).rounded())

        let direction = Self.direction(x: qx, y: qy)
        let count = countMap[direction] ?? 0
        if count == 0 {
            countMap.removeAll()
            countMap[direction] = 1
        } else {
            if count == Const.confirmFrames {
                lastDirection = direction
                if direction != .unknown {
                    onDirection?(direction)
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
