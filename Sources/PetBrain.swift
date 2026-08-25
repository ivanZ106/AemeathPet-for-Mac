import AppKit
import QuartzCore

// ============================================================================
// 爱弥斯桌宠 —— 行为状态机（纯逻辑，可脱离窗口测试）
// 移植自原版 pet.py：游荡/跟随/好奇/休息/待机动画 + 惯性移动 + 边缘处理
// 低功耗设计：
//   - 移动时快 tick（20Hz）驱动惯性积分
//   - 静止播动画时按帧延时精确调度（约 9FPS，仅在有帧需要时唤醒）
//   - 完全静止时慢 tick（2Hz）检查状态
// ============================================================================

enum MotionState {
    case wander, follow, curious, rest, idle
}

enum PetConstants {
    static let tickSlow: Double = 0.5         // 静止巡检 2Hz

    // 速度（px/s，按实际 tick 自动换算，保证不同帧率下速度一致）
    static let speedXPxS: CGFloat = 100
    static let speedYPxS: CGFloat = 66
    static let inertia: CGFloat = 0.97        // 惯性因子（时间常数 ≈0.55s，与原版相近）
    static let intent: CGFloat = 0.03         // 意图因子
    static let jitterAmp: CGFloat = 15.0   // px/s 抖动幅度

    static let restChance = 0.6               // 到达目标后休息概率
    static let restDurationMin: Double = 1.0
    static let restDurationMax: Double = 3.0
    static let restDistance: CGFloat = 20     // 到达目标判定距离

    static let stopChancePerSec = 0.06        // 游荡中随机停下概率（每秒）
    static let stopDurationMin: Double = 4.0
    static let stopDurationMax: Double = 8.0

    static let followStartDist: CGFloat = 200 // 开始跟随距离
    static let followStopDist: CGFloat = 60   // 停止跟随/好奇距离
    static let followOffset: CGFloat = 80     // 跟随保持偏移

    static let targetChangeMin: Double = 4.0  // 目标点保持 4~10 秒
    static let targetChangeMax: Double = 10.0

    static let edgeEscapeChance = 0.3         // 撞边后走出屏幕概率
    static let respawnMargin: CGFloat = 50    // 屏幕外重生边距

    static let stayPutChance = 0.3            // 概率停驻模式下停下的概率

    static let speedWander: CGFloat = 0.8
    static let speedFollow: CGFloat = 1.2
    static let speedCurious: CGFloat = 0.5

    static let pausedAnimMin: Double = 30.0   // 暂停模式随机动画间隔
    static let pausedAnimMax: Double = 120.0
}

/// 渲染指令：控制器据此更新画面
struct RenderState {
    let image: CGImage?
    let flipped: Bool
}

final class PetBrain {

    // MARK: - 帧率（可配置，20~120Hz；速度按 px/s 换算，帧率无关）
    var tickRate: Double = 60 {
        didSet {
            tickRate = min(max(tickRate, 1), 240)
        }
    }

    /// 当前移动积分间隔（秒），由控制器用于移动门控
    var fastInterval: Double { 1.0 / tickRate }

    // MARK: - 输入（由控制器维护）
    var bounds: CGRect = .zero            // 活动区域（所有屏幕并集，左下角坐标系）
    var windowSize: CGSize = CGSize(width: 200, height: 200)
    var followMouse = false
    /// 跟随模式下的固定偏移（多只宠物分散用，心形分布）
    var followAnchor: CGPoint = .zero
    /// 队形目标：非 nil 时走向该点并停驻（多开随机队形模式）
    var formationTarget: CGPoint?
    /// 行进模式：目标持续移动，到达后不驻留（列队行进用）
    var formationMarching = false
    var paused = false

    /// 是否已在队形位置停驻（供波浪等同步动作判断）
    var settled: Bool { !isMoving && isIdlePlaying }
    var isHidden = false
    var wanderIdleStayMode = 2            // 0 始终移动 / 1 概率停驻 / 2 停驻

    // MARK: - 输出回调
    var onRender: ((RenderState) -> Void)?
    var onMove: ((CGPoint) -> Void)?

    // MARK: - 内部状态
    private(set) var pos: CGPoint = .zero
    private(set) var motion: MotionState = .wander
    private(set) var currentFrame: CGImage?
    private(set) var movingRight = true
    private(set) var dragging = false

