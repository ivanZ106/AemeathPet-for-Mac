import Foundation

// ============================================================================
// 开机自启：LaunchAgent（无需特殊权限，路径变更后自动重建）
// 注意：只写/删 plist 文件，不调用 launchctl bootstrap——
//   bootstrap + RunAtLoad 会立即拉起第二个应用实例（多一只宠物）；
//   写入的 plist 会在下次登录时由 launchd 自动加载，实现开机自启。
// ============================================================================

enum AutoStart {

    static let label = "com.aemeath.pet"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ on: Bool) {
        if on {
            guard let exe = Bundle.main.executableURL?.path else { return }
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "ProcessType": "Interactive",
                "KeepAlive": false,
            ]
            do {
                let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                              format: .xml,
                                                              options: 0)
                try data.write(to: plistURL)
            } catch {
                NSLog("[Aemeath] 写入 LaunchAgent 失败: \(error)")
            }
        } else {
            try? FileManager.default.removeItem(at: plistURL)
        }
    }
}
