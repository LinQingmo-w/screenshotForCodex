import Foundation

/// 标注进程自身的权限快照；菜单栏启动器不能代替标注 App 查询授权。
struct PermissionStatus {
    /// 自动回到 Codex 并粘贴所需的辅助功能权限。
    let accessibility: Bool
    /// 系统选区截图所需的屏幕录制权限。
    let screenRecording: Bool

    /// 所有操作提示保持中文，不把检测当作已授予权限。
    var message: String {
        let accessibilityText = accessibility ? "已开启" : "未开启"
        let recordingText = screenRecording ? "已开启" : "未开启"
        let guidance = accessibility && screenRecording
            ? "基础权限已开启。截图时 macOS 仍可能要求再次确认，请按系统提示操作。"
            : "请在对应设置中允许 screenshotForCodex。授权后重新点击“检查权限”；系统如要求退出重开，请按提示操作。"
        return "辅助功能：\(accessibilityText)\n屏幕录制：\(recordingText)\n\n\(guidance)"
    }
}