    private var vel: CGPoint = .zero
    private var target: CGPoint = .zero
    private var targetTimer: Double = 0
    private var isMoving = true
    private var isIdlePlaying = false
    private var idleAllowsMove = false
    private var frameIndex = 0
    private var clipImages: [NSImage] = []
    private var clipDelays: [Double] = []
    private var clipIsAnimating = false
    private var nextFrameTime: CFTimeInterval = 0
    private var restTimer: Double = 0
    private var idleStopTimer: Double = 0
    private var pausedAnimTimer: Double = 0
    private var jitter: CGPoint = .zero
    private var jitterTimer: Double = 0
    private var tickCount = 0
    private var lastMouse: CGPoint?
    private var lastTick: CFTimeInterval = 0
    private var lastMoveTime: CFTimeInterval = 0
    private var respawning = false   // 走出屏幕重生期间不钳制
    private var lastReported: CGPoint = .zero
    private var needsRender = true

    // 供性能测试统计
    private(set) var animFrameAdvances = 0

    // MARK: - 生命周期

    init() {
        resetToWander(now: 0)
    }

    func start(bounds: CGRect, at origin: CGPoint, now: CFTimeInterval) {
        self.bounds = bounds
        pos = origin
        lastTick = now
        lastMoveTime = now
        lastReported = origin
        resetToWander(now: now)
        needsRender = true
    }

    func resetToWander(now: CFTimeInterval) {
        motion = .wander
        isMoving = true
        isIdlePlaying = false
        idleAllowsMove = false
        vel = .zero
        target = randomPointInside()
        targetTimer = Double.random(in: PetConstants.targetChangeMin...PetConstants.targetChangeMax)
        play(.move, now: now, flipped: movingRight)
    }

    // MARK: - 主循环
    // 由 CVDisplayLink（显示刷新同步）驱动；shouldMove 控制移动积分门控
    // 返回 true = 需要持续驱动（移动/动画中）；false = 完全静止（可降频巡检）

