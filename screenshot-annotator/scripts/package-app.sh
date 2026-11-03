#!/bin/bash
set -euo pipefail
# 独立菜单栏应用原生启动，不再携带或启动 Node；MCP 仍使用源码服务。
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/.build/screenshotForCodex.app"
bash "$PROJECT_DIR/scripts/build-native.sh"
# 仅清理本脚本生成的安装包，避免把旧版运行时继续带进新版。
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/Helpers"
cp "$PROJECT_DIR/.build/Screenshot Quick Start.app/Contents/MacOS/ScreenshotQuickStart" "$APP_DIR/Contents/MacOS/"
cp "$PROJECT_DIR/native/QuickStartInfo.plist" "$APP_DIR/Contents/Info.plist"
ditto "$PROJECT_DIR/.build/Screenshot Annotator.app" "$APP_DIR/Contents/Resources/Helpers/screenshotForCodex.app"
cp "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$APP_DIR/Contents/Resources/"
# 独立下载包同时携带项目许可与参考代码原始许可。
cp "$PROJECT_DIR/../LICENSE" "$APP_DIR/Contents/Resources/LICENSE"
codesign --force --sign - --identifier local.codex.screenshot-quick-start \
  --requirements '=designated => identifier "local.codex.screenshot-quick-start"' "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
echo "原生独立应用已打包：$APP_DIR"
