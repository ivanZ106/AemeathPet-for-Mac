import Foundation

/// 应用配置：UserDefaults 持久化 + 档位表
enum Settings {

    // MARK: - 档位（参考原版 9 档缩放 0.3x~1.9x、8 档透明度 30%~100%）
    static let scaleOptions: [Double] = [0.3, 0.5, 0.7, 0.8, 0.9, 1.0, 1.2, 1.5, 1.9]
    static let transparencyOptions: [Double] = [0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
    /// 移动积分帧率（Hz）
    static let tickRateOptions: [Int] = [20, 30, 45, 60, 90, 120]

    static let defaultScaleIndex = 0      // 0.3x（默认大小）
    static let defaultTransparencyIndex = 7 // 100%
    static let defaultTickRateIndex = 3   // 60Hz（默认）
    static let defaultInstanceCount = 1   // 多开数量（默认 1 只）
    static let maxInstanceCount = 100     // 多开数量上限（单一来源，持久化钳制用）
    static let defaultFormationEnabled = true // 随机队形（默认开启）
    /// 队形频率档位（0 慢 / 1 正常 / 2 快 / 3 很快）
    static let formationFrequencyOptions = ["慢", "正常", "快", "很快"]
    static let defaultFormationFrequencyIndex = 1 // 正常

    enum DisplayLevel: Int, CaseIterable {
        case top = 1      // 置顶（悬浮于普通窗口之上）
        case normal = 2   // 普通层级
        case desktop = 3  // 桌面层级（低于普通窗口）

        var title: String {
            switch self {
            case .top: return "置顶"
            case .normal: return "普通"
            case .desktop: return "桌面"
            }
        }
    }

    struct State {
        var scaleIndex: Int
        var transparencyIndex: Int
        var tickRateIndex: Int
        var instanceCount: Int
        var formationEnabled: Bool
        var formationFrequencyIndex: Int
        var clickThrough: Bool
        var followMouse: Bool
        var displayLevel: DisplayLevel
        var autoStart: Bool
        var startPaused: Bool
        var wanderIdleStayMode: Int // 0 始终移动 / 1 概率停驻 / 2 停驻

        static let defaults = State(
            scaleIndex: Settings.defaultScaleIndex,
            transparencyIndex: Settings.defaultTransparencyIndex,
            tickRateIndex: Settings.defaultTickRateIndex,
            instanceCount: Settings.defaultInstanceCount,
            formationEnabled: Settings.defaultFormationEnabled,
            formationFrequencyIndex: Settings.defaultFormationFrequencyIndex,
            clickThrough: false,         // 默认关闭：可直接拖动宠物（与原版一致）
            followMouse: false,
            displayLevel: .top,
            autoStart: false,
            startPaused: false,
            wanderIdleStayMode: 2
        )

        var scale: Double { Settings.scaleOptions[scaleIndex] }
        var transparency: Double { Settings.transparencyOptions[transparencyIndex] }
        var tickRate: Int { Settings.tickRateOptions[tickRateIndex] }
    }

    // MARK: - 持久化
    private enum Key {
        static let scaleIndex = "scaleIndex"
        static let transparencyIndex = "transparencyIndex"
        static let tickRateIndex = "tickRateIndex"
        static let instanceCount = "instanceCount"
        static let formationEnabled = "formationEnabled"
        static let formationFrequencyIndex = "formationFrequencyIndex"
        static let clickThrough = "clickThrough"
        static let followMouse = "followMouse"
        static let displayLevel = "displayLevel"
        static let autoStart = "autoStart"
        static let startPaused = "startPaused"
        static let wanderIdleStayMode = "wanderIdleStayMode"
    }

    static var state: State {
        get {
            let d = UserDefaults.standard
            let clamp = { (v: Int, count: Int) -> Int in min(max(v, 0), count - 1) }
            var s = State.defaults
            if let v = d.object(forKey: Key.scaleIndex) as? Int { s.scaleIndex = clamp(v, scaleOptions.count) }
            if let v = d.object(forKey: Key.transparencyIndex) as? Int { s.transparencyIndex = clamp(v, transparencyOptions.count) }
            if let v = d.object(forKey: Key.tickRateIndex) as? Int { s.tickRateIndex = clamp(v, tickRateOptions.count) }
            if let v = d.object(forKey: Key.instanceCount) as? Int { s.instanceCount = clamp(v, Settings.maxInstanceCount + 1) }
            if d.object(forKey: Key.formationEnabled) != nil { s.formationEnabled = d.bool(forKey: Key.formationEnabled) }
            if let v = d.object(forKey: Key.formationFrequencyIndex) as? Int { s.formationFrequencyIndex = clamp(v, formationFrequencyOptions.count) }
            if d.object(forKey: Key.clickThrough) != nil { s.clickThrough = d.bool(forKey: Key.clickThrough) }
            if d.object(forKey: Key.followMouse) != nil { s.followMouse = d.bool(forKey: Key.followMouse) }
            if let raw = d.object(forKey: Key.displayLevel) as? Int, let lvl = DisplayLevel(rawValue: raw) { s.displayLevel = lvl }
            if d.object(forKey: Key.autoStart) != nil { s.autoStart = d.bool(forKey: Key.autoStart) }
            if d.object(forKey: Key.startPaused) != nil { s.startPaused = d.bool(forKey: Key.startPaused) }
            if let v = d.object(forKey: Key.wanderIdleStayMode) as? Int { s.wanderIdleStayMode = clamp(v, 3) }
            return s
        }
        set {
            let d = UserDefaults.standard
            d.set(newValue.scaleIndex, forKey: Key.scaleIndex)
            d.set(newValue.transparencyIndex, forKey: Key.transparencyIndex)
            d.set(newValue.tickRateIndex, forKey: Key.tickRateIndex)
            d.set(newValue.instanceCount, forKey: Key.instanceCount)
            d.set(newValue.formationEnabled, forKey: Key.formationEnabled)
            d.set(newValue.formationFrequencyIndex, forKey: Key.formationFrequencyIndex)
            d.set(newValue.clickThrough, forKey: Key.clickThrough)
            d.set(newValue.followMouse, forKey: Key.followMouse)
            d.set(newValue.displayLevel.rawValue, forKey: Key.displayLevel)
            d.set(newValue.autoStart, forKey: Key.autoStart)
            d.set(newValue.startPaused, forKey: Key.startPaused)
            d.set(newValue.wanderIdleStayMode, forKey: Key.wanderIdleStayMode)
        }
    }
}