    func tick(now: CFTimeInterval, shouldMove: Bool) -> Bool {
        tickCount += 1
        let dt = min(max(now - lastTick, 0.0), 0.1)
        lastTick = now

        if isHidden { return false }

        if dragging {
            // 拖动中：只推进 drag 动画，不做状态机/移动
            advanceFrameIfDue(now: now)
            return true
        }

        if paused {
            tickPaused(now, dt: dt)
            return true   // 暂停中播放基础动画
        }

        // ===== 队形模式：走向队形点并停驻 =====
        if let ft = formationTarget {
            return tickFormation(target: ft, now: now, dt: dt, shouldMove: shouldMove)
        }

        // ===== 随机停下休息（游荡模式专属） =====
        if motion == .wander, isMoving, !isIdlePlaying,
           Double.random(in: 0...1) < PetConstants.stopChancePerSec * dt {
            switchToIdle(now: now)
            return true
        }

        // ===== 休息状态：播放 idle 动画直到时间到 =====
        if motion == .rest {
            restTimer -= dt
            advanceFrameIfDue(now: now)
            if restTimer <= 0 {
                motion = .wander
                target = randomPointInside()
                targetTimer = Double.random(in: PetConstants.targetChangeMin...PetConstants.targetChangeMax)
                switchToMove(now: now)
            }
            return true
        }

        // ===== 待机动画播放中（停下不移动） =====
        if !isMoving {
            idleStopTimer -= dt
            advanceFrameIfDue(now: now)
            if idleStopTimer <= 0 {
                switchToMove(now: now)
                return true
            }
            return clipIsAnimating   // 无动画的静帧 → false（降频巡检）
        }

        // ===== 移动路径：动画照常推进 =====
        advanceFrameIfDue(now: now)

        // ===== 移动积分门控：本帧不积分时保持驱动 =====
        if !shouldMove {
            return true
        }

        // 移动积分的实际时间差（距上次积分，而非距上次显示刷新）
        let moveDt = min(max(now - lastMoveTime, 0.0), 0.1)
        lastMoveTime = now

        // ===== 鼠标位置（仅跟随模式启用时查询，避免无谓开销） =====
        var mouse: CGPoint?
        var mouseMoved = false
        if followMouse {
            let m = NSEvent.mouseLocation
            mouse = m
            mouseMoved = lastMouse.map { abs($0.x - m.x) > 0.5 || abs($0.y - m.y) > 0.5 } ?? true
            lastMouse = m
        }

        // ===== 到目标距离 =====
        var dx = target.x - pos.x
        var dy = target.y - pos.y
        var dist = max(1, sqrt(dx * dx + dy * dy))

        // ===== 状态判断与切换 =====
        if !followMouse, motion == .follow || motion == .curious {
            motion = .wander
        }

        if followMouse, let m = mouse {
            let dmx = m.x - pos.x
            let dmy = m.y - pos.y
            let distMouse = sqrt(dmx * dmx + dmy * dmy)
            if distMouse > PetConstants.followStartDist {
                motion = .follow
            } else if distMouse < PetConstants.followStopDist {
                motion = .curious
            }
        } else if motion == .wander, dist < PetConstants.restDistance {
            if Double.random(in: 0...1) < PetConstants.restChance {
                if wanderIdleStayMode == 0 {
                    target = randomPointInside()
                    targetTimer = Double.random(in: PetConstants.targetChangeMin...PetConstants.targetChangeMax)
                } else if !isIdlePlaying {
                    motion = .rest
                    restTimer = Double.random(in: PetConstants.restDurationMin...PetConstants.restDurationMax)
                    switchToIdle(now: now)
                    return true
                }
            } else {
                target = randomPointInside()
                targetTimer = Double.random(in: PetConstants.targetChangeMin...PetConstants.targetChangeMax)
            }
        }

        // ===== 定时更换目标（仅游荡） =====
        if motion == .wander {
            targetTimer -= dt
            if targetTimer <= 0 {
                target = randomPointInside()
                targetTimer = Double.random(in: PetConstants.targetChangeMin...PetConstants.targetChangeMax)
            }
        }

        // ===== 速度倍率 =====
        let speedMul: CGFloat
        switch motion {
        case .wander: speedMul = PetConstants.speedWander
        case .follow: speedMul = PetConstants.speedFollow
        case .curious: speedMul = PetConstants.speedCurious
        default: speedMul = 1.0
        }

        // ===== 跟随/好奇：仅鼠标移动时更新目标 =====
        if motion == .follow || motion == .curious {
            if mouseMoved, let m = mouse {
                // 围绕鼠标的固定锚点偏移（心形分布，所有状态统一，保证成形）
                target = CGPoint(x: m.x + followAnchor.x,
                                 y: m.y + followAnchor.y)
                dx = target.x - pos.x
                dy = target.y - pos.y
                dist = max(1, sqrt(dx * dx + dy * dy))
            }
        }

        // ===== 朝目标移动（惯性，px/s，帧率无关） =====
        let desiredVX = dx / dist * PetConstants.speedXPxS * speedMul
        let desiredVY = dy / dist * PetConstants.speedYPxS * speedMul
        let alpha = 1.0 - exp(-moveDt / 0.55)   // 平滑时间常数 ≈0.55s
        vel.x += (desiredVX - vel.x) * alpha
        vel.y += (desiredVY - vel.y) * alpha

        // 抖动：≈150ms 刷新一次的 px/s 扰动（时间驱动，帧率无关）
        jitterTimer -= dt
        if jitterTimer <= 0 {
            jitterTimer = 0.15
            jitter = CGPoint(x: CGFloat.random(in: -PetConstants.jitterAmp...PetConstants.jitterAmp),
                             y: CGFloat.random(in: -PetConstants.jitterAmp...PetConstants.jitterAmp))
        }
        pos.x += (vel.x + jitter.x) * moveDt
        pos.y += (vel.y + jitter.y) * moveDt

        // ===== 边缘处理 =====
        handleEdge()

        // ===== 方向切换 =====
        let newRight = vel.x > 30.0
        let newLeft = vel.x < -30.0
        if newLeft && movingRight && !isIdlePlaying {
            movingRight = false
            play(.move, now: now, flipped: true)
        } else if newRight && !movingRight && !isIdlePlaying {
            movingRight = true
            play(.move, now: now, flipped: false)
        }

        // ===== 位置上报（仅明显变化时，避免无谓的窗口移动） =====
        let mdx = pos.x - lastReported.x
        let mdy = pos.y - lastReported.y
        if mdx * mdx + mdy * mdy >= 0.25 {
            lastReported = pos
            onMove?(pos)
        }

        return true
    }

    // MARK: - 队形模式

