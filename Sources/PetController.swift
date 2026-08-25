import AppKit
import QuartzCore
import CoreVideo

// ============================================================================
// 宠物控制器：单画布窗口 + 多宠物精灵（多开模式）
// - 窗口固定为全屏透明画布，所有宠物图层在画布内移动（合成永远流畅）
// - CVDisplayLink 显示同步驱动（不受后台定时器合并影响）
// - 每只宠物有独立的随机状态机（游荡/跟随/好奇/休息/待机 = 随机动作）
// - 静止时自动降频到 2Hz 巡检，显示器休眠时自动停止（省电）
// ============================================================================

/// 随机队形
enum Formation: CaseIterable {
    case heart, circle, row, column, grid, diamond, spiral, march
}

/// 单只宠物精灵：一个大脑 + 一个渲染图层
final class PetSprite {
    let brain: PetBrain
    let layer: CALayer
    var dragOffset: CGPoint = .zero
    private(set) var isDragging = false
    var lastContents: CGImage?

    init(brain: PetBrain, layer: CALayer) {
        self.brain = brain
        self.layer = layer
    }
}

final class PetController: NSObject {

    private let panel: NSPanel
    private weak var canvasView: PetView?
    private var sprites: [PetSprite] = []
    private var draggingSprite: PetSprite?
    private var displayLink: CVDisplayLink?
    private var slowTimer: Timer?          // 完全静止时的 2Hz 巡检
    private var moveAccum: Double = 0      // 移动积分门控累加器
    private var pendingMainUpdate = false  // 防止主线程积压
    private var lastDisplayTime: Double = 0

    private(set) var isVisible = false   // 初始隐藏，由 show() 显示并启动定时器
    private var suspended = false   // 屏幕休眠等暂停标志

    // 随机队形状态
    private var formation: Formation?
    private var formationActive = false
    private var formationCenter: CGPoint = .zero
    private var formationTimer: Double = 18   // 首次队形前的自由活动时间
    private var waveTime: Double = 0

    // 列队行进状态
    private var marchRoute: (points: [CGPoint], cum: [Double], total: Double)?
    private var marchProgress: Double = 0
    private var marchSpacing: Double = 90
    private let marchSpeed: Double = 115   // px/s

    /// 队形切换频率：保持时长 / 自由活动时长（随「队形频率」设置变化）
    private var formationHoldRange: ClosedRange<Double> {
        switch settings.formationFrequencyIndex {
        case 0: return 40...50
        case 2: return 15...20
        case 3: return 8...12
        default: return 25...35
        }
    }
    private var formationRoamRange: ClosedRange<Double> {
        switch settings.formationFrequencyIndex {
        case 0: return 25...35
        case 2: return 10...15
        case 3: return 5...8
        default: return 15...25
        }
    }

    var settings: Settings.State

    /// 供菜单查询暂停状态（全部暂停才算暂停）
    var isPaused: Bool { sprites.allSatisfy { $0.brain.paused } }

    /// 当前宠物数量
    var instanceCount: Int { sprites.count }

    // MARK: - 多开内存上限

    /// 每实例内存预算（MB）——帧资源共享，实测每只增量 <1MB，取 2MB 保守预算
    static let perInstanceMemoryMB: Double = 2
    /// 宠物总内存预算占物理内存比例
    static let memoryBudgetRatio = 0.30
    /// 多开数量上限（100 只：够用且省电）
    static let hardMaxInstances = Settings.maxInstanceCount

    /// 多开上限：取「内存×30% ÷ 每只预算」与 100 的较小值
    static func maxInstances() -> Int {
        let totalMB = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576
        let budgetMB = totalMB * memoryBudgetRatio
        let byMemory = Int(budgetMB / perInstanceMemoryMB)
        return max(1, min(hardMaxInstances, byMemory))
    }

    // MARK: - 初始化

