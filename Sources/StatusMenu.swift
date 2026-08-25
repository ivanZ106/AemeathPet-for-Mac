import AppKit

// ============================================================================
// 应用门面：状态栏图标 + 菜单 + 宠物控制器
// ============================================================================

final class PetApp: NSObject {

    static let shared = PetApp()

    let version = "1.0.0"

    private(set) var controller: PetController!
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    private override init() {
        super.init()
    }

    func setup() {
        Assets.load()
        controller = PetController(settings: Settings.state)
        configureStatusItem()
        rebuildMenu()
        controller.show()
    }

    // MARK: - 状态栏

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = Assets.menuBarIcon
            button.imagePosition = .imageOnly
        }
        statusItem.menu = PetMenu.buildMenu()
    }

    func rebuildMenu() {
        statusItem.menu = PetMenu.buildMenu()
    }

    // MARK: - 菜单动作

    @objc func toggleVisibleAction(_ sender: Any?) {
        controller.toggleVisible()
        rebuildMenu()
    }

    @objc func togglePauseAction(_ sender: Any?) {
        controller.togglePause()
        rebuildMenu()
    }

    @objc func toggleFollowAction(_ sender: Any?) {
        let on = !controller.settings.followMouse
        controller.setFollowMouse(on)
        persist()
        rebuildMenu()
    }

    @objc func toggleClickThroughAction(_ sender: Any?) {
        let on = !controller.settings.clickThrough
        controller.setClickThrough(on)
        persist()
        rebuildMenu()
    }

    @objc func setScaleAction(_ sender: NSMenuItem) {
        controller.setScale(sender.tag)
        persist()
        rebuildMenu()
    }

    @objc func setTransparencyAction(_ sender: NSMenuItem) {
        controller.setTransparency(sender.tag)
        persist()
        rebuildMenu()
    }

    @objc func setTickRateAction(_ sender: NSMenuItem) {
        controller.setTickRate(sender.tag)
        persist()
        rebuildMenu()
    }

    @objc func setDisplayLevelAction(_ sender: NSMenuItem) {
        if let level = Settings.DisplayLevel(rawValue: sender.tag) {
            controller.setDisplayLevel(level)
            persist()
            rebuildMenu()
        }
    }

    @objc func setFormationFrequencyAction(_ sender: NSMenuItem) {
        controller.settings.formationFrequencyIndex = sender.tag
        persist()
        rebuildMenu()
    }

    @objc func toggleFormationAction(_ sender: Any?) {
        let on = !controller.settings.formationEnabled
        controller.settings.formationEnabled = on
        if !on { controller.disbandFormation() }
        persist()
        rebuildMenu()
    }

    @objc func instanceCountAction(_ sender: Any?) {
        let maxCount = PetController.maxInstances()
        let alert = NSAlert()
        alert.messageText = "多开模式 · 实例数量"
        alert.informativeText = "提示：每只爱弥斯约 \(Int(PetController.perInstanceMemoryMB))MB 内存预算，量力而行。\n请输入 1~\(maxCount) 只（当前 \(controller.instanceCount) 只）。"
        let combo = NSComboBox(frame: NSRect(x: 0, y: 0, width: 140, height: 26))
        // 常用预设 + 可手动输入任意数量
        combo.addItems(withObjectValues: [1, 2, 3, 4, 5, 6, 8, 10, 15, 20, 30, 50, 80, 100].map { "\($0)" })
        combo.stringValue = "\(controller.instanceCount)"
        combo.isEditable = true
        alert.accessoryView = combo
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            let value = Int(combo.stringValue.trimmingCharacters(in: .whitespaces)) ?? controller.instanceCount
            let clamped = min(max(value, 1), maxCount)
            controller.setInstanceCount(clamped)
            persist()
            rebuildMenu()
        }
    }

    @objc func toggleAutoStartAction(_ sender: Any?) {
        let on = !AutoStart.isEnabled
        AutoStart.setEnabled(on)
        var s = controller.settings
        s.autoStart = on
        controller.settings = s
        persist()
        rebuildMenu()
    }

    @objc func aboutAction(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "爱弥斯桌宠 Aemeath Pet"
        alert.informativeText = """
        版本 \(version)

        「爱弥斯，拉贝尔学部的隧者适格者！不过，那都是生前的事了。现在的我，是电子幽灵哦~」

        行为设计参考: ameath (MIT) - gitee.com/lzy-buaa-jdi/ameath
        原作者: B站 -fugu-
        动画素材: 原项目提供（特别感谢 B站 @_BLZ_）
        Mac 版: 原生 Swift/AppKit，低内存、低耗电
        """
        alert.icon = Assets.appIcon
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }

    @objc func quitAction(_ sender: Any?) {
        persist()
        NSApp.terminate(nil)
    }

    private func persist() {
        Settings.state = controller.settings
    }
}

// ============================================================================
// 菜单构建
// ============================================================================

enum PetMenu {

