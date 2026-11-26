import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var showAbout = false
    @State private var portRefreshSpin = 0.0
    @State private var displayRefreshSpin = 0.0

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private var statusColor: Color {
        if model.connected && model.ready { return .green }
        if model.connected { return .orange }
        return .red
    }

    private var rotationDisabled: Bool {
        !model.rotationAvailable || model.displays.isEmpty
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 12) {
                headerSection
                Divider()
                controlsSection
                if let banner = alertBannerText {
                    alertBanner(banner)
                }
                Divider()
                footerToolbar
            }
            .padding(14)

            if showAbout {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showAbout = false
                        }
                    }

                aboutCard
                    .padding(.trailing, 14)
                    .padding(.bottom, 44)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
            }
        }
        .frame(width: 324)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 顶栏状态区

    private var headerSection: some View {
        HStack(spacing: 10) {
            MonitorOrientationBadge(rotation: model.screenRotation)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(model.statusText)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }

                Text("传感器 \(model.direction.label) · 屏幕 \(model.screenRotation.label)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if model.connected {
                Button("断开") {
                    model.disconnect()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            } else {
                Button("连接") {
                    model.connect()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(model.selectedPort.isEmpty)
            }
        }
    }

    // MARK: 核心配置区

    private var controlsSection: some View {
        VStack(spacing: 8) {
            // 传感器串口
            HStack(spacing: 8) {
                rowLabel("传感器")

                Picker("", selection: $model.selectedPort) {
                    if model.ports.isEmpty {
                        Text("未发现串口设备").tag("")
                    }
                    ForEach(model.ports) { device in
                        Text(device.displayName).tag(device.path)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
                .disabled(model.connected)

                PopoverIconButton(
                    systemName: "arrow.clockwise",
                    help: "重新扫描串口",
                    spinAngle: portRefreshSpin
                ) {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        portRefreshSpin += 360
                    }
                    model.refreshPorts()
                }
            }

            // 目标显示器
            HStack(spacing: 8) {
                rowLabel("显示器")

                Picker("", selection: Binding(
                    get: { model.selectedDisplayUUID },
                    set: { model.selectDisplay(uuid: $0) }
                )) {
                    if model.displays.isEmpty {
                        Text("未发现外接显示器").tag("")
                    }
                    ForEach(model.displays) { display in
                        Text(display.displayName).tag(display.uuid)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)

                PopoverIconButton(
                    systemName: "arrow.clockwise",
                    help: "重新扫描显示器",
                    spinAngle: displayRefreshSpin
                ) {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        displayRefreshSpin += 360
                    }
                    model.refreshDisplays()
                }
            }

            // 快捷旋转操作
            HStack(spacing: 8) {
                rowLabel("快捷")

                HStack(spacing: 8) {
                    QuickActionButton(
                        title: "复位 0°",
                        systemImage: "arrow.counterclockwise",
                        disabled: rotationDisabled
                    ) {
                        model.resetRotation()
                    }
                    .help("一键将屏幕复位到 0°")

                    QuickActionButton(
                        title: "旋转测试",
                        systemImage: "rotate.right",
                        disabled: rotationDisabled
                    ) {
                        model.cycleTestRotation()
                    }
                    .help("按 0° → 90° → 180° → 270° 依次测试旋转")
                }
            }
        }
    }

    private func rowLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(width: 42, alignment: .leading)
    }

    // MARK: 异常提示（仅出错时显示）

    private var alertBannerText: String? {
        if !model.rotationAvailable {
            return "当前系统未提供旋转接口"
        }
        if !model.message.isEmpty {
            return model.message
        }
        return nil
    }

    private func alertBanner(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
    }

    // MARK: 底部工具栏

    private var footerToolbar: some View {
        HStack(spacing: 8) {
            Toggle("开机自启", isOn: Binding(
                get: { model.autoStart },
                set: { model.setAutoStart($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 2) {
                PopoverIconButton(systemName: "doc.text", help: "打开日志目录") {
                    model.openLogFolder()
                }

                PopoverIconButton(
                    systemName: "info.circle",
                    help: "关于 DisplayRotate",
                    isActive: showAbout
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showAbout.toggle()
                    }
                }

                PopoverIconButton(
                    systemName: "power",
                    help: "退出 DisplayRotate",
                    destructiveHover: true
                ) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: 关于气泡

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("DisplayRotate")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text("v\(version)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Text("GY-25T 串口 9600 8N1\n映射：左→0°  上→90°  右→180°  下→270°")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineSpacing(2)

            Text("使用 SkyLight 私有旋转接口，内置屏自动忽略。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(11)
        .frame(width: 244, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.75)
        )
    }
}

// MARK: - 实时旋转显示器徽章

private struct MonitorOrientationBadge: View {
    let rotation: DisplayRotation

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.06))
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.75)

            VStack(spacing: 1.5) {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .stroke(Color.primary.opacity(0.85), lineWidth: 1.5)
                        .frame(width: 17, height: 11.5)
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 2.6, height: 2.6)
                        .padding(.top, 2.2)
                }
                RoundedRectangle(cornerRadius: 0.75)
                    .fill(Color.primary.opacity(0.75))
                    .frame(width: 7, height: 1.5)
            }
            .rotationEffect(.degrees(Double(rotation.degrees)))
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: rotation)
        }
        .frame(width: 36, height: 36)
    }
}

// MARK: - 紧凑图标按钮

private struct PopoverIconButton: View {
    let systemName: String
    let help: String
    var isActive: Bool = false
    var destructiveHover: Bool = false
    var spinAngle: Double = 0
    let action: () -> Void

    @State private var isHovered = false

    private var foreground: Color {
        if isHovered && destructiveHover { return .red }
        if isActive { return .accentColor }
        return isHovered ? .primary : .secondary
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .medium))
                .rotationEffect(.degrees(spinAngle))
                .foregroundStyle(foreground)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered || isActive ? Color.primary.opacity(0.08) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(help)
    }
}

// MARK: - 快捷操作按钮

private struct QuickActionButton: View {
    let title: String
    let systemImage: String
    let disabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(disabled ? .tertiary : .primary)
            .frame(maxWidth: .infinity)
            .frame(height: 27)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovered && !disabled ? 0.10 : 0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