    init(settings: Settings.State) {
        self.settings = settings

        let scale = settings.scale
        let base = CGSize(width: 200, height: 200)
        let size = CGSize(width: base.width * scale, height: base.height * scale)

        let screenBounds = Self.allScreensBounds()

        // ===== 全屏透明画布窗口 =====
        // 窗口保持固定不动，宠物图层在窗口内部移动 → 合成永远流畅
        panel = NSPanel(contentRect: NSRect(origin: screenBounds.origin, size: screenBounds.size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.sharingType = .readOnly
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.ignoresMouseEvents = true   // 全屏画布默认穿透；光标悬停宠物上时动态关闭

        super.init()

        // 内容视图（全屏）
        let view = PetView(frame: NSRect(origin: .zero, size: screenBounds.size))
        view.wantsLayer = true
        view.controller = self
        panel.contentView = view
        canvasView = view

        // 初始宠物
        let count = max(1, min(settings.instanceCount, Self.maxInstances()))
        for i in 0..<count {
            addSprite(at: startPosition(for: i, in: screenBounds, size: size))
        }

        applyLevel(settings.displayLevel)
        applyOpacity(settings.transparency)
        // 鼠标穿透由「光标是否悬停宠物上」动态控制（画布窗口本身始终穿透）
        panel.ignoresMouseEvents = true

        // 睡眠/唤醒监听
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(screenDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(screenDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(sessionResigned), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(sessionBecameActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }

    /// 各宠物初始位置：第一只恢复上次位置，其余沿屏幕底部均匀分布
    private func startPosition(for index: Int, in bounds: CGRect, size: CGSize) -> CGPoint {
        if index == 0 {
            var origin = CGPoint(x: bounds.midX - size.width / 2, y: bounds.minY + 40)
            if let saved = UserDefaults.standard.string(forKey: "petPosition") {
                let parts = saved.split(separator: ",").compactMap { Double($0) }
                if parts.count == 2 {
                    origin = CGPoint(x: parts[0], y: parts[1])
                }
            }
            origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
            origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
            return origin
        }
        let total = max(2, settings.instanceCount)
        let x = bounds.minX + bounds.width * CGFloat(index) / CGFloat(total)
        let y = bounds.minY + 40
        return CGPoint(x: min(x, bounds.maxX - size.width), y: y)
    }

    /// 添加一只宠物
    @discardableResult
    private func addSprite(at origin: CGPoint) -> PetSprite {
        let brain = PetBrain()
        brain.tickRate = Double(settings.tickRate)
        brain.followMouse = settings.followMouse

        // 关键：应用配置的缩放尺寸（否则会用大脑默认的 200x200=1.0x）
        let scale = settings.scale
        let size = CGSize(width: 200 * scale, height: 200 * scale)
        brain.setWindowSize(size)

        // 跟随模式锚点：心形分布（添加后统一重算，保证与总数一致）

        let layer = CALayer()
        layer.contentsGravity = .resizeAspect
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.position = CGPoint(x: origin.x + size.width / 2,
                                 y: origin.y + size.height / 2)
        layer.contentsScale = panel.backingScaleFactor
        // 关键：禁用隐式动画——否则每次换帧会触发 0.25s 的交叉淡入淡出 = 跳动/拖影
        layer.actions = [
            "contents": NSNull(),
            "transform": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
        ]

        let sprite = PetSprite(brain: brain, layer: layer)
        sprites.append(sprite)
        canvasView?.layer?.addSublayer(layer)

        brain.onRender = { [weak self, weak sprite] state in
            guard let sprite = sprite else { return }
            self?.applyRender(state, to: sprite)
        }
        brain.onMove = { [weak self, weak sprite] _ in
            guard let sprite = sprite else { return }
            self?.syncLayerPosition(sprite)
        }

        brain.start(bounds: Self.allScreensBounds(), at: origin, now: Self.now())
        if settings.startPaused {
            brain.setPaused(true, now: Self.now())
        }
        reassignFollowAnchors()
        return sprite
    }

    private func removeSprite() {
        guard let last = sprites.popLast() else { return }
        if draggingSprite === last { draggingSprite = nil }
        last.layer.removeFromSuperlayer()
    }

    /// 重算所有宠物的心形锚点（数量变化后必须重算，否则形状错乱）
    private func reassignFollowAnchors() {
        let n = max(2, sprites.count)
        let heartScale = 10.0   // 心形尺度（约 320pt 宽，更大更明显）
        for (i, sprite) in sprites.enumerated() {
            let t = 2 * Double.pi * Double(i) / Double(n) + 0.35
            let hx = 16 * pow(sin(t), 3)
            let hy = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
            sprite.brain.followAnchor = CGPoint(x: CGFloat(hx * heartScale),
                                                y: CGFloat(hy * heartScale))
        }
    }

    /// 动态调整宠物数量（多开）
    func setInstanceCount(_ n: Int) {
        let target = max(1, min(n, Self.maxInstances()))
        settings.instanceCount = target
        let bounds = Self.allScreensBounds()
        while sprites.count < target {
            let idx = sprites.count
            addSprite(at: startPosition(for: idx, in: bounds, size: sprites[0].brain.windowSize))
        }
        while sprites.count > target {
            removeSprite()
        }
        reassignFollowAnchors()
        disbandFormation()   // 数量变化：解散当前队形，稍后重新排列
        formationTimer = Double.random(in: 15...25)
        panel.orderFrontRegardless()
    }

    // MARK: - 显示控制

    func show() {
        guard !isVisible else { return }
        isVisible = true
        for s in sprites { s.brain.isHidden = false }
        panel.orderFrontRegardless()
        lastDisplayTime = Self.now()
        startDisplayLink()
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        for s in sprites { s.brain.isHidden = true }
        stopDisplayLink()
        stopSlowPoll()
        panel.orderOut(nil)
    }

    func toggleVisible() {
        isVisible ? hide() : show()
    }

    // MARK: - 暂停

    func togglePause() {
        let target = !isPaused
        for s in sprites { s.brain.setPaused(target, now: Self.now()) }
        stopSlowPoll()
        startDisplayLink()
    }

    // MARK: - 设置应用（作用于所有宠物）

    func setFollowMouse(_ on: Bool) {
        settings.followMouse = on
        for s in sprites { s.brain.followMouse = on }
        if on {
            disbandFormation()
        } else {
            formationTimer = Double.random(in: 15...25)   // 重新开始自由活动计时
        }
    }

    func setClickThrough(_ on: Bool) {
        settings.clickThrough = on
        if on, let ds = draggingSprite {
            draggingSprite = nil
            ds.brain.endDrag(now: Self.now())
            startDisplayLink()
        }
        updateClickThroughForMouse()
    }

    func setScale(_ index: Int) {
        settings.scaleIndex = index
        let scale = settings.scale
        let size = CGSize(width: 200 * scale, height: 200 * scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for s in sprites {
            s.layer.bounds = CGRect(origin: .zero, size: size)
            s.brain.setWindowSize(size)
            syncLayerPosition(s)
            applyRender(RenderState(image: s.brain.currentFrame, flipped: s.brain.movingRight), to: s)
        }
        CATransaction.commit()
        panel.orderFrontRegardless()
    }

    func setTransparency(_ index: Int) {
        settings.transparencyIndex = index
        applyOpacity(settings.transparency)
    }

    /// 设置移动积分帧率（立即生效；显示刷新率即上限）
    func setTickRate(_ index: Int) {
        settings.tickRateIndex = index
        for s in sprites { s.brain.tickRate = Double(settings.tickRate) }
        moveAccum = 0
    }

    func setDisplayLevel(_ level: Settings.DisplayLevel) {
        settings.displayLevel = level
        applyLevel(level)
    }

    private func applyOpacity(_ value: Double) {
        panel.alphaValue = CGFloat(value)
    }

    private func applyLevel(_ level: Settings.DisplayLevel) {
        switch level {
        case .top:
            panel.level = .floating
        case .normal:
            panel.level = .normal
        case .desktop:
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        }
    }

    // MARK: - 渲染与移动

    private func applyRender(_ state: RenderState, to sprite: PetSprite) {
        if probeEnabled {
            let t = CACurrentMediaTime()
            let idx = sprites.firstIndex(where: { $0 === sprite }) ?? -1
            let line = "\(String(format: "%.4f", t)),\(idx),\(state.flipped ? "L" : "R")\n"
            if let h = FileHandle(forWritingAtPath: "/tmp/aemeath_probe.log") {
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8)!)
                try? h.close()
            } else {
                FileManager.default.createFile(atPath: "/tmp/aemeath_probe.log", contents: line.data(using: .utf8))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // 换帧立即生效，无淡入淡出
        if sprite.lastContents !== state.image {
            sprite.lastContents = state.image
            sprite.layer.contents = state.image
        }
        let flip: CGFloat = state.flipped ? -1 : 1
        let transform = CATransform3DMakeScale(flip, 1, 1)
        if !CATransform3DEqualToTransform(sprite.layer.transform, transform) {
            sprite.layer.transform = transform
        }
        CATransaction.commit()
    }

    /// 动态穿透：光标在任一宠物矩形内 → 画布接收鼠标事件；否则完全穿透
    private func updateClickThroughForMouse() {
        guard draggingSprite == nil else { return }
        let mouse = NSEvent.mouseLocation
        let overPet = sprites.contains { sprite(at: mouse) === $0 }
        let shouldPassThrough = !overPet || settings.clickThrough
        if panel.ignoresMouseEvents != shouldPassThrough {
            panel.ignoresMouseEvents = shouldPassThrough
        }
    }

    /// 命中测试：返回光标下的宠物（后添加的在上层）
    private func sprite(at point: CGPoint) -> PetSprite? {
        for sprite in sprites.reversed() {
            let size = sprite.layer.bounds.size
            let rect = CGRect(x: sprite.brain.pos.x, y: sprite.brain.pos.y,
                              width: size.width, height: size.height).insetBy(dx: -6, dy: -6)
            if rect.contains(point) { return sprite }
        }
        return nil
    }

    /// 同步宠物图层位置（窗口固定，仅移动图层 → 合成永远流畅）
    /// 显示驱动用：基础位置 + 队形同步动作偏移，单事务一次应用（避免多事务分帧导致的闪烁）
    private func updateSpritePosition(_ sprite: PetSprite) {
        let size = sprite.layer.bounds.size
        var center = CGPoint(x: sprite.brain.pos.x + size.width / 2,
                             y: sprite.brain.pos.y + size.height / 2)
        if formationActive, let formation = formation, formation != .march, sprite.brain.settled,
           let idx = sprites.firstIndex(where: { $0 === sprite }) {
            let offset = formationActionOffset(sprite, type: formation, index: idx, count: sprites.count)
            center.x += offset.x
            center.y += offset.y
        }
        if abs(sprite.layer.position.x - center.x) > 0.01 || abs(sprite.layer.position.y - center.y) > 0.01 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sprite.layer.position = center
            CATransaction.commit()
        }
        if sprites.first === sprite {
            savePosition(sprite.brain.pos)
        }
    }

    /// 非驱动路径用的基础位置同步（setScale/解散/拖动等）
    private func syncLayerPosition(_ sprite: PetSprite) {
        let size = sprite.layer.bounds.size
        let center = CGPoint(x: sprite.brain.pos.x + size.width / 2,
                             y: sprite.brain.pos.y + size.height / 2)
        if abs(sprite.layer.position.x - center.x) > 0.01 || abs(sprite.layer.position.y - center.y) > 0.01 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sprite.layer.position = center
            CATransaction.commit()
        }
        if sprites.first === sprite {
            savePosition(sprite.brain.pos)
        }
    }

    private func savePosition(_ p: CGPoint) {
        UserDefaults.standard.set("\(Int(p.x)),\(Int(p.y))", forKey: "petPosition")
    }

    // MARK: - 随机队形

    private func updateFormation(dt: Double) {
        let canForm = settings.formationEnabled && !settings.followMouse
            && instanceCount > 1 && draggingSprite == nil
        if !canForm {
            if formationActive { disbandFormation() }
            return
        }
        if formationActive {
            if formation == .march {
                updateMarch(dt: dt)   // 行进自终止（走完路线解散）
                return
            }
            // 所有队形期间的同步动作（爱心心跳/圆形旋转/一排波浪/方阵棋盘…）
            applyFormationAction(dt: dt)
            formationTimer -= dt
            if formationTimer <= 0 {
                // 保持结束：解散，自由活动一段时间
                disbandFormation()
                formationTimer = Double.random(in: formationRoamRange)
            }
            return
        }
        // 自由活动阶段
        formationTimer -= dt
        if formationTimer <= 0 {
            // 自由活动结束：随机排一个队形
            startRandomFormation()
            formationTimer = Double.random(in: formationHoldRange)
        }
    }

    private func startRandomFormation() {
        guard !sprites.isEmpty else { return }
        let type = Formation.allCases.randomElement()!
        if type == .march {
            startMarchFormation()
            return
        }
        let bounds = Self.allScreensBounds()
        let center = CGPoint(x: bounds.minX + bounds.width * CGFloat.random(in: 0.25...0.75),
                             y: bounds.minY + bounds.height * CGFloat.random(in: 0.25...0.7))
        formationCenter = center
        let size = sprites[0].layer.bounds.size
        let slots = formationSlots(type, count: sprites.count, center: center, petSize: size)
        for (i, sprite) in sprites.enumerated() {
            sprite.brain.formationTarget = clampToBounds(slots[min(i, slots.count - 1)])
        }
        formation = type
        formationActive = true
        waveTime = 0
        if probeEnabled {
            probeWrite(String(format: "formation: \(type) @ %.1f", Self.now()))
        }
    }

    private func probeWrite(_ msg: String) {
        let line = "[formation] \(msg)\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/aemeath_probe.log") {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            FileManager.default.createFile(atPath: "/tmp/aemeath_probe.log", contents: line.data(using: .utf8))
        }
    }

    /// 列队行进：所有宠物排成一队沿随机路线行进
    private func startMarchFormation() {
        guard !sprites.isEmpty else { return }
        formation = .march
        formationActive = true
        marchRoute = buildMarchRoute()
        guard let route = marchRoute else {
            disbandFormation()
            return
        }
        marchSpacing = Double(sprites[0].layer.bounds.size.width) * 1.6
        let spacingU = marchSpacing / route.total
        marchProgress = Double(sprites.count - 1) * spacingU
        if probeEnabled {
            probeWrite(String(format: "march: len=%.0fpt @ %.1f", route.total, Self.now()))
        }
        // 初始沿路线起点依次排开（0 号在最前）
        for (i, sprite) in sprites.enumerated() {
            sprite.brain.formationMarching = true
            let u = max(0, marchProgress - Double(i) * spacingU)
            sprite.brain.formationTarget = routePoint(route, at: u)
        }
    }

    /// 行进更新：路线进度前进，各宠物保持间距跟进
    private func updateMarch(dt: Double) {
        guard let route = marchRoute else { return }
        marchProgress += dt * marchSpeed / route.total
        if marchProgress >= 1.0 {
            // 走完路线：解散，自由活动
            disbandFormation()
            formationTimer = Double.random(in: formationRoamRange)
            return
        }
        let spacingU = marchSpacing / route.total
        for (i, sprite) in sprites.enumerated() {
            let u = max(0, marchProgress - Double(i) * spacingU)
            sprite.brain.formationTarget = routePoint(route, at: u)
        }
    }

    /// 生成随机行进路线（折线 + 弧长参数化），5 种路线
    private func buildMarchRoute() -> (points: [CGPoint], cum: [Double], total: Double) {
        let b = Self.allScreensBounds()
        let w = b.width, h = b.height
        let m: CGFloat = 70
        let kind = Int.random(in: 0..<5)
        var pts: [CGPoint] = []

        switch kind {
        case 0: // 横向蛇形：左右穿梭逐行下行
            let rows = 3
            let stepY = (h - 2 * m) / CGFloat(rows)
            for r in 0..<rows {
                let y = b.minY + m + CGFloat(r) * stepY + stepY / 2
                if r % 2 == 0 {
                    pts.append(CGPoint(x: b.minX + m, y: y))
                    pts.append(CGPoint(x: b.maxX - m, y: y))
                } else {
                    pts.append(CGPoint(x: b.maxX - m, y: y))
                    pts.append(CGPoint(x: b.minX + m, y: y))
                }
            }
        case 1: // 纵向蛇形：上下穿梭逐列右移
            let cols = 3
            let stepX = (w - 2 * m) / CGFloat(cols)
            for c in 0..<cols {
                let x = b.minX + m + CGFloat(c) * stepX + stepX / 2
                if c % 2 == 0 {
                    pts.append(CGPoint(x: x, y: b.minY + m))
                    pts.append(CGPoint(x: x, y: b.maxY - m))
                } else {
                    pts.append(CGPoint(x: x, y: b.maxY - m))
                    pts.append(CGPoint(x: x, y: b.minY + m))
                }
            }
        case 2: // 大波浪：正弦起伏横穿并折返
            let steps = 80
            for pass in 0..<2 {
                for i in 0...steps {
                    let t = CGFloat(i) / CGFloat(steps)
                    let x = pass == 0
                        ? b.minX + m + (w - 2 * m) * t
                        : b.maxX - m - (w - 2 * m) * t
                    let y = b.midY + sin(t * 6 * .pi) * (h * 0.28)
                    pts.append(CGPoint(x: x, y: y))
                }
            }
        case 3: // 圆形巡回：绕两圈
            let cx = b.midX, cy = b.midY
            let r = min(w, h) * 0.3
            let steps = 64
            for _ in 0..<2 {
                for i in 0...steps {
                    let a = 2 * .pi * CGFloat(i) / CGFloat(steps)
                    pts.append(CGPoint(x: cx + cos(a) * r, y: cy + sin(a) * r))
                }
            }
        default: // 8字形巡回（lemniscate）绕两圈
            let cx = b.midX, cy = b.midY
            let a = min(w, h) * 0.26
            let steps = 96
            for _ in 0..<2 {
                for i in 0...steps {
                    let t = 2 * .pi * CGFloat(i) / CGFloat(steps)
                    let den = 1 + sin(t) * sin(t)
                    pts.append(CGPoint(x: cx + a * cos(t) / den,
                                       y: cy + a * sin(t) * cos(t) / den))
                }
            }
        }

        // 弧长参数化
        var cum: [Double] = [0]
        for i in 1..<pts.count {
            cum.append(cum[i - 1] + Double(hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)))
        }
        return (pts, cum, cum.last ?? 1)
    }

    /// 路线上的弧长位置点
    private func routePoint(_ route: (points: [CGPoint], cum: [Double], total: Double), at u: Double) -> CGPoint {
        let s = u * route.total
        let cum = route.cum
        var idx = 1
        while idx < cum.count - 1 && cum[idx] < s { idx += 1 }
        let segLen = max(0.001, cum[idx] - cum[idx - 1])
        let seg = (s - cum[idx - 1]) / segLen
        let a = route.points[idx - 1], b = route.points[idx]
        return CGPoint(x: a.x + (b.x - a.x) * CGFloat(seg),
                       y: a.y + (b.y - a.y) * CGFloat(seg))
    }

    func disbandFormation() {
        for sprite in sprites {
            sprite.brain.formationTarget = nil
            sprite.brain.formationMarching = false
            syncLayerPosition(sprite)   // 恢复（去掉波浪偏移）
        }
        formation = nil
        formationActive = false
        marchRoute = nil
    }

    /// 各队形的站位计算
    private func formationSlots(_ type: Formation, count: Int, center: CGPoint, petSize: CGSize) -> [CGPoint] {
        let n = max(1, count)
        switch type {
        case .heart:
            let hs = 10.0
            return (0..<n).map { i in
                let t = 2 * Double.pi * Double(i) / Double(n) + 0.35
                return CGPoint(x: center.x + 16 * pow(sin(t), 3) * hs,
                               y: center.y + (13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)) * hs)
            }
        case .circle:
            let r = max(80.0, Double(petSize.width) * 0.5 + 40 + Double(n) * 3)
            return (0..<n).map { i in
                let a = 2 * Double.pi * Double(i) / Double(n)
                return CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
            }
        case .row:
            let sp = Double(petSize.width) + 14
            return (0..<n).map { i in
                CGPoint(x: center.x + (Double(i) - Double(n - 1) / 2) * sp, y: center.y)
            }
        case .column:
            let sp = Double(petSize.height) + 14
            return (0..<n).map { i in
                CGPoint(x: center.x, y: center.y + (Double(i) - Double(n - 1) / 2) * sp)
            }
        case .grid:
            let cols = max(1, Int(ceil(sqrt(Double(n)))))
            let sp = Double(petSize.width) + 10
            let rows = (n + cols - 1) / cols
            return (0..<n).map { i in
                let r = i / cols, c = i % cols
                return CGPoint(x: center.x + (Double(c) - Double(cols - 1) / 2) * sp,
                               y: center.y + (Double(r) - Double(rows - 1) / 2) * sp)
            }
        case .diamond:
            let a = 130.0, b = 90.0
            return (0..<n).map { i in
                let th = 2 * Double.pi * Double(i) / Double(n)
                let denom = abs(cos(th)) + abs(sin(th))
                return CGPoint(x: center.x + a * cos(th) / denom,
                               y: center.y + b * sin(th) / denom)
            }
        case .spiral:
            return (0..<n).map { i in
                let r = 20 + Double(i) * (280.0 / Double(n))
                let th = Double(i) * 0.7
                return CGPoint(x: center.x + cos(th) * r, y: center.y + sin(th) * r)
            }
        case .march:
            // 行进队形由 startMarchFormation 单独处理，这里不产生站位
            return Array(repeating: center, count: n)
        }
    }

    private func clampToBounds(_ p: CGPoint) -> CGPoint {
        let b = Self.allScreensBounds()
        let size = sprites.isEmpty ? CGSize(width: 60, height: 60) : sprites[0].layer.bounds.size
        return CGPoint(x: min(max(p.x, b.minX), b.maxX - size.width),
                       y: min(max(p.y, b.minY), b.maxY - size.height))
    }

    /// 队形期间的同步动作：已到位的宠物按队形类型做协调动作
    /// 爱心=全体心跳搏动 / 圆形·菱形·螺旋=整体旋转 / 一排·一列=波浪 / 方阵=棋盘交替起伏
    /// 队形同步动作的时钟推进（偏移计算在 updateSpritePosition 内统一应用，单事务避免闪烁）
    private func applyFormationAction(dt: Double) {
        waveTime += dt
    }

    /// 计算单只宠物的同步动作偏移（相对其队形站位）
    private func formationActionOffset(_ sprite: PetSprite, type: Formation, index i: Int, count n: Int) -> CGPoint {
        let t = waveTime
        switch type {
        case .heart:
            // 心跳：全体同步「噗通-噗通」双搏动起伏
            let beat = sin(2 * Double.pi * t / 1.2) * 0.7 + sin(2 * Double.pi * t / 0.6) * 0.3
            return CGPoint(x: 0, y: beat * 10)
        case .row, .column:
            // 波浪：沿队列依次起伏（一排横波 / 一列竖波）
            let phase = 2 * Double.pi * Double(i) / Double(n)
            return CGPoint(x: 0, y: sin(2 * Double.pi * t / 1.4 + phase) * 12)
        case .grid:
            // 棋盘格：相邻宠物交替起伏
            let checker = (i % 2 == 0) ? 1.0 : -1.0
            return CGPoint(x: 0, y: sin(2 * Double.pi * t / 1.0) * 8 * checker)
        case .circle, .diamond, .spiral:
            // 旋转：整体绕队形中心缓慢转动（12 秒一圈）
            let slot = sprite.brain.pos
            let dx = slot.x - formationCenter.x
            let dy = slot.y - formationCenter.y
            let r = max(1, sqrt(dx * dx + dy * dy))
            let newAngle = atan2(dy, dx) + 2 * Double.pi * t / 12.0
            let vx = formationCenter.x + cos(newAngle) * r
            let vy = formationCenter.y + sin(newAngle) * r
            return CGPoint(x: vx - slot.x, y: vy - slot.y)
        case .march:
            // 行进中由路线驱动，无额外动作偏移
            return .zero
        }
    }

    // MARK: - 显示同步驱动（低功耗核心）

    /// 启动 CVDisplayLink：随显示器刷新回调（60/120Hz，精确无掉拍）
    private func startDisplayLink() {
        guard displayLink == nil, isVisible, !suspended else { return }
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link = link else { return }
        CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
            guard let self = self, !self.pendingMainUpdate else { return kCVReturnSuccess }
            self.pendingMainUpdate = true
            DispatchQueue.main.async {
                self.pendingMainUpdate = false
                self.displayTick()
            }
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(link)
        displayLink = link
    }

    private func stopDisplayLink() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
    }