    static func buildMenu() -> NSMenu {
        let app = PetApp.shared
        guard let c = app.controller else { return NSMenu() }
        let s = c.settings

        let menu = NSMenu()

        // 显示/隐藏
        let visibleItem = NSMenuItem(title: c.isVisible ? "隐藏宠物" : "显示宠物",
                                     action: #selector(PetApp.toggleVisibleAction), keyEquivalent: "")
        visibleItem.target = app
        menu.addItem(visibleItem)

        // 暂停/继续
        let pauseItem = NSMenuItem(title: c.isPaused ? "继续" : "暂停",
                                   action: #selector(PetApp.togglePauseAction), keyEquivalent: "")
        pauseItem.target = app
        menu.addItem(pauseItem)

        menu.addItem(.separator())

        // 跟随鼠标
        let followItem = NSMenuItem(title: "跟随鼠标", action: #selector(PetApp.toggleFollowAction), keyEquivalent: "")
        followItem.target = app
        followItem.state = s.followMouse ? .on : .off
        menu.addItem(followItem)

        // 鼠标穿透
        let clickItem = NSMenuItem(title: "鼠标穿透", action: #selector(PetApp.toggleClickThroughAction), keyEquivalent: "")
        clickItem.target = app
        clickItem.state = s.clickThrough ? .on : .off
        menu.addItem(clickItem)

        menu.addItem(.separator())

        // 缩放
        let scaleMenu = NSMenu()
        for (i, v) in Settings.scaleOptions.enumerated() {
            let item = NSMenuItem(title: String(format: "%.1fx", v),
                                  action: #selector(PetApp.setScaleAction), keyEquivalent: "")
            item.target = app
            item.tag = i
            item.state = i == s.scaleIndex ? .on : .off
            scaleMenu.addItem(item)
        }
        let scaleTitle = NSMenuItem(title: "缩放", action: nil, keyEquivalent: "")
        menu.setSubmenu(scaleMenu, for: scaleTitle)
        menu.addItem(scaleTitle)

        // 透明度
        let opacityMenu = NSMenu()
        for (i, v) in Settings.transparencyOptions.enumerated() {
            let item = NSMenuItem(title: "\(Int(v * 100))%",
                                  action: #selector(PetApp.setTransparencyAction), keyEquivalent: "")
            item.target = app
            item.tag = i
            item.state = i == s.transparencyIndex ? .on : .off
            opacityMenu.addItem(item)
        }
        let opacityTitle = NSMenuItem(title: "透明度", action: nil, keyEquivalent: "")
        menu.setSubmenu(opacityMenu, for: opacityTitle)
        menu.addItem(opacityTitle)

        // 移动帧率
        let rateMenu = NSMenu()
        for (i, hz) in Settings.tickRateOptions.enumerated() {
            let item = NSMenuItem(title: "\(hz)Hz",
                                  action: #selector(PetApp.setTickRateAction), keyEquivalent: "")
            item.target = app
            item.tag = i
            item.state = i == s.tickRateIndex ? .on : .off
            rateMenu.addItem(item)
        }
        let rateTitle = NSMenuItem(title: "移动帧率", action: nil, keyEquivalent: "")
        menu.setSubmenu(rateMenu, for: rateTitle)
        menu.addItem(rateTitle)

        // 显示层级
        let levelMenu = NSMenu()
        for level in Settings.DisplayLevel.allCases {
            let item = NSMenuItem(title: level.title,
                                  action: #selector(PetApp.setDisplayLevelAction), keyEquivalent: "")
            item.target = app
            item.tag = level.rawValue
            item.state = level == s.displayLevel ? .on : .off
            levelMenu.addItem(item)
        }
        let levelTitle = NSMenuItem(title: "显示层级", action: nil, keyEquivalent: "")
        menu.setSubmenu(levelMenu, for: levelTitle)
        menu.addItem(levelTitle)

        menu.addItem(.separator())

        // 多开模式
        let multiItem = NSMenuItem(title: "多开数量…（当前 \(c.instanceCount) 只）",
                                   action: #selector(PetApp.instanceCountAction), keyEquivalent: "")
        multiItem.target = app
        menu.addItem(multiItem)

        // 随机队形
        let formationItem = NSMenuItem(title: "随机队形（爱心/圆形/一排波浪/方阵…）",
                                       action: #selector(PetApp.toggleFormationAction), keyEquivalent: "")
        formationItem.target = app
        formationItem.state = c.settings.formationEnabled ? .on : .off
        menu.addItem(formationItem)

        // 队形频率
        let freqMenu = NSMenu()
        for (i, label) in Settings.formationFrequencyOptions.enumerated() {
            let item = NSMenuItem(title: label,
                                  action: #selector(PetApp.setFormationFrequencyAction), keyEquivalent: "")
            item.target = app
            item.tag = i
            item.state = i == c.settings.formationFrequencyIndex ? .on : .off
            freqMenu.addItem(item)
        }
        let freqTitle = NSMenuItem(title: "队形频率", action: nil, keyEquivalent: "")
        menu.setSubmenu(freqMenu, for: freqTitle)
        menu.addItem(freqTitle)

        menu.addItem(.separator())

        // 开机自启
        let autoItem = NSMenuItem(title: "开机自启", action: #selector(PetApp.toggleAutoStartAction), keyEquivalent: "")
        autoItem.target = app
        autoItem.state = AutoStart.isEnabled ? .on : .off
        menu.addItem(autoItem)

        menu.addItem(.separator())

        // 关于 / 退出
        let aboutItem = NSMenuItem(title: "关于 爱弥斯桌宠", action: #selector(PetApp.aboutAction), keyEquivalent: "")
        aboutItem.target = app
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "退出", action: #selector(PetApp.quitAction), keyEquivalent: "q")
        quitItem.target = app
        menu.addItem(quitItem)

        return menu
    }
}
