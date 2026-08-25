import AppKit

/// 宠物动画状态（与 gifs 目录对应）
enum PetState: String, CaseIterable {
    case move, idle1, idle2, idle3, idle4, drag

    /// 帧所在子目录
    var dirName: String { rawValue }
}

/// 一段动画片段：帧图 + 每帧延时（秒）
struct AnimClip {
    let images: [NSImage]
    let delays: [Double]
    let totalDuration: Double

    var frameCount: Int { images.count }

    static let empty = AnimClip(images: [], delays: [], totalDuration: 0)
}

/// 资源加载器：从应用 Bundle 的 Resources 读取帧与图标
enum Assets {
    static private(set) var clips: [PetState: AnimClip] = [:]
    static private(set) var menuBarIcon: NSImage?
    static private(set) var appIcon: NSImage?

    /// 原始帧（GIF 原帧，锐利无插值）
    private static var baseClips: [PetState: AnimClip] = [:]

    /// 加载全部资源（应在启动时调用一次）
    static func load() {
        loadFrames()
        loadIcons()
        clips = baseClips
    }

    private static func loadFrames() {
        let bundle = Bundle.main
        // 帧清单（构建期由 Scripts/extract_frames.py 生成）
        guard let manifestURL = bundle.url(forResource: "manifest", withExtension: "json"),
              let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let states = json["states"] as? [String: Any] else {
            print("[Aemeath] 无法加载 manifest.json")
            return
        }

        for state in PetState.allCases {
            guard let entry = states[state.rawValue] as? [String: Any],
                  let names = entry["frames"] as? [String],
                  let delayList = entry["delays"] as? [Int] else { continue }

            var images: [NSImage] = []
            images.reserveCapacity(names.count)
            var delays: [Double] = []
            for (i, name) in names.enumerated() {
                // manifest 中存的是带扩展名的完整文件名（如 frame_000.png）
                guard let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "frames/\(state.dirName)"),
                      let img = NSImage(contentsOf: url) else { continue }
                images.append(img)
                let d = i < delayList.count ? Double(delayList[i]) / 1000.0 : 0.11
                delays.append(d)
            }
            guard !images.isEmpty else { continue }
            baseClips[state] = AnimClip(images: images, delays: delays, totalDuration: delays.reduce(0, +))
        }
    }

    private static func loadIcons() {
        let bundle = Bundle.main
        // 菜单栏图标：16pt，含 @1x/@2x/@3x 表示
        let icon = NSImage(size: NSSize(width: 18, height: 18))
        for (name, px) in [("menubar_16", 16), ("menubar_32", 32), ("menubar_48", 48)] {
            if let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "icon"),
               let rep = NSImageRep(contentsOf: url) {
                rep.size = NSSize(width: px == 16 ? 18 : 18, height: 18)
                icon.addRepresentation(rep)
            }
        }
        menuBarIcon = icon

        if let url = bundle.url(forResource: "app_icon_1024", withExtension: "png", subdirectory: "icon") {
            appIcon = NSImage(contentsOf: url)
        }
    }
}

extension NSImage {
    /// 转成 CGImage（供 CALayer.contents 使用）
    var cgImageValue: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
