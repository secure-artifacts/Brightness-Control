import SwiftUI

@main
struct Brightness_ControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 初始化菜单栏图标和弹窗
        menuBar()
        // 刷新显示器亮度信息
        BrightnessManager.shared.refresh()
        // 开始拦截媒体按键（如亮度调节键）
        BrightnessKeyHandler.shared.start()
    }

    // 创建菜单栏
    private func menuBar() {
        // 初始化 NSPopover 弹窗
        let p = NSPopover()

        p.contentViewController = NSHostingController(rootView: MenuBarView())
        p.behavior = .transient

        popover = p

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // 配置状态栏按钮的图标和点击行为
        if let btn = statusItem?.button {
            // 设置菜单栏图标
            btn.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: nil)

            // 设置点击按钮时触发的方法
            btn.action = #selector(togglePopover)
            btn.target = self
        }
    }

    @objc private func togglePopover() {
        guard let btn = statusItem?.button, let p = popover else {
            return
        }
        if p.isShown {
            p.performClose(nil)
        } else {
            p.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
        }
    }
}
