# 开发说明

## 环境

- macOS 与 Swift 编译工具链，包含 macOS 26 SDK 或更新版本。源码使用新截图 API，并通过运行时检查提供旧系统兼容路径。
- 仅构建独立 App 无需 Node.js；MCP 服务及 Node 测试需要 Node.js 20+，无第三方 npm 依赖。
- 当前构建脚本按本机 CPU 架构生成二进制，不生成 Universal 2；公开 Release 为 arm64，Intel 构建尚未验证。

## 构建 App

```sh
git clone https://github.com/LinQingmo-w/screenshotForCodex.git
cd screenshotForCodex/screenshot-annotator
xcrun --find swiftc
xcrun --show-sdk-version
bash scripts/package-app.sh
```

输出为 `.build/screenshotForCodex.app`。将整个 App 复制到“应用程序”即可运行；包内包含原生菜单栏启动器、标注辅助 App 和许可，不依赖源码目录。

构建使用本地临时签名，未进行 Developer ID 签名或 Apple 公证。脚本只删除自身生成的 `.build/screenshotForCodex.app` 后重建，不安装 App、不修改系统权限。

## 验证

在 `screenshot-annotator/` 中执行：

```sh
npm test
bash scripts/test-native-policy.sh
bash scripts/test-overlay.sh
```

Node 测试使用临时会话；纯策略和合成界面测试不读取真实桌面，不操作真实 Codex 聊天。实际验收仍需手动截图，确认附件缩略图、已有草稿保留及剪贴板可粘贴。

## 可选：安装本地 MCP 插件

日常菜单栏和快捷键使用不需要 MCP。需要在聊天中调用工具时，在 `screenshot-annotator/` 中执行：

```sh
npm run build:native
npm run configure
cd ..
codex plugin marketplace add .
codex plugin add screenshot-annotator@codex-local-tools
codex mcp get screenshot-annotator --json
```

需要支持上述插件命令的 Codex CLI。按客户端提示刷新或重启，再新开聊天确认工具加载。仓库根目录的 `.agents/plugins/marketplace.json` 是本地市场入口，`source.path` 相对于仓库根目录。

`configure` 生成本机的 `mcp.json` 和启动脚本：MCP command 使用插件内的 `./scripts/launch-server.sh`，Node 和源码绝对路径只出现在生成的脚本内部。移动源码、换机器或更改 Node 路径后，重新 configure 并刷新安装。MCP 安装后需保留源码目录；不能把旧机器的生成配置或插件缓存直接搬到新设备。

工具包括 `start_screenshot`、`get_screenshot_status`、`read_screenshot`。读取截图供模型分析不等于向聊天输入框添加附件。`paste_requested` 只表示匹配的图片接收证据，不能替代 UI 缩略图验收。

## 代码结构

| 路径 | 用途 |
| --- | --- |
| `native/QuickStart.swift` | 原生菜单栏及全局快捷键 |
| `native/Annotator.swift` | 截图流程、导出与保护性粘贴 |
| `native/SelectionCanvas.swift`、`native/FloatingTools.swift` | 选区、可编辑标注与工具栏 |
| `native/ComposerPolicy.swift` | 输入框选择、短暂重试与草稿保护策略 |
| `server/` | 本地 stdio MCP 与兼容启动入口 |
| `tests/` | Node、策略及合成界面测试 |
| `scripts/` | 构建、打包、配置生成与测试入口 |

构建产物、本机生成配置和内部开发记录由 `.gitignore` 排除。提交前检查不要包含会话截图、个人路径或凭据。

## 制作发布包

在仓库根目录执行；先完成上述验证：

```sh
cd screenshot-annotator
bash scripts/package-app.sh
mkdir -p .build/release
ditto -c -k --sequesterRsrc --keepParent \
  .build/screenshotForCodex.app \
  .build/release/screenshotForCodex-0.7.6-macOS-arm64.zip
cd .build/release
shasum -a 256 screenshotForCodex-0.7.6-macOS-arm64.zip > SHA256SUMS.txt
```

将 App ZIP 和校验文件作为对应版本的 Release 资产，源码通过 GitHub 自动生成的源码归档提供。版本号变更时同步更新插件清单、package.json、两个原生 Info.plist、README 和发布文件名。
