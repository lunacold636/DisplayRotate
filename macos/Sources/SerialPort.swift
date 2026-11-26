import Foundation
import IOKit
import IOKit.serial

// MARK: - 设备枚举

struct SerialDevice: Identifiable, Hashable {
    /// 设备路径，例如 /dev/cu.usbserial-1130
    let path: String
    /// USB 产品名，例如 USB-SERIAL CH340
    let product: String

    var id: String { path }

    /// 显示名，例如 "USB-SERIAL CH340  (/dev/cu.usbserial-1130)"
    var displayName: String {
        product.isEmpty ? path : "\(product)  (\(path))"
    }

    /// 是否是常见的 USB 转串口芯片（用于自动重连时避免误连手机等设备）
    var isLikelySerial: Bool {
        let lower = product.lowercased()
        let known = ["ch340", "ch341", "cp210", "ft232", "ftdi", "usb-serial", "usb serial",
                     "pl2303", "silicon labs", "arduino", "uart", "usbserial"]
        if known.contains(where: { lower.contains($0) }) { return true }
        return path.lowercased().contains("usbserial") || path.lowercased().contains("usbmodem")
    }
}

enum SerialEnumerator {
    /// 通过 IOKit 枚举 USB 串口设备，并取到 USB 产品名。
    static func devices() -> [SerialDevice] {
        var result: [SerialDevice] = []
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching(kIOSerialBSDServiceValue)
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return fallbackScan()
        }
        defer { IOObjectRelease(iterator) }

        var seen = Set<String>()
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            guard let callout = IORegistryEntryCreateCFProperty(
                service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String else { continue }

            // macOS 上必须用 /dev/cu.*（callout）打开；/dev/tty.* 会阻塞等待载波信号
            guard callout.hasPrefix("/dev/cu.") else { continue }
            // 蓝牙串口、调试控制台永远不会是传感器
            if callout.contains("Bluetooth") || callout.contains("debug-console") { continue }
            guard seen.insert(callout).inserted else { continue }

            let product = usbProductName(of: service) ?? ""

            result.append(SerialDevice(path: callout, product: product))
        }

        if result.isEmpty { return fallbackScan() }
        // 常见 USB 串口芯片排前面，其余（手机网络共享等）排后面
        return result.sorted {
            if $0.isLikelySerial != $1.isLikelySerial { return $0.isLikelySerial }
            return $0.path < $1.path
        }
    }

    private static func usbProductName(of service: io_registry_entry_t) -> String? {
        let options = IOOptionBits(kIORegistryIterateRecursively) | IOOptionBits(kIORegistryIterateParents)
        guard let value = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, "USB Product Name" as CFString, kCFAllocatorDefault, options
        ) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// IOKit 不可用时的兜底：直接扫 /dev
    private static func fallbackScan() -> [SerialDevice] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names
            .filter { $0.hasPrefix("cu.") && !$0.contains("Bluetooth") && !$0.contains("debug-console") }
            .sorted()
            .map { SerialDevice(path: "/dev/" + $0, product: "") }
    }
}

// MARK: - POSIX 串口

enum SerialError: LocalizedError {
    case openFailed(String, Int32)
    case notOpen
    case configureFailed(String)

    var errorDescription: String? {
        switch self {
        case let .openFailed(path, code):
            return "无法打开 \(path)（errno \(code)：\(String(cString: strerror(code)))）"
        case .notOpen:
            return "串口未打开"
        case let .configureFailed(reason):
            return "串口配置失败：\(reason)"
        }
    }
}

enum SerialReadResult {
    case data(Data)
    case timeout
    case disconnected(Int32)
}

/// 基于 POSIX termios 的串口封装，9600 8N1、raw 模式。
final class SerialPort {
    let path: String
    private var fd: Int32 = -1
    private let lock = NSLock()

    init(path: String) {
        self.path = path
    }

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fd >= 0
    }

    func open() throws {
        let handle = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard handle >= 0 else {
            throw SerialError.openFailed(path, errno)
        }

        var tio = termios()
        guard tcgetattr(handle, &tio) == 0 else {
            Darwin.close(handle)
            throw SerialError.configureFailed("tcgetattr 失败")
        }

        cfmakeraw(&tio)
        cfsetspeed(&tio, speed_t(B9600))
        tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tio.c_cflag &= ~tcflag_t(CRTSCTS)
        tio.c_cflag &= ~tcflag_t(CSTOPB)
        tio.c_cflag = (tio.c_cflag & ~tcflag_t(CSIZE)) | tcflag_t(CS8)
        tio.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        tio.c_cc.16 = 0 // VMIN
        tio.c_cc.17 = 0 // VTIME（读取用 poll 控制超时）

        guard tcsetattr(handle, TCSANOW, &tio) == 0 else {
            Darwin.close(handle)
            throw SerialError.configureFailed("tcsetattr 失败")
        }
        tcflush(handle, TCIOFLUSH)

        lock.lock()
        fd = handle
        lock.unlock()
        Log.info("串口已打开：\(path)")
    }

    func write(_ data: Data) throws {
        lock.lock()
        let handle = fd
        lock.unlock()
        guard handle >= 0 else { throw SerialError.notOpen }

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(handle, base.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EAGAIN || errno == EINTR {
                        usleep(2000)
                        continue
                    }
                    throw SerialError.configureFailed("写入失败 errno \(errno)")
                }
                offset += written
            }
        }
    }

    /// 带超时的读取；区分正常数据、超时空闲与设备异常断开。
    func readChunk(timeoutMs: Int32 = 100) -> SerialReadResult {
        lock.lock()
        let handle = fd
        lock.unlock()
        guard handle >= 0 else { return .disconnected(0) }

        var pfd = pollfd(fd: handle, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, timeoutMs)
        if ready == 0 { return .timeout }
        if ready < 0 {
            if errno == EINTR || errno == EAGAIN { return .timeout }
            return .disconnected(errno)
        }
        if (pfd.revents & Int16(POLLERR | POLLHUP | POLLNVAL)) != 0 {
            return .disconnected(0)
        }
        guard (pfd.revents & Int16(POLLIN)) != 0 else { return .timeout }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(handle, &buffer, buffer.count)
        if count > 0 {
            return .data(Data(buffer[0..<count]))
        }
        if count == 0 {
            // POLLIN 就绪但 read 返回 0（EOF）：设备被拔出或 USB 串口已重置
            return .disconnected(0)
        }
        if errno == EAGAIN || errno == EINTR {
            return .timeout
        }
        return .disconnected(errno)
    }

    func close() {
        lock.lock()
        let handle = fd
        fd = -1
        lock.unlock()
        if handle >= 0 {
            Darwin.close(handle)
            Log.info("串口已关闭：\(path)")
        }
    }
}
