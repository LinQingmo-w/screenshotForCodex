#!/bin/bash
set -euo pipefail
# 仅在明确运行此构建脚本时编译；MCP 启动和协议测试不会触发编译。
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/.build/Screenshot Annotator.app"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$PROJECT_DIR/.build/ModuleCache"
/usr/bin/swiftc -swift-version 5 -target "$(uname -m)-apple-macos12.3" -O -module-cache-path "$PROJECT_DIR/.build/ModuleCache" -framework AppKit -framework ApplicationServices -framework ScreenCaptureKit \
  "$PROJECT_DIR/native/NativeSessionStore.swift" "$PROJECT_DIR/native/AttachmentObservation.swift" "$PROJECT_DIR/native/PermissionStatus.swift" "$PROJECT_DIR/native/SelectionGeometry.swift" "$PROJECT_DIR/native/ComposerPolicy.swift" "$PROJECT_DIR/native/MarkGeometry.swift" "$PROJECT_DIR/native/SelectionCanvas.swift" "$PROJECT_DIR/native/FloatingTools.swift" "$PROJECT_DIR/native/Annotator.swift" -o "$APP_DIR/Contents/MacOS/ScreenshotAnnotator"
cp "$PROJECT_DIR/native/Info.plist" "$APP_DIR/Contents/Info.plist"
/usr/bin/codesign --force --sign - --identifier local.codex.screenshot-annotator --requirements '=designated => identifier "local.codex.screenshot-annotator"' "$APP_DIR"
echo "已构建：$APP_DIR"
QUICK_APP="$PROJECT_DIR/.build/Screenshot Quick Start.app"
mkdir -p "$QUICK_APP/Contents/MacOS"
/usr/bin/swiftc -swift-version 5 -target "$(uname -m)-apple-macos12.3" -O -module-cache-path "$PROJECT_DIR/.build/ModuleCache" -framework AppKit -framework Carbon \
  "$PROJECT_DIR/native/QuickStart.swift" -o "$QUICK_APP/Contents/MacOS/ScreenshotQuickStart"
cp "$PROJECT_DIR/native/QuickStartInfo.plist" "$QUICK_APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$QUICK_APP"
echo "已构建：$QUICK_APP"
