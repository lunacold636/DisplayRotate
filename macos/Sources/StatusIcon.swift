import AppKit

/// 菜单栏图标：18×18 模板图，已连接为实心屏、未连接为空心屏。
enum StatusIcon {
    static func make(connected: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let screenRect = NSRect(x: 3, y: 5, width: 12, height: 8.6)
            let screen = NSBezierPath(roundedRect: screenRect, xRadius: 2.2, yRadius: 2.2)
            screen.lineWidth = 1.6
            if connected {
                screen.fill()
            } else {
                screen.stroke()
            }

            let stand = NSBezierPath()
            stand.move(to: NSPoint(x: 9, y: 5))
            stand.line(to: NSPoint(x: 9, y: 2.6))
            stand.move(to: NSPoint(x: 6.4, y: 2.0))
            stand.line(to: NSPoint(x: 11.6, y: 2.0))
            stand.lineWidth = 1.6
            stand.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