    private func tickFormation(target: CGPoint, now: CFTimeInterval, dt: Double, shouldMove: Bool) -> Bool {
        advanceFrameIfDue(now: now)
        if !shouldMove { return true }
        let dx = target.x - pos.x
        let dy = target.y - pos.y
        let dist = max(1, sqrt(dx * dx + dy * dy))
        if dist < 6 && !formationMarching {
            // 到达队形位：停驻并播放待机动画（行进模式不驻留，持续跟进）
            if isMoving {
                switchToIdle(now: now)
            }
            return true
        }
        // 向队形点移动（惯性积分，px/s）
        let moveDt = min(max(now - lastMoveTime, 0.0), 0.1)
        lastMoveTime = now
        let desiredVX = dx / dist * PetConstants.speedXPxS * PetConstants.speedFollow
        let desiredVY = dy / dist * PetConstants.speedYPxS * PetConstants.speedFollow
        let alpha = 1.0 - exp(-moveDt / 0.55)
        vel.x += (desiredVX - vel.x) * alpha
        vel.y += (desiredVY - vel.y) * alpha
        pos.x += (vel.x + jitter.x) * moveDt
        pos.y += (vel.y + jitter.y) * moveDt
        handleEdge()
        // 方向
        if vel.x < -30 && movingRight {
            movingRight = false
            play(.move, now: now, flipped: true)
        } else if vel.x > 30 && !movingRight {
            movingRight = true
            play(.move, now: now, flipped: false)
        }
        // 位置上报
        let mdx = pos.x - lastReported.x
        let mdy = pos.y - lastReported.y
        if mdx * mdx + mdy * mdy >= 0.25 {
            lastReported = pos
            onMove?(pos)
        }
        return true
    }

    // MARK: - 暂停模式

    private func tickPaused(_ now: CFTimeInterval, dt: Double) {
        // 基础为 idle2 动画；每 30~120s 随机换一个 idle 动画播 4~8s
        advanceFrameIfDue(now: now)
        pausedAnimTimer -= dt
        if pausedAnimTimer <= 0 {
            playRandomIdle(now: now)
            pausedAnimTimer = Double.random(in: PetConstants.pausedAnimMin...PetConstants.pausedAnimMax)
        }
    }

    // MARK: - 状态切换

    func setPaused(_ p: Bool, now: CFTimeInterval) {
        guard paused != p else { return }
        paused = p
        if p {
            // 进入暂停：停住，播放基础动画
            isMoving = false
            isIdlePlaying = false
            play(.idle2, now: now, flipped: movingRight)
            pausedAnimTimer = Double.random(in: PetConstants.pausedAnimMin...PetConstants.pausedAnimMax)
        } else {
            // 恢复：回到游荡
            resetToWander(now: now)
        }
    }

    private func switchToIdle(now: CFTimeInterval) {
        isIdlePlaying = false
        idleAllowsMove = false

        switch wanderIdleStayMode {
        case 0: // 始终移动：播动画但继续走
            isIdlePlaying = true
            idleAllowsMove = true
            isMoving = true
        case 2: // 停驻
            isIdlePlaying = true
            idleAllowsMove = false
            isMoving = false
        default: // 概率停驻
            if Double.random(in: 0...1) < PetConstants.stayPutChance {
                isIdlePlaying = true
                idleAllowsMove = Bool.random()
                isMoving = idleAllowsMove
            } else {
                isIdlePlaying = false
                idleAllowsMove = false
                isMoving = false
            }
        }

        if isIdlePlaying {
            playRandomIdle(now: now)
        } else {
            // 播静帧：随机取一帧
            setStaticFrame(from: randomIdleClip())
        }
        idleStopTimer = Double.random(in: PetConstants.stopDurationMin...PetConstants.stopDurationMax)
    }

    private func switchToMove(now: CFTimeInterval) {
        isIdlePlaying = false
        idleAllowsMove = false
        isMoving = true
        play(.move, now: now, flipped: movingRight)
    }

    // MARK: - 拖动

    func beginDrag(now: CFTimeInterval) {
        dragging = true
        isMoving = false
        isIdlePlaying = false
        play(.drag, now: now, flipped: movingRight)
    }

    func endDrag(now: CFTimeInterval) {
        dragging = false
        if paused {
            play(.idle2, now: now, flipped: movingRight)
        } else if isMoving {
            play(.move, now: now, flipped: movingRight)
        } else {
            setStaticFrame(from: randomIdleClip())
        }
    }

    // MARK: - 缩放

    func setWindowSize(_ size: CGSize) {
        windowSize = size
        pos.x = min(max(pos.x, bounds.minX), bounds.maxX - windowSize.width)
        pos.y = min(max(pos.y, bounds.minY), bounds.maxY - windowSize.height)
        lastReported = pos
        onMove?(pos)
    }

    /// 拖动等外部直接设置位置（不触发 onMove 回调）
    func setPosition(_ p: CGPoint) {
        pos = p
        lastReported = p
    }

