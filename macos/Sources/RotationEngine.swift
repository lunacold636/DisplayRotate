import Foundation

/// 旋转引擎：串口 + 协议 + 方向映射 + 屏幕旋转，行为对齐 Windows 版 MainForm。
/// 除串口 I/O 外，所有状态变更都在主线程完成。
final class RotationEngine {
    // 与 Windows 版一致的时序参数
    private enum Timing {
        static let pollInterval: TimeInterval = 0.5      // 状态轮询周期
        static let rotateCooldown: TimeInterval = 2.0    // 旋转后抑制窗口
        static let watchdogPeriod: TimeInterval = 1.0    // 看门狗检查周期
        static let watchdogTimeout: TimeInterval = 5.0   // 超过 5 秒无有效帧判定离线
        static let reconnectBase: TimeInterval = 2.0     // 自动重连起始间隔
        static let reconnectMax: TimeInterval = 60.0     // 重连退避封顶
        static let commandTimeout: TimeInterval = 3.0    // 单条指令等待应答
    }

    // MARK: 依赖

    let displayManager = DisplayManager()
    private let parser = Gy25tParser()
    private let ioQueue = DispatchQueue(label: "com.luyanjia.DisplayRotate.serial")
    private let stateLock = NSLock()
    private var ackSemaphore = DispatchSemaphore(value: 0)

    // MARK: 对外状态

    private(set) var displays: [DisplayInfo] = []
    private(set) var ports: [SerialDevice] = []
    private(set) var isConnected = false
    private(set) var isReady = false
    private(set) var lastDirection: SensorDirection = .unknown
    private(set) var appliedRotation: DisplayRotation = .r0
    private(set) var targetDisplay: DisplayInfo?
    private(set) var simulationEnabled = false

    var onChange: (() -> Void)?

    // MARK: 内部状态

    private var port: SerialPort?
    private var readLoopActive = false
    private var rotateMap: [SensorDirection: DisplayRotation] = [:]
    private var lastRotateAt = Date.distantPast
    private var pollTimer: Timer?
    private var watchdogTimer: Timer?
    private var reconnectTimer: Timer?
    private var simulateTimer: Timer?
    private var simulateIndex = 0
    private var reconnectAttempts = 0
    private var reconnectEnabled = false
    private var manualClose = false
    private var initializing = false

    // MARK: 生命周期

    func start() {
        rotateMap = RotationMap.build(
            landscape: SensorDirection(rawValue: Prefs.landscapeDirection) ?? .left,
            reversed: Prefs.reverseRotation
        )
        refreshPorts()
        refreshDisplays()
        resyncApplied()

        parser.onDirection = { [weak self] direction in
            DispatchQueue.main.async { self?.handleDirection(direction) }
        }
        parser.onReadyChanged = { [weak self] ready in
            DispatchQueue.main.async { self?.handleReady(ready) }
        }
        parser.onAck = { [weak self] in
            self?.ackSemaphore.signal()
        }

        displayManager.onReconfiguration = { [weak self] in
            DispatchQueue.main.async { self?.handleReconfiguration() }
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: Timing.pollInterval, repeats: true) { [weak self] _ in
            self?.pollTick()
        }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: Timing.watchdogPeriod, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }

