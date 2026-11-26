import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let engine = RotationEngine()
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var eventMonitor: Any?
    private var cancellable: AnyCancellable?
    private let arguments: [String]

    init(arguments: [String]) {
        self.arguments = arguments
        super.init()
    }

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel(engine: engine)
        setupStatusItem()
        setupPopover()
        engine.start()
        model.refresh()

        cancellable = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }

        if !arguments.contains("--autostart") || arguments.contains("--show-settings") {
            DispatchQueue.main.async { [weak self] in
                self?.showPopover()
            }
        }
        Log.info("DisplayRotate 已启动，参数：\(arguments.dropFirst().joined(separator: " "))")
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopEventMonitor()
        engine.shutdown()
        Log.info("DisplayRotate 已退出")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = StatusIcon.make(connected: false)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusItem()
    }

    private func setupPopover() {
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button, let model else { return }
        let active = model.connected && model.ready
        button.image = StatusIcon.make(connected: active)
        button.toolTip = "DisplayRotate — \(model.statusText)"
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            if popover.isShown { closePopover() }
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func showContextMenu() {
        statusItem.menu = buildMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let open = NSMenuItem(title: "打开控制面板", action: #selector(showPopoverAction), keyEquivalent: ",")
        open.target = self
        menu.addItem(open)

        let status = NSMenuItem(title: model.statusText, action: nil, keyEquivalent: "")
        status.attributedTitle = statusTitle()
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: model.connected ? "断开连接" : "连接传感器",
            action: #selector(toggleConnection),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.isEnabled = model.connected || !model.selectedPort.isEmpty
        menu.addItem(toggle)

        let reset = NSMenuItem(title: "一键复位到 0°", action: #selector(resetRotation), keyEquivalent: "r")
        reset.target = self
        reset.isEnabled = model.rotationAvailable && !model.displays.isEmpty
        menu.addItem(reset)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 DisplayRotate", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func statusTitle() -> NSAttributedString {
        let color: NSColor = (model.connected && model.ready)
            ? .systemGreen
            : (model.connected ? .systemOrange : .systemRed)
        let text = NSMutableAttributedString(
            string: "● ",
            attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 12)]
        )
        text.append(NSAttributedString(
            string: model.statusText,
            attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 12)]
        ))
        return text
    }

    // MARK: Popover

    @objc private func showPopoverAction() {
        showPopover()
    }

    private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        startEventMonitor()
    }

    private func closePopover() {
        popover.performClose(nil)
        stopEventMonitor()
    }

    func popoverDidClose(_ notification: Notification) {
        stopEventMonitor()
    }

    private func startEventMonitor() {
        stopEventMonitor()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.closePopover()
        }
    }

    private func stopEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: 菜单动作

    @objc private func toggleConnection() {
        if model.connected {
            model.disconnect()
        } else {
            model.connect()
        }
    }

    @objc private func resetRotation() {
        model.resetRotation()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
