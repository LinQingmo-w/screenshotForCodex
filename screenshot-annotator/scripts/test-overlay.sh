#!/bin/bash
set -euo pipefail
# 仅使用合成图片和离屏视图，不读取真实桌面、不启动截图或粘贴。
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$PROJECT_DIR/.build/ModuleCache"
swiftc -D UI_TESTING -swift-version 5 -target "$(uname -m)-apple-macos12.3" -module-cache-path "$PROJECT_DIR/.build/ModuleCache" -framework AppKit -framework ApplicationServices -framework ScreenCaptureKit \
  "$PROJECT_DIR/native/NativeSessionStore.swift" "$PROJECT_DIR/native/AttachmentObservation.swift" "$PROJECT_DIR/native/PermissionStatus.swift" \
  "$PROJECT_DIR/native/ComposerPolicy.swift" "$PROJECT_DIR/native/SelectionGeometry.swift" \
  "$PROJECT_DIR/native/MarkGeometry.swift" "$PROJECT_DIR/native/SelectionCanvas.swift" "$PROJECT_DIR/native/FloatingTools.swift" \
  "$PROJECT_DIR/native/Annotator.swift" "$PROJECT_DIR/tests/OverlayTests.swift" -o "$PROJECT_DIR/.build/overlay-tests"
"$PROJECT_DIR/.build/overlay-tests"
