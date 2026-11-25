# DisplayRotate for macOS

GY-25T 加速度计驱动的 macOS 屏幕自动旋转工具。原生 Swift / AppKit 实现，常驻菜单栏，无 Dock 图标、无第三方运行时。

> Windows 版见仓库根目录（C# / WinForms）。两端共享同一套协议解析与方向判定逻辑。

## 功能

- **菜单栏常驻**：左键点图标打开设置窗口，右键弹出菜单（连接 / 一键复位 / 退出）
- **状态图标**：实心屏 = 已连接并收到数据，空心屏 = 未连接
- **GY-25T 串口**：9600 8N1，自动发送初始化序列，解析 `A4 03 08 06` 加速度帧
- **方向去抖**：20 帧滑动平均 + 同方向连续 20 帧确认，避免过渡期抖动
- **显示器旋转**：走系统私有接口 `SLSSetDisplayRotation`，支持 0/90/180/270
- **一键复位**：把屏幕强制转回配置的基准角度（默认 0°），传感器未接入时也能用
- **自动重连**：断线后指数退避（2s → 60s），设备就绪自动恢复
- **开机自启**：写入 `~/Library/LaunchAgents`，静默进入菜单栏
- **单实例**：文件锁保证只跑一份
- **模拟传感器**：无硬件时也能验证「方向 → 旋转」整条链路
- **日志**：`~/Library/Logs/DisplayRotate/DisplayRotate.log`

## 构建

需要 Xcode 命令行工具（`swiftc`），macOS 14+。

```bash
cd macos
./build.sh              # Apple Silicon
./build.sh --universal  # Intel + Apple Silicon 通用二进制
```

产物：`macos/build/DisplayRotate.app`，双击或 `open build/DisplayRotate.app` 运行。

## 使用

1. 打开 App，菜单栏出现显示器图标，同时弹出设置窗口
2. 「设备」下拉框选择传感器串口（CH340 / CP210x 等会显示 USB 产品名），点「连接」
3. 「目标显示器」选择要自动旋转的屏幕（内置屏已自动剔除，无法旋转）
4. 屏幕随传感器姿态在 0°/90°/180°/270° 之间切换
5. 需要强制回正时点「一键复位」，基准角度可在左侧下拉框修改
6. 关闭窗口 = 隐藏到菜单栏；真正退出用菜单栏右键 → 退出

## 自检

无界面验证私有 API、显示器枚举、协议解析、去抖、映射与旋转链路：

```bash
build/DisplayRotate.app/Contents/MacOS/DisplayRotate --selftest
build/DisplayRotate.app/Contents/MacOS/DisplayRotate --selftest --rotate-test   # 含真实旋转往返
```

## 目录结构

```
macos/
├── build.sh                  # 一键构建脚本
├── Info.plist                # LSUIElement=true（无 Dock 图标）
└── Sources/
    ├── main.swift            # 入口、单实例锁、命令行参数
    ├── AppDelegate.swift     # 菜单栏图标、右键菜单、设置窗口
    ├── SettingsView.swift    # SwiftUI 设置界面
    ├── AppModel.swift        # 视图模型（引擎状态 → SwiftUI）
    ├── RotationEngine.swift  # 连接/重连/轮询/旋转/模拟 的状态机
    ├── Gy25t.swift           # 协议解析 + 方向判定（移植自 Gy25t.cs）
    ├── SerialPort.swift      # IOKit 枚举 + POSIX termios 串口
    ├── DisplayManager.swift  # 显示器枚举 + SLSSetDisplayRotation
    ├── Prefs.swift           # UserDefaults 设置
    ├── LaunchAtLogin.swift   # LaunchAgent 开机自启
    ├── Logger.swift          # 文件日志
    ├── StatusIcon.swift      # 菜单栏图标绘制
    └── SelfTest.swift        # 无界面自检
```

## 与 Windows 版的对应关系

| 功能 | Windows | macOS |
| --- | --- | --- |
| 屏幕旋转 | `ChangeDisplaySettingsEx` | `SLSSetDisplayRotation`（私有，dlopen） |
| 读取角度 | `EnumDisplaySettingsEx` | `CGDisplayRotation`（公开） |
| 显示器枚举 | `EnumDisplayDevices` | `CGGetActiveDisplayList` + `NSScreen` |
| 显示器标识 | `\\.\DISPLAY1` | 显示器 UUID（跨重启稳定） |
| 串口 | `System.IO.Ports` | POSIX `open` + termios，`/dev/cu.*` |
| 开机自启 | `HKCU\...\Run` | `~/Library/LaunchAgents` |
| 设置 | 注册表 | `UserDefaults` |
| 托盘 | `NotifyIcon` | `NSStatusItem` |
| 单实例 | 命名 Mutex | 文件锁 `flock` |
| 日志 | 程序目录 | `~/Library/Logs/DisplayRotate` |

时序参数与 Windows 版一致：轮询 500ms、旋转冷却 2s、看门狗 5s、重连 2s→60s。

## 关于私有 API

旋转依赖 `/System/Library/PrivateFrameworks/SkyLight.framework` 的 `SLSSetDisplayRotation`：

```c
int SLSSetDisplayRotation(CGDirectDisplayID display, int degrees);  // 0 = 成功
```

- 已在 macOS 14.8.9 / Apple Silicon / SIP 开启环境下实测可用，参数为**角度**
- 效果与「系统设置 → 显示器 → 旋转」等价，**持久化**（重启后保持）
- 不属于公开 API：**不可上架 App Store**，但可以直接分发并公证
- 若未来系统移除该符号，程序会降级为「旋转不可用」并在界面提示，不会崩溃

## 已知限制

- **内置屏不支持旋转**：Apple Silicon 机型系统本身不提供该能力，已从显示器列表剔除
- **需要外接屏**：没有外接显示器时旋转功能不可用
- **仅 arm64 默认构建**：需要 Intel 支持请用 `./build.sh --universal`
- **未做 Developer ID 签名**：首次打开可能需要在「隐私与安全性」里放行

## 待联调（拿到设备后）

1. **安装方向基准**：确认传感器贴在屏幕上的朝向，校准 `Prefs.landscapeDirection`（默认「左 → 0°」）
2. **串口自动识别**：验证 CH340 / CP210x 的产品名能否被 IOKit 正确读到
3. **复位基准**：确定日常使用的复位角度（0° 还是某个固定方向），在界面里直接选即可
4. **去抖手感**：如切换过于灵敏或迟钝，调整 `Gy25t.swift` 中的 `accWindow` 与 `confirmFrames`
