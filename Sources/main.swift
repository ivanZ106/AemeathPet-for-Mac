import AppKit

// ============================================================================
// 爱弥斯桌宠 —— macOS 入口
// 用法:
//   AemeathPet             正常启动桌宠
//   AemeathPet --selftest  无窗口自检（状态机模拟 + 内存统计）
// ============================================================================

if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
    exit(0)
}

// --probe: 记录渲染时间戳，用于分析动画播放节奏
let probeEnabled = CommandLine.arguments.contains("--probe")
if probeEnabled {
    try? FileManager.default.removeItem(atPath: "/tmp/aemeath_probe.log")
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // 仅状态栏，无 Dock 图标
app.run()
