import AppKit
import QuartzCore
import Darwin

// ============================================================================
// 自检模式：--selftest
// 无窗口运行状态机模拟（模拟 120Hz 显示刷新驱动），输出：
//   动画插值帧率、动画帧推进、位置约束、各移动帧率档位下的速度一致性、内存占用
// ============================================================================

enum SelfTest {

    static func run() {
        Assets.load()

        // 帧率统计：各状态原始帧数与帧率
        var frameLines: [String] = []
        for state in [PetState.move, .idle1, .idle2, .idle3, .idle4, .drag] {
            if let clip = Assets.clips[state] {
                let fps = 1.0 / (clip.delays.first ?? 0.11)
                frameLines.append("\(state.rawValue):\(clip.images.count)帧/\(String(format: "%.1f", fps))fps")
            }
        }

        let brain = PetBrain()
        brain.tickRate = Double(Settings.tickRateOptions[Settings.defaultTickRateIndex])
        let bounds = CGRect(x: 0, y: 0, width: 1728, height: 1117) // 模拟一块屏幕
        let start = CGPoint(x: 800, y: 200)
        brain.start(bounds: bounds, at: start, now: 0)

        var renderCount = 0
        var insideTicks = 0, outsideTicks = 0
        var activeTicks = 0
        brain.onRender = { _ in renderCount += 1 }

        // 模拟 120Hz 显示刷新驱动
        let displayHz = 120.0
        let displayStep = 1.0 / displayHz
        var t: CFTimeInterval = 0
        var moveAccum: Double = 0

        // 阶段1：正常游荡模拟（60 秒）
        let simSeconds = 60.0
        let iterations = Int(simSeconds * displayHz)
        for _ in 0..<iterations {
            moveAccum += displayStep
            let shouldMove = moveAccum >= brain.fastInterval
            if shouldMove { moveAccum = 0 }
            let active = brain.tick(now: t, shouldMove: shouldMove)
            if active { activeTicks += 1 }
            let p = brain.pos
            let inside = p.x >= bounds.minX && p.x <= bounds.maxX - brain.windowSize.width
                && p.y >= bounds.minY && p.y <= bounds.maxY - brain.windowSize.height
            if inside { insideTicks += 1 } else { outsideTicks += 1 }
            t += displayStep
        }

        // 阶段2：暂停模式模拟（20 秒）
        brain.setPaused(true, now: t)
        let pausedTicks = Int(20.0 * displayHz)
        var pausedFrameAdvances = 0
        let before = brain.animFrameAdvances
        for _ in 0..<pausedTicks {
            _ = brain.tick(now: t, shouldMove: false)
            t += displayStep
        }
        pausedFrameAdvances = brain.animFrameAdvances - before

        // 阶段3：跟随模式（真实鼠标位置，允许失败）
        brain.setPaused(false, now: t)
        brain.followMouse = true
        for _ in 0..<Int(5.0 * displayHz) {
            moveAccum += displayStep
            _ = brain.tick(now: t, shouldMove: moveAccum >= brain.fastInterval)
            t += displayStep
        }
        brain.followMouse = false

        // 阶段4：拖动模拟
        brain.beginDrag(now: t)
        brain.endDrag(now: t)

        // 阶段5：帧率档位验证（各档 5 秒，位移应一致 = px/s 与帧率无关）
        var rateLines: [String] = []
        for hz in Settings.tickRateOptions {
            brain.tickRate = Double(hz)
            brain.resetToWander(now: t)
            let p0 = brain.pos
            let rateSeconds = 5.0
            let n = Int(rateSeconds * displayHz)
            var moveTicks = 0
            var acc: Double = 0
            for _ in 0..<n {
                acc += displayStep
                let shouldMove = acc >= brain.fastInterval
                if shouldMove { acc -= brain.fastInterval; moveTicks += 1 }
                _ = brain.tick(now: t, shouldMove: shouldMove)
                t += displayStep
            }
            let dist = hypot(brain.pos.x - p0.x, brain.pos.y - p0.y)
            rateLines.append(String(format: "%dHz: 移动 tick %d（期望≈%d）, 位移 %.0fpx",
                                    hz, moveTicks, Int(Double(hz) * rateSeconds), dist))
        }

        let total = iterations + pausedTicks
        let insidePct = insideTicks * 100 / max(insideTicks + outsideTicks, 1)
        print("==============================================")
        print("[Aemeath Pet SelfTest] 爱弥斯桌宠自检")
        print("==============================================")
        print("素材加载: \(Assets.clips.count) 组动画")
        print("模拟: \(simSeconds)s 游荡 + 20s 暂停 + 5s 跟随（120Hz 驱动）")
        print("活动驱动 tick: \(activeTicks)/\(total) (\(activeTicks * 100 / max(total, 1))%)")
        print("渲染回调: \(renderCount) 次")
        print("动画帧推进: \(brain.animFrameAdvances) 次 (暂停段 +\(pausedFrameAdvances))")
        print("位置在屏幕内占比: \(insidePct)% (走出屏幕 = 撞边重生特性)")
        print("动画帧率(原始帧):")
        for line in frameLines { print("  \(line)") }
        print("帧率档位验证:")
        for line in rateLines { print("  \(line)") }
        print("内存占用 (phys_footprint): \(String(format: "%.1f", Double(memoryFootprintBytes()) / 1_048_576)) MB")
        print("==============================================")
        print("自检完成")
    }

    /// 进程物理内存占用（字节）
    static func memoryFootprintBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { p in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), p, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint)
    }
}
