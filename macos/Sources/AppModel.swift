import Foundation
import Combine
import AppKit

/// 视图模型：把引擎状态镜像成 SwiftUI 可观察的属性。
final class AppModel: ObservableObject {
    @Published var ports: [SerialDevice] = []
    @Published var displays: [DisplayInfo] = []
    @Published var connected = false
    @Published var ready = false
    @Published var direction: SensorDirection = .unknown
    @Published var applied: DisplayRotation = .r0
    @Published var screenRotation: DisplayRotation = .r0
    @Published var targetDisplayName = "—"
    @Published var rotationAvailable = false
    @Published var simulation = false
    @Published var autoStart = false
    @Published var selectedPort = ""
    @Published var selectedDisplayUUID = ""
    @Published var message = ""
    @Published var resetBaseline = 0
    @Published var reverseRotation = true

    let engine: RotationEngine

    init(engine: RotationEngine) {
        self.engine = engine
        engine.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    var statusText: String {
        if engine.isConnected {
            return engine.isReady ? "已连接" : "已连接（等待传感器数据）"
        }
        return simulation ? "模拟模式" : "未连接"
    }

    var statusColorName: String {
        engine.isConnected && engine.isReady ? "green" : (engine.isConnected ? "orange" : "red")
    }

    func refresh() {
        ports = engine.ports
        displays = engine.displays
        connected = engine.isConnected
        ready = engine.isReady
        direction = engine.lastDirection
        applied = engine.appliedRotation
        rotationAvailable = engine.displayManager.isRotationAvailable
        simulation = engine.simulationEnabled
        targetDisplayName = engine.targetDisplay?.displayName ?? "—"
        if let target = engine.targetDisplay {
            selectedDisplayUUID = target.uuid
            // 实时读取，避免使用启动时的快照
            screenRotation = engine.displayManager.currentRotation(of: target.id)
        } else {
            screenRotation = .r0
        }
        if selectedPort.isEmpty || !ports.contains(where: { $0.path == selectedPort }) {
            selectedPort = engine.isConnected ? Prefs.port : (ports.first?.path ?? "")
        }
        autoStart = LaunchAtLogin.isEnabled
        resetBaseline = Prefs.resetRotation
        reverseRotation = Prefs.reverseRotation
    }

    // MARK: 操作

    func refreshPorts() {
        engine.refreshPorts()
        if selectedPort.isEmpty { selectedPort = ports.first?.path ?? "" }
        refresh()
    }

    func refreshDisplays() {
        engine.refreshDisplays()
        refresh()
    }

    func connect() {
        guard !selectedPort.isEmpty else {
            message = "请先选择一个串口设备"
            return
        }
        message = ""
        engine.connect(path: selectedPort)
        refresh()
    }

    func disconnect() {
        engine.disconnect(manual: true)
        refresh()
    }

    func selectDisplay(uuid: String) {
        engine.selectDisplay(uuid: uuid)
        refresh()
    }

    func setSimulation(_ enabled: Bool) {
        engine.setSimulation(enabled)
        refresh()
    }

    func setAutoStart(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            message = enabled ? "已开启开机自启" : "已关闭开机自启"
        } catch {
            message = "设置开机自启失败：\(error.localizedDescription)"
            Log.error("设置开机自启失败", error)
        }
        autoStart = LaunchAtLogin.isEnabled
        resetBaseline = Prefs.resetRotation
        reverseRotation = Prefs.reverseRotation
    }

    func cycleTestRotation() {
        engine.cycleTestRotation()
        refresh()
    }

    func resetRotation() {
        if !engine.resetRotation() {
            message = "复位失败：请确认已选中可旋转的显示器"
        } else {
            message = ""
        }
        refresh()
    }

    func setReverseRotation(_ reversed: Bool) {
        engine.setReverseRotation(reversed)
        reverseRotation = reversed
        refresh()
    }

    func setResetBaseline(_ degrees: Int) {
        Prefs.resetRotation = degrees
        resetBaseline = degrees
    }

    func openLogFolder() {
        let url = Log.directory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}