    /// 显示刷新回调（主线程）
    private func displayTick() {
        guard isVisible, !suspended else { return }
        let now = Self.now()
        if lastDisplayTime == 0 { lastDisplayTime = now }
        let frameDt = now - lastDisplayTime
        // 移动积分门控：按配置的移动帧率积分，其余刷新只推进动画/状态
        moveAccum += frameDt
        lastDisplayTime = now

        if draggingSprite != nil {
            // 拖动中：被拖动的宠物只播 drag 动画，其余宠物照常活动
            let fastInterval = sprites.first?.brain.fastInterval ?? 0.0167
            let shouldMove = moveAccum >= fastInterval
            if shouldMove { moveAccum -= fastInterval }
            for sprite in sprites {
                _ = sprite.brain.tick(now: now, shouldMove: shouldMove)
                updateSpritePosition(sprite)
            }
            startDisplayLink()
            return
        }

        let fastInterval = sprites.first?.brain.fastInterval ?? 0.0167
        let shouldMove = moveAccum >= fastInterval
        if shouldMove { moveAccum -= fastInterval }

        // 动态穿透：光标悬停在宠物上时接收事件（可拖动/右键），其余区域点击穿透
        updateClickThroughForMouse()

        // 驱动所有宠物（各自随机状态机）
        var anyActive = false
        for sprite in sprites {
            if sprite.brain.tick(now: now, shouldMove: shouldMove) { anyActive = true }
            updateSpritePosition(sprite)   // 单事务应用位置（含队形同步动作偏移，避免闪烁）
        }
        // 随机队形调度（跟随关闭且多只时生效）
        updateFormation(dt: frameDt)
        if anyActive {
            startDisplayLink()   // 保持驱动
        } else {
            stopDisplayLink()    // 全部静止：降频巡检
            startSlowPoll()
        }
    }

