# 爱弥斯桌宠 · Aemeath Pet (macOS)

*"爱弥斯，拉贝尔学部的隧者适格者！不过，那都是生前的事了。现在的我，是电子幽灵哦~"*

一款适配 **macOS** 的爱弥斯桌面宠物，移植自 [gitee.com/lzy-buaa-jdi/ameath](https://gitee.com/lzy-buaa-jdi/ameath)（Windows / Python 版）。
使用 **原生 Swift + AppKit** 实现：**低内存占用（≈15MB）、低耗电**（自适应定时器 + 按帧调度 + 休眠暂停）。

<p align="center">
  <img src="assets/pet_states.gif" alt="爱弥斯桌宠 - 移动/待机/拖动 动画状态" width="85%">
</p>

## ✨ 特性

- 🐾 **状态机智能运动** — 游荡 / 跟随 / 好奇 / 休息 / 待机，模拟真实宠物行为
- 🖱️ **鼠标跟随** — 远距离主动跟随，近距离好奇观察（可开关）
- 💤 **随机休息** — 到达目标后随机停下休息，随机播放待机动画
- 🌀 **惯性移动** — 惯性 + 意图 + 随机抖动，轨迹流畅不生硬
- ⚡ **移动帧率可调** — 20 / 30 / 45 / 60 / 90 / 120Hz 六档（默认 60Hz），菜单一键切换
- 🎭 **多态动画** — 移动 / 待机(idle1~4) / 拖动 六组动画，移动方向自动翻转
- 🚶 **走出屏幕** — 撞边后概率走出屏幕，从对侧重新进入
- 📏 **9 档缩放** — 0.3x ~ 1.9x，缩放不重新解码帧（零额外内存）
- 👻 **8 档透明度** — 30% ~ 100%
- 👆 **鼠标穿透** — 默认关闭，可直接用鼠标拖动宠物（与原版一致）；需要时可一键开启
- 🖥️ **显示层级** — 置顶 / 普通 / 桌面 三档
- 🔄 **开机自启** — LaunchAgent 方式（无权限弹窗，路径变更自动重建）
- 🧭 **菜单栏控制** — 状态栏图标 + 完整菜单（隐藏/暂停/跟随/穿透/缩放/透明度/层级/多开/自启/退出）
- 👥 **多开模式** — 同时养多只爱弥斯，各自独立随机行动；上限 100 只（内存×30% ÷ 每只 2MB 与 100 取小，省电又够用）
- ❤️ **随机队形** — 关闭鼠标跟随后，多只宠物定时随机排成队形：**爱心 / 圆形 / 一排 / 一列 / 方阵 / 菱形 / 螺旋 / 列队行进**；所有队形期间都有**同步动作**（爱心=心跳搏动、圆形/菱形/螺旋=整体旋转、一排/一列=波浪、方阵=棋盘交替起伏）；**列队行进**排成一队沿随机路线游走全屏（横向蛇形/纵向蛇形/大波浪/圆形巡回/8字巡回 5 种路线）；保持一段时间后解散自由活动
- ⏱️ **队形频率可调** — 菜单可选慢/正常/快/很快四档切换节奏；跟随模式下自动排成**心形**围绕鼠标
- 🖱️ **右键菜单** — 非穿透模式下右键宠物直接弹出菜单
- 🪟 **跨空间置顶** — 全屏应用上也保持可见（可切换层级）
- 🎯 **Retina 适配** — 高分屏清晰显示

## 🍃 低内存 · 低耗电设计

| 手段 | 说明 |
| --- | --- |
| 帧资源 | 200×200 RGBA 帧，共 71 帧 ≈ 3MB（GIF 原帧，锐利无插值）；运行时物理占用 ≈ 15MB |
| 显示同步驱动 | CVDisplayLink 随显示器刷新精确驱动（不受后台 App 定时器合并影响）；完全静止时自动降频 2Hz 巡检，显示器休眠自动停止 |
| 画布架构 | 窗口固定为透明画布，宠物图层在画布内移动——避免移动窗口导致内容更新被丢弃（动画永不跳动） |
| 多开共享 | 多只宠物共享同一画布窗口与帧资源：实测 20 只仅 13.4MB（每只增量 <1MB），远轻于原版 60MB/只 |
| 移动积分 | 20~120Hz 可调（默认 60Hz，上限为显示刷新率）；px/s 物理积分，与帧率无关 |
| 无 60fps 渲染 | 只有帧变化才更新图层内容（CALayer.contents 引用替换），位置变化 ≥0.5pt 才移动窗口 |
| 跟随省电 | 仅开启「跟随鼠标」时才轮询鼠标位置 |
| 休眠暂停 | 屏幕休眠 / 会话锁定时停止全部定时器，唤醒后恢复 |
| 原生实现 | 无 WebView / 无运行时（Python/Electron），swiftc -Osize 编译，二进制 ≈ 300KB |

实测（Apple Silicon, macOS 15）：
- 自检：60 秒游荡模拟（120Hz 驱动），动画帧推进 4.5 万次；探针实测帧间隔均匀（9.1fps，掉拍 0 次）
- 帧率档位自检：20/30/45/60/90/120Hz 全部精确命中（间隔 = 1/Hz）
- `sample` 采样：主线程 92% 时间处于 `mach_msg2_trap` 空闲等待
- 物理内存 `phys_footprint` ≈ 13.5MB

## 📦 运行

```bash
# 直接运行（已构建产物）
open build/AemeathPet.app

# 或把 build/AemeathPet.app 拖入「应用程序」后打开
```

**控制方式**：点击菜单栏的 🐱 图标弹出菜单；**直接用鼠标拖动宠物**（鼠标穿透默认关闭），右键宠物也可弹菜单。

## 🔨 构建（需 Xcode 命令行工具）

```bash
./Scripts/build.sh          # 产物: build/AemeathPet.app
# 资源提取（首次自动执行）: python3 Scripts/extract_frames.py
```

## 🧪 自检

```bash
./build/AemeathPet.app/Contents/MacOS/AemeathPet --selftest
```

无窗口运行 8.5 万 tick 状态机模拟，输出调度分布、动画帧推进、内存占用。

## 📁 项目结构

```
Aemeath_Pet/
├── Sources/            # Swift 源码
│   ├── main.swift          # 入口（--selftest 支持）
│   ├── AppDelegate.swift
│   ├── Config.swift        # 配置档位 + UserDefaults
│   ├── Assets.swift        # 帧/图标加载
│   ├── PetBrain.swift      # 行为状态机（纯逻辑，可测试）
│   ├── PetController.swift # 透明窗口 + 自适应定时器 + 拖动
│   ├── StatusMenu.swift    # 菜单栏 + 菜单
│   ├── AutoStart.swift     # 开机自启 (LaunchAgent)
│   └── SelfTest.swift      # 自检
├── Resources/          # 构建期提取的帧与图标（manifest.json）
├── assets/             # 原始 GIF 素材
├── reference/          # 原版 Python 源码（学习参考）
├── Scripts/
│   ├── extract_frames.py   # GIF → PNG 帧 + 图标 + 清单
│   └── build.sh            # 编译 + 打包 .app
└── build/AemeathPet.app    # 构建产物
```

## ⚙️ 配置

- 设置存于 `UserDefaults`（`defaults read com.aemeath.pet`）
- 宠物位置自动记忆，下次启动恢复（超出屏幕自动钳回）
- 开机自启 = `~/Library/LaunchAgents/com.aemeath.pet.plist`

## 🔄 与原版的差异

| 原版 (Windows) | 本版 (macOS) |
| --- | --- |
| Python + Tkinter + Pillow + pystray | 原生 Swift + AppKit（无任何运行时依赖） |
| 系统托盘 (pystray) | 菜单栏 NSStatusItem |
| 注册表开机自启 | LaunchAgent（无权限弹窗） |
| 窗口贴靠特定程序 (win32gui) | 未移植（需辅助功能权限，暂不支持） |
| 语音 / 音乐播放 | 未移植（保持轻量，低内存优先） |
| 多宠物实例 | 单宠物（如需多只可后续扩展） |

## 📜 许可与致谢

- 行为设计参考 [ameath (MIT)](https://gitee.com/lzy-buaa-jdi/ameath)，原作者为 B站 [-fugu-](https://search.bilibili.com/all?keyword=-fugu-)；动画素材由原项目提供，特别感谢 B站 [@_BLZ_](https://b23.tv/LOWldqI)
- 本仓库代码遵循 MIT License，详见 [LICENSE](LICENSE)

---

*但愿爱弥斯能陪你在 Mac 上度过每一个安静的时刻。*
