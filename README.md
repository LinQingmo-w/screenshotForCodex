# screenshotForCodex

为 Codex 准备的 macOS 截图标注工具。按 **⌘⇧6** 截图，画框、写字或涂抹马赛克，点 **✓** 后自动返回 Codex 并尝试附图，同时保留剪贴板图片。

[下载最新版](https://github.com/LinQingmo-w/screenshotForCodex/releases/latest) · [提交问题](https://github.com/LinQingmo-w/screenshotForCodex/issues) · [开发说明](screenshot-annotator/docs/DEVELOPMENT.md)

## 功能

- **随处截图**：菜单栏或全局快捷键启动，无需先聚焦 Codex。
- **调整范围**：选区外变暗，可移动选区、拖动边缘和手柄调整大小。
- **截图标注**：矩形、圆形、直线、箭头、画笔、马赛克、文字。
- **继续编辑**：选中已有标注后移动、缩放、改色或删除；双击文字重新编辑，支持中文输入法。
- **固定配色与尺寸**：六种常用颜色，默认红色；画笔三档粗细、文字四档字号。马赛克使用独立的宽笔刷。
- **快捷完成**：✓ 或回车完成，Esc 取消，⌘Z 撤销；输入文字时，回车先确认文字。
- **附图并保留剪贴板**：完成后尝试附到 Codex 当前最前面的聊天，保留已有草稿，不自动发送。图片也可以粘贴到其他应用。
- **中文权限检查**：菜单栏查看辅助功能和屏幕录制权限状态。

这是独立的社区工具，与 OpenAI 无隶属关系，不是 Codex 官方功能。日常使用不需要安装 MCP 插件，也不需要 Node.js、API key 或云端服务。

## 下载与安装

1. 前往 [Releases](https://github.com/LinQingmo-w/screenshotForCodex/releases/latest)，下载 `screenshotForCodex-0.7.4-macOS-arm64.zip`。GitHub 自动提供的 `Source code` 是源码，不是可直接运行的 App。
2. 解压，将完整的 **screenshotForCodex.app** 拖入“应用程序”。
3. 双击打开。应用常驻菜单栏，没有普通主窗口。
4. 点击菜单栏图标 → **检查权限**，按提示开启辅助功能与屏幕录制权限；首次授权后重新打开应用。

**当前下载包适用于 Apple Silicon（M 系列芯片）的 Mac，不支持 Intel Mac。** 构建的最低系统版本是 macOS 12.3，目前主要在 macOS 26 上验证，尚未逐一验证旧系统与所有 Codex 版本。

当前 App 使用本地临时签名，**未经过 Apple 公证**。下载后可能受到 macOS 安全检查限制；仅在确认来源可信时，按系统提示或 [Apple 的应用安全说明](https://support.apple.com/zh-cn/102445) 处理。

## 开始使用

1. 在 Codex 打开要接收图片的聊天，然后可以切到其他应用。
2. 按 **⌘⇧6**，或点击菜单栏图标 → **开始截图**。
3. 拖动选择截图范围，再选择下方工具标注。截图位于启动时鼠标所在的屏幕。
4. 点击绿色 **✓** 或按回车，回到 Codex 确认输入框出现图片缩略图，再自行发送。

| 操作 | 用法 |
| --- | --- |
| 开始截图 | ⌘⇧6，或菜单栏“开始截图” |
| 调整范围 | 范围工具；拖动选区边缘、手柄或内部 |
| 编辑标注 | 单击选中，拖动移动或缩放；Delete 删除 |
| 修改文字 | 双击已有文字；输入时回车确认，Esc 放弃本次编辑 |
| 撤销 | ⌘Z；纯粗细调整不单独占用撤销记录 |
| 完成 / 取消 | ✓ 或回车 / × 或 Esc |
| 手动粘贴图片 | 在目标输入框按 ⌘V |

退出 Codex 不会退出截图工具。当前没有登录自启；退出工具或重启 Mac 后，请从“应用程序”重新打开。

## 权限与常见问题

### 权限应该授予哪个应用？

在“系统设置 → 隐私与安全性”中开启**辅助功能**和**屏幕录制**（部分系统称“屏幕与系统音频录制”）。实际执行截图和粘贴的是包内同名辅助 App：

```text
/Applications/screenshotForCodex.app/Contents/Resources/Helpers/screenshotForCodex.app
```

需要手动添加时，在文件选择框按 **⌘⇧G** 输入该路径。每台 Mac 都需要重新授权。系统仍可能另行询问是否允许绕过窗口选择器访问屏幕；工具本身没有录音功能。

### 图片没有自动进入聊天框？

自动附图依赖 Codex 暴露给 macOS 的辅助功能控件，客户端更新或页面加载可能影响识别。工具找不到输入框时会每隔 0.5 秒重试，最多额外重试 3 次；仍失败则提示，并保留剪贴板图片。

点一下目标聊天输入框，按 **⌘V** 即可手动粘贴，无需重新截图。若持续失败，可以完全退出再打开 Codex 后重试，并在 [Issues](https://github.com/LinQingmo-w/screenshotForCodex/issues) 提供 macOS、Codex、工具版本和错误提示；请勿附上私人聊天内容。

自动附图只尝试粘贴，不自动发送，也不是官方附件上传接口。以目标聊天输入框实际出现缩略图为成功标准。

### 快捷键无效？

确认工具正在菜单栏运行。若 ⌘⇧6 与其他截图应用冲突，可退出占用相同快捷键的工具，或使用菜单栏“开始截图”。

## 数据保存

截图和标注在本机处理。工具不会主动上传图片、录音或联网分析；你在 Codex 中发送图片后，按 Codex 自身的数据处理规则处理。

最终标注图片保存在下方目录，可自行清理。原始临时截图在完成或取消后删除；完成时会替换剪贴板内容，不恢复之前的剪贴板。

```text
~/Library/Application Support/ScreenshotAnnotator/sessions/
```

## 开发与可选 MCP 插件

源码、构建步骤、测试和 Codex 本地 MCP 安装方法见 [开发说明](screenshot-annotator/docs/DEVELOPMENT.md)。普通下载用户可直接使用 Release 中的独立 App。

## 致谢与许可

本项目的窗口恢复、系统级粘贴和图片接收证据逻辑参考并改编自 **[Screen Voice Capture](https://github.com/evstki/codex-screenshot-to-prompt-dictation)**。感谢原项目作者与贡献者；本项目没有引入语音听写功能。

项目采用 [MIT License](LICENSE)。参考代码的原始版权与许可保留在 [THIRD_PARTY_NOTICES.md](screenshot-annotator/THIRD_PARTY_NOTICES.md)。