    /// 完全静止时的 2Hz 巡检（状态变化时自动恢复显示链接）
    private func startSlowPoll() {
        guard slowTimer == nil, isVisible, !suspended else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.isVisible, !self.suspended, self.draggingSprite == nil else { return }
            let now = Self.now()
            var anyActive = false
            for sprite in self.sprites {
                if sprite.brain.tick(now: now, shouldMove: false) { anyActive = true }
                self.syncLayerPosition(sprite)
            }
            if anyActive {
                self.stopSlowPoll()
                self.startDisplayLink()
            }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        slowTimer = t
    }

    private func stopSlowPoll() {
        slowTimer?.invalidate()
        slowTimer = nil
    }

    // MARK: - 拖动（仅鼠标穿透关闭时）

    func handleMouseDown(_ event: NSEvent) {
        guard !settings.clickThrough else { return }
        let mouseScreen = NSEvent.mouseLocation
        guard let sprite = sprite(at: mouseScreen) else { return }
        disbandFormation()   // 拖动：解散队形，其他宠物自由活动
        draggingSprite = sprite
        // 画布窗口原点为 (0,0)，偏移量相对宠物位置计算，避免瞬移
        sprite.dragOffset = CGPoint(x: mouseScreen.x - sprite.brain.pos.x,
                                    y: mouseScreen.y - sprite.brain.pos.y)
        sprite.brain.beginDrag(now: Self.now())
        // 保持驱动：拖动中需要推进 drag 动画
        stopSlowPoll()
        startDisplayLink()
    }

