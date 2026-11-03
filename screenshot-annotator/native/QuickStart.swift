import AppKit
import Carbon

/// 轻量菜单栏入口；只在用户点击或按快捷键时启动一次截图，不开网络端口。
final class QuickStart: NSObject, NSApplicationDelegate {
    /// 保留菜单栏项目、全局快捷键及单次启动进程的生命周期。
    var item: NSStatusItem?
    var hotKey: EventHotKeyRef?
    var handler: EventHandlerRef?
    /// 只序列化原生启动请求，会话锁负责阻止重复截图。
    var launching = false

    /// 独立安装版随包携带标注 App；开发入口仍兼容源码目录结构。
    var bundledHelper: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Helpers/screenshotForCodex.app"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// 启动时只注册菜单及快捷键，绝不自动截图或读取 Codex 界面。
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 从构建产物所在的 .build/ 返回源码目录，入口脚本由 configure 生成。
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item?.button?.image = NSImage(systemSymbolName: "crop", accessibilityDescription: "截图标注")
        item?.button?.toolTip = "截图标注 · ⌘⇧6 · 完成后回到 Codex 附图"
        let menu = NSMenu()
        menu.addItem(withTitle: "开始截图（⌘⇧6）", action: #selector(startCapture), keyEquivalent: "").target = self
        let hint = NSMenuItem(title: "可在其他应用截图，完成后回到 Codex 附图", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        menu.addItem(withTitle: "检查权限", action: #selector(checkPermissions), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 screenshotForCodex", action: #selector(quit), keyEquivalent: "").target = self
        item?.menu = menu
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data = data else { return OSStatus(eventNotHandledErr) }
            Unmanaged<QuickStart>.fromOpaque(data).takeUnretainedValue().startCapture()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { showError("快捷键监听注册失败，仍可使用菜单栏入口。"); return }
        let key = EventHotKeyID(signature: OSType(0x53414E4F), id: 1)
        let registration = RegisterEventHotKey(UInt32(kVK_ANSI_6), UInt32(cmdKey | shiftKey), key, GetApplicationEventTarget(), 0, &hotKey)
        if registration != noErr { showError("⌘⇧6 已被其他程序占用或无法注册，请使用菜单栏“开始截图”。") }
    }

    /// 直接通过原生 Launch Services 启动标注，不经过 Node、shell 或 open 子进程。
    @objc func startCapture() {
        guard !launching else { return }
        let root = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let helper = bundledHelper ?? root.appendingPathComponent(".build/Screenshot Annotator.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--start-session", "--focused-composer", "--request-uptime", String(ProcessInfo.processInfo.systemUptime)]
        launching = true
        NSWorkspace.shared.openApplication(at: helper, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                self?.launching = false
                if let error = error { self?.showError("截图启动失败：\(error.localizedDescription)") }
            }
        }
    }

    /// 在实际执行截图和粘贴的标注 App 内检查权限，避免误显示启动器的授权状态。
    @objc func checkPermissions() {
        let root = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", (bundledHelper ?? root.appendingPathComponent(".build/Screenshot Annotator.app")).path,
                          "--args", "--check-permissions"]
        do { try task.run() }
        catch { showError("无法打开权限检查：\(error.localizedDescription)") }
    }

    /// 显示启动错误，不自行切换到其他聊天或模拟输入。
    func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "screenshotForCodex"
        alert.informativeText = message
        alert.runModal()
    }

    /// 用户可随时退出，退出后释放快捷键，无开机自启或后台守护。
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey = hotKey { UnregisterEventHotKey(hotKey) }
        if let handler = handler { RemoveEventHandler(handler) }
    }
}

let app = NSApplication.shared
let delegate = QuickStart()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
