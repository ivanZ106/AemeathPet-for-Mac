import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        PetApp.shared.setup()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 持久化当前设置
        if PetApp.shared.controller != nil {
            Settings.state = PetApp.shared.controller.settings
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
