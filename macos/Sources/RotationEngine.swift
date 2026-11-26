import AppKit
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
        static let initGraceTimeout: TimeInterval = 5.0  // 初始化完成后等待首帧超时
        static let wakeReconnectDelay: TimeInterval = 1.5
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

    var onChange: (() -> Void)?

    // MARK: 内部状态

    private var port: SerialPort?
    private var generation: Int = 0
    private var readLoopActive = false
    private var initializing = false
    private var initFinishedAt: Date?
    private var isSleeping = false
    private var rotateMap: [SensorDirection: DisplayRotation] = [:]
    private var lastRotateAt = Date.distantPast
    private var pollTimer: Timer?
    private var watchdogTimer: Timer?
    private var reconnectTimer: Timer?
    private var reconnectAttempts = 0
    private var reconnectEnabled = false
    private var manualClose = false
    private var activityToken: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []

    // MARK: 生命周期

    func start() {
        rotateMap = RotationMap.build(landscape: SensorDirection(rawValue: Prefs.landscapeDirection) ?? .left)
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
            guard let self else { return }
            self.stateLock.lock()
            let sem = self.ackSemaphore
            self.stateLock.unlock()
            sem.signal()
        }

        displayManager.onReconfiguration = { [weak self] in
            DispatchQueue.main.async { self?.handleReconfiguration() }
        }

        registerSleepWakeObservers()

        pollTimer = Timer.scheduledTimer(withTimeInterval: Timing.pollInterval, repeats: true) { [weak self] _ in
            self?.pollTick()
        }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: Timing.watchdogPeriod, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }

        if !Prefs.port.isEmpty {
            connect(path: Prefs.port)
        }
    }

    func shutdown() {
        manualClose = true
        unregisterSleepWakeObservers()
        stopReconnect()
        closePort()
        endActivityAssertion()
        pollTimer?.invalidate(); pollTimer = nil
        watchdogTimer?.invalidate(); watchdogTimer = nil
    }

    // MARK: App Nap 豁免与休眠唤醒

    /// 在传感器处于运行或自动重连状态时豁免 macOS App Nap，同时允许系统正常空闲休眠。
    private func updateActivityAssertion() {
        let shouldKeepAwake = isConnected || reconnectEnabled
        if shouldKeepAwake, activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Monitor GY-25T orientation sensor over serial port"
            )
        } else if !shouldKeepAwake {
            endActivityAssertion()
        }
    }

    private func endActivityAssertion() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    private func registerSleepWakeObservers() {
        unregisterSleepWakeObservers()
        let center = NSWorkspace.shared.notificationCenter
        let sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWillSleep()
        }
        let wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleDidWake()
        }
        workspaceObservers = [sleepObserver, wakeObserver]
    }

    private func unregisterSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    private func handleWillSleep() {
        isSleeping = true
        Log.info("系统即将休眠，暂停传感器看门狗")
    }

    private func handleDidWake() {
        isSleeping = false
        parser.touchWatchdog()
        if initFinishedAt != nil {
            initFinishedAt = Date()
        }
        Log.info("系统已唤醒，恢复传感器监测")
        if !manualClose && reconnectEnabled && !(isConnected && isReady) {
            reconnectAttempts = 0
            scheduleReconnect(delayOverride: Timing.wakeReconnectDelay)
        }
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

    func connect(path: String, resetBackoff: Bool = true) {
        guard !isConnected else { return }
        manualClose = false
        reconnectEnabled = false
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        if resetBackoff {
            reconnectAttempts = 0
        }

        let serial = SerialPort(path: path)
        do {
            try serial.open()
        } catch {
            Log.error("打开串口失败", error)
            scheduleReconnect()
            return
        }

        stateLock.lock()
        generation &+= 1
        let currentGen = generation
        port = serial
        readLoopActive = true
        initializing = true
        stateLock.unlock()

        isConnected = true
        isReady = false
        initFinishedAt = nil
        lastDirection = .unknown
        parser.reset()
        Prefs.port = path
        if let device = ports.first(where: { $0.path == path }) {
            Prefs.portDescription = device.product
        }
        resyncApplied()
        updateActivityAssertion()
        startReadLoop(generation: currentGen, serial: serial)
        runInitSequence(generation: currentGen, serial: serial)
        onChange?()
    }

    func disconnect(manual: Bool = true) {
        manualClose = manual
        stopReconnect()
        closePort()
        updateActivityAssertion()
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
        generation &+= 1
        readLoopActive = false
        initializing = false
        let oldPort = port
        port = nil
        let sem = ackSemaphore
        stateLock.unlock()

        sem.signal()
        oldPort?.close()
        isConnected = false
        isReady = false
        initFinishedAt = nil
        lastDirection = .unknown
        parser.reset()
    }

    private func isCurrentGeneration(_ gen: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == gen && readLoopActive
    }

    private func startReadLoop(generation gen: Int, serial: SerialPort) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            var unexpectedDisconnect: Int32?

            while self.isCurrentGeneration(gen) {
                switch serial.readChunk(timeoutMs: 100) {
                case let .data(data):
                    guard self.isCurrentGeneration(gen) else { break }
                    self.parser.feed(data)
                case .timeout:
                    if !serial.isOpen { break }
                case let .disconnected(code):
                    if self.isCurrentGeneration(gen) {
                        unexpectedDisconnect = code
                    }
                    break
                }
                if unexpectedDisconnect != nil || !serial.isOpen {
                    break
                }
            }

            Log.info("串口读取循环结束")
            if let code = unexpectedDisconnect {
                DispatchQueue.main.async { [weak self] in
                    self?.handlePortDisconnected(generation: gen, errnoCode: code)
                }
            }
        }
    }

    private func handlePortDisconnected(generation gen: Int, errnoCode: Int32) {
        stateLock.lock()
        let matches = (generation == gen)
        stateLock.unlock()
        guard matches else { return }

        if errnoCode != 0 {
            Log.error("串口异常断开（errno \(errnoCode)：\(String(cString: strerror(errnoCode)))）")
        } else {
            Log.error("串口已断开（设备可能被拔出或重置）")
        }

        closePort()
        onChange?()
        if !manualClose {
            scheduleReconnect()
        } else {
            updateActivityAssertion()
        }
    }

    private func runInitSequence(generation gen: Int, serial: SerialPort) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for command in Gy25tCommand.initialize {
                guard self.isCurrentGeneration(gen) else { return }
                _ = self.writeSync(command, generation: gen, serial: serial)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                let stillCurrent = (self.generation == gen)
                if stillCurrent { self.initializing = false }
                self.stateLock.unlock()
                guard stillCurrent else { return }

                self.initFinishedAt = Date()
                self.parser.touchWatchdog()
                Log.info("GY-25T 初始化指令发送完成")
            }
        }
    }

    private func writeSync(_ command: [UInt8], generation gen: Int, serial: SerialPort) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        stateLock.lock()
        guard generation == gen else {
            stateLock.unlock()
            return false
        }
        ackSemaphore = sem
        stateLock.unlock()

        parser.pendingCommand = command
        defer { parser.pendingCommand = nil }
        do {
            try serial.write(Data(command))
        } catch {
            Log.error("串口写入失败", error)
            return false
        }
        return sem.wait(timeout: .now() + Timing.commandTimeout) == .success
    }

    // MARK: 状态回调

    private func handleDirection(_ direction: SensorDirection) {
        guard isConnected else { return }
        lastDirection = direction
        onChange?()
    }

    private func handleReady(_ ready: Bool) {
        if ready && !isConnected { return }
        guard isReady != ready else { return }
        isReady = ready
        if ready {
            stopReconnect()
            reconnectAttempts = 0
            resyncApplied()
            updateActivityAssertion()
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
        guard !isSleeping, isConnected else { return }

        stateLock.lock()
        let isInitializing = initializing
        stateLock.unlock()
        // 初始化指令序列期间模块处于查询模式，暂停看门狗避免误判
        guard !isInitializing else { return }

        if isReady {
            let idle = Date().timeIntervalSince(parser.lastAccTime)
            if idle >= Timing.watchdogTimeout {
                Log.error("超过 \(Int(idle)) 秒无有效加速度帧，判定离线")
                parser.markOffline()
                handleReady(false)
            }
        } else if let finishedAt = initFinishedAt,
                  !reconnectEnabled,
                  Date().timeIntervalSince(finishedAt) >= Timing.initGraceTimeout {
            Log.error("初始化完成后超过 \(Int(Timing.initGraceTimeout)) 秒未收到加速度帧，判定离线")
            parser.markOffline()
            scheduleReconnect()
        }
    }

    /// 一键复位：把目标显示器强制转回 0°
    @discardableResult
    func resetRotation() -> Bool {
        guard let display = targetDisplay else { return false }
        let baseline: DisplayRotation = .r0
        guard displayManager.setRotation(of: display.id, to: baseline) else { return false }
        appliedRotation = baseline
        lastRotateAt = Date()
        Log.info("一键复位：\(display.name) → 0°")
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

    // MARK: 自动重连

    private func scheduleReconnect(delayOverride: TimeInterval? = nil) {
        guard !manualClose else { return }
        reconnectEnabled = true
        reconnectAttempts += 1
        let exponent = min(reconnectAttempts - 1, 5)
        let delay = delayOverride ?? min(Timing.reconnectBase * pow(2, Double(exponent)), Timing.reconnectMax)
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.attemptReconnect()
        }
        updateActivityAssertion()
        Log.info("\(Int(delay.rounded())) 秒后尝试重连（第 \(reconnectAttempts) 次）")
    }

    private func attemptReconnect() {
        guard reconnectEnabled, !manualClose else { return }
        if isConnected && isReady {
            stopReconnect()
            return
        }

        refreshPorts()
        guard let path = findSensorPort() else {
            if isConnected {
                closePort()
                onChange?()
            }
            scheduleReconnect()
            return
        }

        closePort()
        connect(path: path, resetBackoff: false)
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
