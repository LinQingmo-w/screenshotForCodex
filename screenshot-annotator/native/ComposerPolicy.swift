import Foundation

/// 输入框的最小结构信息；策略测试不读取或操作真实 App。
struct ComposerCandidate {
    /// AX 角色、可访问提示，以及完成时是否已聚焦。
    let role: String
    let hint: String
    let focused: Bool
    /// 只有可设置文字选区的输入框才能安全保留草稿。
    let writableRange: Bool
}

/// 从可访问提示或用户明确聚焦的输入框选择唯一目标，绝不按屏幕坐标猜测。
enum ComposerPolicy {
    /// 快捷启动允许使用用户预先聚焦的 textarea；普通 MCP 入口仍要求聊天提示匹配。
    static func select(_ candidates: [ComposerCandidate], allowFocused: Bool) -> Int? {
        let textAreas = candidates.indices.filter { candidates[$0].role == "AXTextArea" }
        let focused = textAreas.filter { candidates[$0].focused && candidates[$0].writableRange }
        if allowFocused && focused.count == 1 {
            let hint = candidates[focused[0]].hint.lowercased()
            if !["terminal", "code editor", "search", "终端", "搜索"].contains(where: { hint.contains($0) }) { return focused[0] }
        }
        let matches = textAreas.filter { index in
            let hint = candidates[index].hint.lowercased()
            return ["codex", "composer", "prompt-input", "message", "ask", "消息", "一起工作"].contains { hint.contains($0) }
        }
        let focusedMatches = matches.filter { candidates[$0].focused }
        if focusedMatches.count == 1 { return focusedMatches[0] }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// 粘贴前验证草稿、折叠选区和实际 PNG 内容；剪贴板管理器重写同图不应误报。
enum PastePolicy {
    static func rejection(original: String, current: String, selection: NSRange, expectedPNG: Data, clipboardPNG: Data?) -> String? {
        if original != current { return "草稿在准备粘贴时发生变化，未执行粘贴。" }
        if selection.length != 0 || selection.location < 0 || selection.location > current.utf16.count {
            return "输入框仍有文字选区或光标位置无效，未执行粘贴。"
        }
        if clipboardPNG != expectedPNG { return "剪贴板中的图片已变化，未执行粘贴。标注图仍保存在本地。" }
        return nil
    }
}

/// 仅标记输入框尚未出现在 AX 树中的可重试失败，不包含权限或粘贴错误。
struct ComposerNotFound: LocalizedError {
    /// 最后一次扫描得到的诊断信息，不包含聊天内容。
    let message: String
    var errorDescription: String? { message }
}

/// 等待客户端控件树短暂恢复；只重试查找，成功后只回调一次。
enum ComposerLookup {
    /// 先准备控件树一次，再每隔 0.5 秒最多重试六次，覆盖 Chromium 两秒防抖；调度器可用于无桌面测试。
    static func resolve<T>(prepare: () -> Void = {},
                           lookup: @escaping () throws -> T,
                           schedule: @escaping (@escaping () -> Void) -> Void = { work in
                               DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                           },
                           completion: @escaping (Result<T, Error>) -> Void) {
        /// 每次重新读取当前窗口，耗尽次数或遇到非查找错误即结束。
        func attempt(_ remainingRetries: Int) {
            do {
                completion(.success(try lookup()))
            } catch is ComposerNotFound where remainingRetries > 0 {
                schedule { attempt(remainingRetries - 1) }
            } catch {
                completion(.failure(error))
            }
        }
        prepare()
        attempt(6)
    }
}
