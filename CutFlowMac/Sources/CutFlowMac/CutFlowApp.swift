import AppKit
import SwiftUI

@main
@MainActor
final class CutFlowApp: NSObject, NSApplicationDelegate {
    private let model = EditorModel()
    private var mainWindow: NSWindow!

    static func main() {
        let app = NSApplication.shared
        let delegate = CutFlowApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "CutFlow"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView().environment(model).frame(minWidth: 1180, minHeight: 720))
        window.center()
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
        NSApp.activate(ignoringOtherApps: true)
        if let path = UserDefaults.standard.string(forKey: "recentProject"), FileManager.default.fileExists(atPath: path) {
            Task { do { try await model.openProject(URL(fileURLWithPath: path)) } catch { model.taskState = .failed("恢复最近项目失败：\(error.localizedDescription)") } }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { if model.videoURL != nil { try? model.save() } }
}