        if Prefs.simulation {
            setSimulation(true)
        } else if !Prefs.port.isEmpty {
            connect(path: Prefs.port)
        }
    }

    func shutdown() {
        manualClose = true
        stopReconnect()
        closePort()
        pollTimer?.invalidate(); pollTimer = nil
        watchdogTimer?.invalidate(); watchdogTimer = nil
        simulateTimer?.invalidate(); simulateTimer = nil
    }

    // MARK: 端口

    func refreshPorts() {
        ports = SerialEnumerator.devices()
        onChange?()
    }

    func refreshDisplays() {
        // 内置屏在 Apple Silicon 上无法旋转，直接从可选列表中剔除
        displays = displayManager.activeDisplays().filter { $0.rotationSupported }
        // 优先用保存的 UUID 定位目标显示器，找不到则用主显示器
        let savedUUID = Prefs.displayUUID
        if !savedUUID.isEmpty, let match = displays.first(where: { $0.uuid == savedUUID }) {
            targetDisplay = match
        } else if let main = displays.first(where: { $0.isMain }) ?? displays.first {
            targetDisplay = main
            Prefs.displayUUID = main.uuid
        } else {
            targetDisplay = nil
        }
        onChange?()
    }

    func selectDisplay(uuid: String) {
        guard let match = displays.first(where: { $0.uuid == uuid }) else { return }
        targetDisplay = match
        Prefs.displayUUID = uuid
        resyncApplied()
        onChange?()
    }

    /// 系统显示配置变化（含本程序自己的旋转）：刷新显示器列表并以真实方向为基准
    private func handleReconfiguration() {
        refreshDisplays()
        resyncApplied()
        onChange?()
    }

    /// 以屏幕真实方向刷新「已应用」状态，避免启动即误转
    func resyncApplied() {
        guard let display = targetDisplay else {
            appliedRotation = .r0
            return
        }
        appliedRotation = displayManager.currentRotation(of: display.id)
    }

    // MARK: 连接

    func connect(path: String) {
        guard !isConnected else { return }
        manualClose = false
        reconnectEnabled = false
        reconnectTimer?.invalidate()
        reconnectAttempts = 0

        let serial = SerialPort(path: path)
        do {
            try serial.open()
        } catch {
            Log.error("打开串口失败", error)
            scheduleReconnect()
            return
        }

        port = serial
        isConnected = true
        isReady = false
        lastDirection = .unknown
        parser.reset()
        Prefs.port = path
        if let device = ports.first(where: { $0.path == path }) {
            Prefs.portDescription = device.product
        }
        resyncApplied()
        startReadLoop()
        runInitSequence()
        onChange?()
    }

    func disconnect(manual: Bool = true) {
        manualClose = manual
        stopReconnect()
        closePort()
        onChange?()
    }

    func toggleConnection() {
        if isConnected {
            disconnect(manual: true)
        } else if let device = ports.first {
            connect(path: device.path)
        }
    }

    private func closePort() {
        stateLock.lock()
        readLoopActive = false
        stateLock.unlock()

        port?.close()
        port = nil
        isConnected = false
        isReady = false
        lastDirection = .unknown
        parser.reset()
    }

    private func startReadLoop() {
        stateLock.lock()
        readLoopActive = true
        stateLock.unlock()

        ioQueue.async { [weak self] in
            guard let self else { return }
            while true {
                self.stateLock.lock()
                let active = self.readLoopActive
                self.stateLock.unlock()
                guard active, let serial = self.port else { break }

                let data = serial.readChunk(timeoutMs: 100)
                if data.isEmpty {
                    if !serial.isOpen { break }
                    continue
                }
                self.parser.feed(data)
            }
            Log.info("串口读取循环结束")
        }
    }

    private func runInitSequence() {
        guard !initializing else { return }
        initializing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for command in Gy25tCommand.initialize {
                guard self.port != nil else { break }
                _ = self.writeSync(command)
            }
            self.initializing = false
            Log.info("GY-25T 初始化指令发送完成")
        }
    }

    private func writeSync(_ command: [UInt8]) -> Bool {
        guard let serial = port else { return false }
        ackSemaphore = DispatchSemaphore(value: 0)
        parser.pendingCommand = command
        defer { parser.pendingCommand = nil }
        do {
            try serial.write(Data(command))
        } catch {
            Log.error("串口写入失败", error)
            return false
        }
        return ackSemaphore.wait(timeout: .now() + Timing.commandTimeout) == .success
    }

    // MARK: 状态回调

    private func handleDirection(_ direction: SensorDirection) {
        if direction != lastDirection {
            Log.info("传感器方向：\(direction.label)")
        }
        lastDirection = direction
        onChange?()
    }

    /// 切换旋转方向（90° 与 270° 互换）
    func setReverseRotation(_ reversed: Bool) {
        Prefs.reverseRotation = reversed
        rotateMap = RotationMap.build(
            landscape: SensorDirection(rawValue: Prefs.landscapeDirection) ?? .left,
            reversed: reversed
        )
        Log.info("旋转方向：\(reversed ? "反向（90°↔270°）" : "标准")")
        onChange?()
    }

    private func handleReady(_ ready: Bool) {
        guard isReady != ready else { return }
        isReady = ready
        if ready {
            stopReconnect()
            reconnectAttempts = 0
            resyncApplied()
        } else if !manualClose {
            scheduleReconnect()
        }
        onChange?()
    }

    // MARK: 轮询与旋转

    private func pollTick() {
        guard isReady else { return }
        guard let display = targetDisplay else { return }
        guard let expected = rotateMap[lastDirection] else { return }
        guard expected != appliedRotation else { return }
        guard Date().timeIntervalSince(lastRotateAt) >= Timing.rotateCooldown else { return }

        if displayManager.setRotation(of: display.id, to: expected) {
            appliedRotation = expected
            lastRotateAt = Date()
            Log.info("旋转 \(display.name) → \(expected.degrees)°（传感器方向 \(lastDirection.label)）")
            onChange?()
        }
    }

    private func watchdogTick() {
        guard isReady else { return }
        let idle = Date().timeIntervalSince(parser.lastAccTime)
        if idle >= Timing.watchdogTimeout {
            Log.error("超过 \(Int(idle)) 秒无有效加速度帧，判定离线")
            handleReady(false)
        }
    }

    /// 一键复位：把目标显示器强制转到配置的基准角度（默认 0°）
    @discardableResult
    func resetRotation() -> Bool {
        guard let display = targetDisplay else { return false }
        let baseline = DisplayRotation(rawValue: Prefs.resetRotation) ?? .r0
        guard displayManager.setRotation(of: display.id, to: baseline) else { return false }
        appliedRotation = baseline
        lastRotateAt = Date()
        Log.info("一键复位：\(display.name) → \(baseline.degrees)°")
        refreshDisplays()
        onChange?()
        return true
    }

    /// 手动测试：按 0° → 90° → 180° → 270° 循环切换目标显示器
    func cycleTestRotation() {
        guard let display = targetDisplay else { return }
        let current = displayManager.currentRotation(of: display.id)
        let order: [DisplayRotation] = [.r0, .r90, .r180, .r270]
        let next = order[(order.firstIndex(of: current).map { $0 + 1 } ?? 1) % order.count]
        if displayManager.setRotation(of: display.id, to: next) {
            appliedRotation = next
            lastRotateAt = Date()
            refreshDisplays()
            onChange?()
        }
    }

    // MARK: 模拟

    func setSimulation(_ enabled: Bool) {
        simulationEnabled = enabled
        Prefs.simulation = enabled
        simulateTimer?.invalidate()
        simulateTimer = nil

        if enabled {
            disconnect(manual: true)
            isReady = true
            let order: [SensorDirection] = [.left, .up, .right, .down]
            simulateIndex = 0
            lastDirection = order[0]
            simulateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.simulateIndex = (self.simulateIndex + 1) % order.count
                self.handleDirection(order[self.simulateIndex])
            }
            Log.info("已开启模拟传感器（每 2 秒切换方向）")
        } else {
            isReady = false
            lastDirection = .unknown
            Log.info("已关闭模拟传感器")
        }
        onChange?()
    }

    // MARK: 自动重连

    private func scheduleReconnect() {
        guard !manualClose, !simulationEnabled else { return }
        reconnectEnabled = true
        reconnectAttempts += 1
        let exponent = min(reconnectAttempts - 1, 5)
        let delay = min(Timing.reconnectBase * pow(2, Double(exponent)), Timing.reconnectMax)
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.attemptReconnect()
        }
        Log.info("\(Int(delay)) 秒后尝试重连（第 \(reconnectAttempts) 次）")
    }

    private func attemptReconnect() {
        guard reconnectEnabled, !manualClose, !isConnected else { return }
        refreshPorts()
        guard let path = findSensorPort() else {
            scheduleReconnect()
            return
        }
        closePort()
        connect(path: path)
        if !isConnected { scheduleReconnect() }
    }

    private func stopReconnect() {
        reconnectEnabled = false
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    /// 按「保存的端口 → 保存的设备描述 → 唯一端口」的顺序定位传感器
    private func findSensorPort() -> String? {
        let saved = Prefs.port
        if !saved.isEmpty, ports.contains(where: { $0.path == saved }) { return saved }

        let description = Prefs.portDescription
        if !description.isEmpty,
           let match = ports.first(where: { $0.product.localizedCaseInsensitiveContains(description) }) {
            return match.path
        }

        let candidates = ports.filter { $0.isLikelySerial }
        if candidates.count == 1 { return candidates[0].path }
        return nil
    }
}