    // MARK: - 动画控制

    private func play(_ state: PetState, now: CFTimeInterval, flipped: Bool) {
        guard let clip = Assets.clips[state], !clip.images.isEmpty else { return }
        clipImages = clip.images
        clipDelays = clip.delays
        frameIndex = 0
        clipIsAnimating = true
        nextFrameTime = now + clipDelays[0]
        applyCurrentFrame()
    }

    private func playRandomIdle(now: CFTimeInterval) {
        let clip = randomIdleClip()
        guard !clip.images.isEmpty else { return }
        clipImages = clip.images
        clipDelays = clip.delays
        frameIndex = 0
        clipIsAnimating = true
        nextFrameTime = now + clipDelays[0]
        applyCurrentFrame()
    }

    /// 随机取一个 idle 动画片段
    private func randomIdleClip() -> AnimClip {
        let states: [PetState] = [.idle1, .idle2, .idle3, .idle4]
        for _ in 0..<4 {
            if let s = states.randomElement(), let clip = Assets.clips[s] {
                return clip
            }
        }
        return AnimClip.empty
    }

    private func setStaticFrame(from clip: AnimClip) {
        guard !clip.images.isEmpty else { return }
        clipImages = clip.images
        clipDelays = clip.delays
        frameIndex = Int.random(in: 0..<clip.images.count)
        clipIsAnimating = false
        applyCurrentFrame()
    }

    private func advanceFrameIfDue(now: CFTimeInterval) {
        guard clipIsAnimating, !clipImages.isEmpty, now >= nextFrameTime else { return }
        frameIndex = (frameIndex + 1) % clipImages.count
        nextFrameTime = now + clipDelays[frameIndex]
        animFrameAdvances += 1
        applyCurrentFrame()
    }

    private func applyCurrentFrame() {
        guard !clipImages.isEmpty else { return }
        let image = clipImages[frameIndex].cgImageValue
        if image !== currentFrame {
            currentFrame = image
            needsRender = true
        }
        flushRenderIfNeeded()
    }

    private func flushRenderIfNeeded() {
        if needsRender {
            needsRender = false
            onRender?(RenderState(image: currentFrame, flipped: movingRight))
        }
    }

    // MARK: - 移动辅助

    private func randomPointInside() -> CGPoint {
        let w = max(1, bounds.width - windowSize.width)
        let h = max(1, bounds.height - windowSize.height)
        return CGPoint(x: bounds.minX + CGFloat.random(in: 0...w),
                       y: bounds.minY + CGFloat.random(in: 0...h))
    }

    private func handleEdge() {
        let minX = bounds.minX
        let minY = bounds.minY
        let maxX = bounds.maxX - windowSize.width
        let maxY = bounds.maxY - windowSize.height

        // 重生期间：不钳制，直到走回屏幕内
        if respawning {
            if pos.x >= minX && pos.x <= maxX && pos.y >= minY && pos.y <= maxY {
                respawning = false
            }
            return
        }

        var hitEdge = false
        if pos.x <= minX {
            pos.x = minX
            vel.x = abs(vel.x)
            hitEdge = true
        } else if pos.x >= maxX {
            pos.x = maxX
            vel.x = -abs(vel.x)
            hitEdge = true
        }
        if pos.y <= minY {
            pos.y = minY
            vel.y = abs(vel.y)
            hitEdge = true
        } else if pos.y >= maxY {
            pos.y = maxY
            vel.y = -abs(vel.y)
            hitEdge = true
        }

        if hitEdge {
            if isIdlePlaying { return }
            // 撞边后概率走出屏幕再从对侧回来
            if Double.random(in: 0...1) < PetConstants.edgeEscapeChance {
                respawnFromEdge()
                return
            }
        }
    }

    private func respawnFromEdge() {
        let margin = PetConstants.respawnMargin
        let minX = bounds.minX, minY = bounds.minY, maxX = bounds.maxX, maxY = bounds.maxY
        let newPos: CGPoint
        if pos.x <= minX {
            newPos = CGPoint(x: maxX + margin, y: pos.y)
        } else if pos.x + windowSize.width >= maxX {
            newPos = CGPoint(x: minX - margin - windowSize.width, y: pos.y)
        } else if pos.y <= minY {
            newPos = CGPoint(x: pos.x, y: maxY + margin)
        } else {
            newPos = CGPoint(x: pos.x, y: minY - margin - windowSize.height)
        }
        pos = newPos
        vel = .zero
        respawning = true
        target = randomPointInside()
    }
}
