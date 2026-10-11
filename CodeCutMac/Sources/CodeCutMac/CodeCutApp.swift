import AppKit
import SwiftUI

@main
@MainActor
final class CodeCutApp: NSObject, NSApplicationDelegate {
    private let model = EditorModel()
    private var mainWindow: NSWindow!

    static func main() {
        let app = NSApplication.shared
        let delegate = CodeCutApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = CommandLine.arguments.contains("--music-reference") ? "CodeCut · 音乐参考库 2" : "CodeCut"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView().environment(model)
            .frame(minWidth: 1180, maxWidth: .infinity, minHeight: 720, maxHeight: .infinity, alignment: .topLeading))
        window.center()
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
        NSApp.activate(ignoringOtherApps: true)
        if !CommandLine.arguments.contains("--music-reference"), let path = UserDefaults.standard.string(forKey: "recentProject"), FileManager.default.fileExists(atPath: path) {
            Task { do { try await model.openProject(URL(fileURLWithPath: path)) } catch { model.taskState = .failed("恢复最近项目失败：\(error.localizedDescription)") } }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if model.videoURL != nil || model.projectURL != nil { try? model.save() }
        // 本地视觉模型是我们拉起来的子进程，退出时顺手收掉，避免留下后台服务。
        LocalVLM.stopOwnedServer()
    }

    /// 没有菜单栏的 macOS App 既没有 ⌘Q，也藏起了新建/打开项目的入口。
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 CodeCut", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 CodeCut", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 CodeCut", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "新建项目…", action: #selector(newProject(_:)), keyEquivalent: "n").target = self
        fileMenu.addItem(withTitle: "打开项目…", action: #selector(openProject(_:)), keyEquivalent: "o").target = self
        fileMenu.addItem(withTitle: "导入素材到当前项目…", action: #selector(importVideo(_:)), keyEquivalent: "i").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func newProject(_ sender: Any?) { model.promptNewProject() }
    @objc private func openProject(_ sender: Any?) { model.promptOpenProject() }
    @objc private func importVideo(_ sender: Any?) { model.promptImportVideo() }
}
