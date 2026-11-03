#!/bin/bash
set -euo pipefail
# 只运行纯策略断言，不创建 App、不读取桌面、不触发截图或粘贴。
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$PROJECT_DIR/.build/ModuleCache"
/usr/bin/swiftc -swift-version 5 -framework CoreGraphics -framework ImageIO -module-cache-path "$PROJECT_DIR/.build/ModuleCache" \
  "$PROJECT_DIR/native/AttachmentObservation.swift" "$PROJECT_DIR/native/PermissionStatus.swift" "$PROJECT_DIR/native/SelectionGeometry.swift" "$PROJECT_DIR/native/ComposerPolicy.swift" "$PROJECT_DIR/tests/ComposerPolicyTests.swift" \
  -o "$PROJECT_DIR/.build/policy-tests"
"$PROJECT_DIR/.build/policy-tests"