    func handleMouseDragged(_ event: NSEvent) {
        guard let sprite = draggingSprite else { return }
        let mouseScreen = NSEvent.mouseLocation
        let newOrigin = CGPoint(x: mouseScreen.x - sprite.dragOffset.x,
                                y: mouseScreen.y - sprite.dragOffset.y)
        sprite.brain.setPosition(newOrigin)  // 直接同步，不触发回调
        syncLayerPosition(sprite)
    }

    func handleMouseUp(_ event: NSEvent) {
        guard let sprite = draggingSprite else { return }
        draggingSprite = nil
        sprite.brain.endDrag(now: Self.now())
        moveAccum = 0
        lastDisplayTime = Self.now()
        startDisplayLink()
    }

    // MARK: - 休眠/会话

    @objc private func screenDidSleep() { suspend() }
    @objc private func sessionResigned() { suspend() }
    @objc private func screenDidWake() { resume() }
    @objc private func sessionBecameActive() { resume() }

    private func suspend() {
        suspended = true
        stopDisplayLink()
        stopSlowPoll()
    }

    private func resume() {
        suspended = false
        if isVisible {
            lastDisplayTime = Self.now()
            startDisplayLink()
        }
    }

    // MARK: - 工具

    static func now() -> CFTimeInterval {
        CACurrentMediaTime()
    }

    /// 所有屏幕的并集（左下角坐标系）
    static func allScreensBounds() -> CGRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return CGRect(x: 0, y: 0, width: 1440, height: 900) }
        var union = screens[0].frame
        for s in screens.dropFirst() {
            union = union.union(s.frame)
        }
        return union
    }
}

// ============================================================================
// 宠物内容视图：负责鼠标事件
// ============================================================================

final class PetView: NSView {
    weak var controller: PetController?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        controller?.handleMouseDown(event)
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.handleMouseDragged(event)
    }

    override func mouseUp(with event: NSEvent) {
        controller?.handleMouseUp(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        // 右键弹出菜单
        guard let controller = controller, !controller.settings.clickThrough else { return }
        let menu = PetMenu.buildMenu()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}
