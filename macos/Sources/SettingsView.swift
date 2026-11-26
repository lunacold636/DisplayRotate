import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var model: AppModel

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    var body: some View {
        Form {
            statusSection
            sensorSection
            displaySection
            startupSection
            debugSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 700)
    }

    // MARK: 状态

    private var statusSection: some View {
        Section {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                Text(model.statusText)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text("传感器 \(model.direction.label) · 屏幕 \(model.screenRotation.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("状态")
        }
    }

    private var statusColor: Color {
        if model.simulation { return .blue }
        if model.connected && model.ready { return .green }
        if model.connected { return .orange }
        return .red
    }

    // MARK: 传感器

    private var sensorSection: some View {
        Section {
            HStack(spacing: 8) {
                Picker("设备", selection: $model.selectedPort) {
                    if model.ports.isEmpty {
                        Text("未发现串口设备").tag("")
                    }
                    ForEach(model.ports) { device in
                        Text(device.displayName).tag(device.path)
                    }
                }
                .labelsHidden()
                .disabled(model.connected)

                Button {
                    model.refreshPorts()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("重新扫描串口设备")

                if model.connected {
                    Button("断开") { model.disconnect() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("连接") { model.connect() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.selectedPort.isEmpty || model.simulation)
                }
            }
        } header: {
            Text("GY-25T 传感器 · 9600 8N1")
        } footer: {
            if model.ports.isEmpty {
                Text("没有发现串口设备。请确认模块已插好、驱动已识别。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 显示器

    private var displaySection: some View {
        Section {
            HStack(spacing: 8) {
                Picker("目标显示器", selection: Binding(
                    get: { model.selectedDisplayUUID },
                    set: { model.selectDisplay(uuid: $0) }
                )) {
                    if model.displays.isEmpty {
                        Text("未发现可旋转的显示器").tag("")
                    }
                    ForEach(model.displays) { display in
                        Text(display.displayName).tag(display.uuid)
                    }
                }
                .labelsHidden()

                Button {
                    model.refreshDisplays()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("重新扫描显示器")
            }

            HStack(spacing: 8) {
                Text("复位基准")
                Picker("", selection: Binding(
                    get: { model.resetBaseline },
                    set: { model.setResetBaseline($0) }
                )) {
                    ForEach([0, 90, 180, 270], id: \.self) { degrees in
                        Text("\(degrees)°").tag(degrees)
                    }
                }
                .labelsHidden()
                .frame(width: 76)

                Spacer()

                Button("一键复位") { model.resetRotation() }
                    .disabled(!model.rotationAvailable || model.displays.isEmpty)
                Button("旋转测试") { model.cycleTestRotation() }
                    .disabled(!model.rotationAvailable || model.displays.isEmpty)
            }

            if !model.rotationAvailable {
                Label("当前系统未提供旋转接口", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("显示器")
        } footer: {
            Text("内置屏无法旋转，已从列表剔除。映射：左→0°　上→90°　右→180°　下→270°")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 启动

    private var startupSection: some View {
        Section {
            Toggle("开机自动启动（静默进入菜单栏）", isOn: Binding(
                get: { model.autoStart },
                set: { model.setAutoStart($0) }
            ))
        } header: {
            Text("启动")
        }
    }

    // MARK: 调试

    private var debugSection: some View {
        Section {
            Toggle("模拟传感器（每 2 秒切换方向，验证旋转链路）", isOn: Binding(
                get: { model.simulation },
                set: { model.setSimulation($0) }
            ))
        } header: {
            Text("调试")
        }
    }

    // MARK: 关于

    private var aboutSection: some View {
        Section {
            HStack {
                Text("DisplayRotate for macOS")
                Spacer()
                Text("v\(version)")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("打开日志目录") { model.openLogFolder() }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
            if !model.message.isEmpty {
                Text(model.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("关于")
        } footer: {
            Text("旋转使用系统私有接口 SLSSetDisplayRotation（SkyLight），不可上架 App Store。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
