import AppKit
import ApplicationServices
import ScreenCaptureKit

/// 辅助功能属性读取失败时返回 nil；不强制假定其他 App 的控件结构。
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

/// 将辅助功能字符串属性统一转换为空字符串，便于比较身份信息。
func stringAttribute(_ element: AXUIElement, _ name: String) -> String {
    attribute(element, name) as? String ?? ""
}

/// 有界遍历 AX 控件，避免异常或超大页面无限扫描。
func descendants(_ element: AXUIElement) -> [AXUIElement] {
    var queue = [element]
    var cursor = 0
    while cursor < queue.count && cursor < 2500 {
        let children = attribute(queue[cursor], kAXChildrenAttribute) as? [AXUIElement] ?? []
        queue.append(contentsOf: children.prefix(max(0, 2500 - queue.count)))
        cursor += 1
    }
    return queue
}

/// 可写入状态文件和展示给用户的明确失败原因。
struct AnnotatorError: LocalizedError {
    /// 不含聊天正文的用户可读错误说明。
    let message: String
    var errorDescription: String? { message }
}

/// 会话只写入由 MCP 创建的 UUID 子目录，文件不随 Git 分发。
final class Session {
    /// 应用专属数据目录内的当前会话路径。
    let directory: URL

    /// 原生入口在相同专属目录分配会话，保留 MCP 路径和锁兼容性。
    convenience init() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ScreenshotAnnotator/sessions")
        let id = try NativeSessionStore.create(root: root)
        try self.init(arguments: ["ScreenshotAnnotator", "--session", id.uuidString, "--root", root.path])
    }

    /// 校验本机启动参数，不将任意路径当作有效会话。
    init(arguments: [String]) throws {
        guard (arguments.count == 5 || (arguments.count == 6 && arguments[5] == "--focused-composer")), arguments[1] == "--session", arguments[3] == "--root",
              let id = UUID(uuidString: arguments[2]) else {
            throw AnnotatorError(message: "请从插件启动，缺少有效的截图会话参数。")
        }
        let root = URL(fileURLWithPath: arguments[4], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ScreenshotAnnotator/sessions", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard root == expected else { throw AnnotatorError(message: "拒绝在应用专属会话目录以外写入截图。") }
        directory = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("status.json").path) else {
            throw AnnotatorError(message: "会话尚未由本地插件创建。")
        }
    }

    /// 原子替换状态，查询方不会读取到半个 JSON；图片成功导出后才提供路径。
    func update(_ state: String, _ message: String, image: URL? = nil) {
        var data: [String: String] = ["state": state, "message": message]
        if let image = image { data["image_path"] = image.path }
        do {
            try JSONSerialization.data(withJSONObject: data).write(to: directory.appendingPathComponent("status.json"), options: .atomic)
        } catch { fputs("无法写入截图会话状态。\n", stderr) }
    }
}

/// 点击完成时才选择 Codex 当前聊天输入框，不绑定截图开始时的窗口。
final class PasteTarget {
    /// 当前 Codex 进程，用 PID 防止切到另一个同名应用。
    let application: NSRunningApplication
    /// AX 应用、窗口、输入框引用，用于粘贴前再次校验。
    let appElement: AXUIElement
    let windowElement: AXUIElement
    let composer: AXUIElement

    /// 仅定位当前目标进程，供控件树准备与输入框查找共享相同的多实例规则。
    private static func currentApplication() throws -> NSRunningApplication {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        let frontmost = NSWorkspace.shared.frontmostApplication
        let application = running.first { $0.processIdentifier == frontmost?.processIdentifier }
            ?? (running.count == 1 ? running.first : nil)
        guard let application = application else {
            throw AnnotatorError(message: "请先打开目标 Codex 聊天；若运行了多个 Codex 实例，请先激活要附图的那个。")
        }
        return application
    }

    /// 按需请求 Chromium 完整控件树；每轮查找前只调用一次，避免重复请求重置两秒防抖。
    static func requestFullAccessibilityIfNeeded() {
        guard AXIsProcessTrusted(), let application = try? currentApplication() else { return }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 2)
        guard (attribute(app, "AXEnhancedUserInterface") as? Bool) != true else { return }
        // Chromium 先处理启用请求，再调用父类，因此可能返回 notImplemented 但实际已生效。
        // 不以 setter 返回码中止；后续以真实输入框是否出现判定。上游有两秒防抖。
        // https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/chrome_browser_application_mac.mm
        _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// 点击对勾时读取已运行 Codex 当前窗口和输入框；不读取截图前的聊天状态。
    init(allowFocused: Bool = false) throws {
        let application = try Self.currentApplication()
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            throw AnnotatorError(message: "尚未获得辅助功能权限。请在系统设置中允许 screenshotForCodex，然后重新截图。")
        }
        self.application = application
        appElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 2)
        let windows = attribute(appElement, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let preferred = attribute(appElement, kAXFocusedWindowAttribute)
            ?? attribute(appElement, kAXMainWindowAttribute)
            ?? (windows.count == 1 ? windows.first : nil)
        guard let rawWindow = preferred, CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else {
            throw AnnotatorError(message: "无法确定 Codex 的最近聊天窗口，请先打开要附图的聊天。")
        }
        windowElement = (rawWindow as! AXUIElement)
        var elements = descendants(windowElement)
        var focused: AXUIElement?
        if let rawFocus = attribute(appElement, kAXFocusedUIElementAttribute), CFGetTypeID(rawFocus) == AXUIElementGetTypeID() {
            let element = rawFocus as! AXUIElement
            // 当前焦点可能在长聊天的遍历上限之外，直接通过 AXWindow 验证归属。
            let inTree = elements.contains(where: { CFEqual($0, element) })
            var inWindow = false
            if let owner = attribute(element, kAXWindowAttribute) { inWindow = CFEqual(owner, windowElement) }
            if inTree || inWindow {
                focused = element
                if !elements.contains(where: { CFEqual($0, element) }) { elements.append(element) }
            }
        }
        let candidates = elements.map { element -> ComposerCandidate in
            let role = stringAttribute(element, kAXRoleAttribute)
            guard role == "AXTextArea" else { return ComposerCandidate(role: role, hint: "", focused: false, writableRange: false) }
            let hint = ["AXPlaceholderValue", kAXIdentifierAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXTitleAttribute]
                .map { stringAttribute(element, $0) }.joined(separator: " ")
            var settable = DarwinBoolean(false)
            let canSetRange = AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success && settable.boolValue
            return ComposerCandidate(role: role, hint: hint,
                                     focused: focused.map { CFEqual(element, $0) } ?? false, writableRange: canSetRange)
        }
        guard let selected = ComposerPolicy.select(candidates, allowFocused: allowFocused) else {
            let areas = candidates.filter { $0.role == "AXTextArea" }.count
            throw ComposerNotFound(message: "等待并重试后仍无法唯一识别聊天输入框（扫描 \(elements.count) 个控件，\(areas) 个文本区）。请先点 Codex 聊天输入框，再按 ⌘⇧6 重新截图。")
        }
        composer = elements[selected]
    }

    /// 只确认本次刚选中的目标还可用，不比较标题、聊天内容或截图前的控件。
    func ensureAvailable() throws {
        guard !application.isTerminated,
              stringAttribute(composer, kAXRoleAttribute) == "AXTextArea" else {
            throw AnnotatorError(message: "当前 Codex 输入框暂不可用，标注图仍在剪贴板，可手动按 ⌘V。")
        }
    }

    /// 同时兼容宿主公开的焦点对象和目标控件自身焦点状态；不要求 setter 返回成功。
    func composerHasFocus() -> Bool {
        if let focused = attribute(appElement, kAXFocusedUIElementAttribute), CFEqual(focused, composer) { return true }
        return (attribute(composer, kAXFocusedAttribute) as? Bool) == true
    }

    /// 激活当前窗口并单次粘贴；Bool 仅表示观察到匹配的 Codex 图片文件，不能证明 UI 已显示。
    func paste(imageData: Data, completion: @escaping (Result<Bool, Error>) -> Void) {
        do { try ensureAvailable() } catch { completion(.failure(error)); return }
        // 参考 Screen Voice Capture 的恢复顺序，跨应用截图时也能回到当前窗口。
        _ = application.unhide()
        _ = AXUIElementSetAttributeValue(windowElement, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        _ = AXUIElementSetAttributeValue(windowElement, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = application.activate(options: [.activateAllWindows])
        _ = AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString)
        restoreFocus(attempt: 0, imageData: imageData, completion: completion)
    }

    /// 等待窗口切换与 AX 焦点恢复；仅对已识别的当前输入框尝试一次实际点击。
    func restoreFocus(attempt: Int, imageData: Data, completion: @escaping (Result<Bool, Error>) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            do {
                try self.ensureAvailable()
                let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == self.application.processIdentifier
                let sameWindow = attribute(self.appElement, kAXFocusedWindowAttribute).map { CFEqual($0, self.windowElement) } ?? false
                if !frontmost || !sameWindow || !self.composerHasFocus() {
                    if attempt < 24 {
                        // AXFocused setter 可能不受支持，不能仅根据其返回码认定未聚焦。
                        if frontmost && sameWindow {
                            _ = AXUIElementSetAttributeValue(self.composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                            if [3, 8, 16].contains(attempt) { self.clickComposer() }
                        }
                        if attempt == 8 || attempt == 16 {
                            _ = self.application.activate(options: [.activateAllWindows])
                            _ = AXUIElementPerformAction(self.windowElement, kAXRaiseAction as CFString)
                        }
                        self.restoreFocus(attempt: attempt + 1, imageData: imageData, completion: completion)
                        return
                    }
                    if !frontmost { throw AnnotatorError(message: "当前 Codex 未成为前台应用，未执行粘贴。") }
                    if !sameWindow { throw AnnotatorError(message: "当前 Codex 窗口未获得焦点，未执行粘贴。") }
                    throw AnnotatorError(message: "当前聊天输入框未恢复焦点，等待后仍无法确认，未执行粘贴。")
                }
                self.pasteIntoFocusedComposer(imageData: imageData, completion: completion)
            } catch { completion(.failure(error)) }
        }
    }

    /// 仅点击当前输入框 AX 公布的可见区域；不猜窗口比例，也不点击其他窗口。
    func clickComposer() {
        guard let rawPosition = attribute(composer, kAXPositionAttribute),
              let rawSize = attribute(composer, kAXSizeAttribute),
              CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size),
              size.width > 4, size.height > 4 else { return }
        let point = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit = hit, CFEqual(hit, composer) || descendants(composer).contains(where: { CFEqual($0, hit) }) else { return }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// 检测新生成且像素匹配的 Codex 图片文件；超时不重复粘贴，避免产生重复附件。
    func observeAttachment(_ observation: AttachmentObservation, remaining: Int, completion: @escaping (Result<Bool, Error>) -> Void) {
        if observation.hasMatchingImage() { completion(.success(true)); return }
        guard remaining > 0 else {
            completion(.failure(AnnotatorError(message: "已尝试粘贴，但未检测到 Codex 接收这张标注图。图片仍在剪贴板，可切到目标窗口按 ⌘V；为避免重复附件，未自动重试。")))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.observeAttachment(observation, remaining: remaining - 1, completion: completion)
        }
    }

    /// 已确认当前窗口和当前输入框焦点后，折叠选区并检查实际剪贴板图片再发出粘贴。
    func pasteIntoFocusedComposer(imageData: Data, completion: @escaping (Result<Bool, Error>) -> Void) {
            do {
                // 像素解码在最终焦点/草稿校验之前完成，缩短校验到发出按键之间的窗口。
                let observation = AttachmentObservation(imageData: imageData)
                guard let text = attribute(composer, kAXValueAttribute) as? String else {
                    throw AnnotatorError(message: "当前输入框已聚焦，但无法读取草稿，未执行粘贴。")
                }
                // 折叠现有选区，防止用户原先选中的正文被图片替换。
                var range = CFRange(location: text.utf16.count, length: 0)
                if let selectedRange = AXValueCreate(.cfRange, &range) {
                    _ = AXUIElementSetAttributeValue(composer, kAXSelectedTextRangeAttribute as CFString, selectedRange)
                }
                var actualRange = CFRange(location: -1, length: -1)
                guard let rawRange = attribute(self.composer, kAXSelectedTextRangeAttribute),
                      CFGetTypeID(rawRange) == AXValueGetTypeID(),
                      AXValueGetValue(rawRange as! AXValue, .cfRange, &actualRange) else {
                    throw AnnotatorError(message: "无法读取输入框文字选区，未执行粘贴。")
                }
                if let reason = PastePolicy.rejection(original: text, current: stringAttribute(composer, kAXValueAttribute),
                    selection: NSRange(location: actualRange.location, length: actualRange.length), expectedPNG: imageData,
                    clipboardPNG: NSPasteboard.general.data(forType: .png)) {
                    throw AnnotatorError(message: reason)
                }
                guard composerHasFocus(), NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
                      attribute(appElement, kAXFocusedWindowAttribute).map({ CFEqual($0, windowElement) }) == true else {
                    throw AnnotatorError(message: "准备粘贴时当前输入框失去焦点，未执行粘贴。")
                }
                guard let source = CGEventSource(stateID: .hidSystemState),
                      let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
                    throw AnnotatorError(message: "无法创建粘贴快捷键。")
                }
                down.flags = .maskCommand
                up.flags = .maskCommand
                // 使用参考工具的系统 HID 通道；发出前已核对进程、窗口、焦点和草稿。
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                self.observeAttachment(observation, remaining: 30, completion: completion)
            } catch { completion(.failure(error)) }
    }
}

/// 标注类型保留稳定 rawValue；工具栏独立定义显示顺序。
enum Tool: Int { case rectangle, ellipse, arrow, pen, text, line, mosaic }

/// 标注坐标使用原图像素，不依赖窗口尺寸或 Retina 缩放比例。
struct Mark: Equatable {
    /// 在撤销时按对象身份保留最新粗细，避免对象增删后按索引错配。
    let id = UUID()
    var tool: Tool
    var points: [NSPoint]
    var color: NSColor
    var text: String
    /// 文字对象缩放倍数；非文字对象保持默认 1。
    var textScale: CGFloat = 1
    /// 标注线条的逻辑点宽度，导出时乘以 Retina 比例；默认中等 4pt。
    var strokeWidth: CGFloat = 4
}

/// 按原始像素绘制截图与矢量标注；窗口内缩放只影响显示。
class Canvas: NSView {
    /// 源图及原始像素尺寸，导出时保持一致。
    let image: NSImage
    let pixelSize: NSSize
    /// 当前工具、颜色与已提交/正在拖动的标注。
    var tool = Tool.rectangle
    var ink = NSColor.systemRed
    /// 新标注的粗细与字号；选中已有对象时同步，切换工具仍保留本次设置。
    var strokeWidth: CGFloat = 4
    var currentTextScale: CGFloat = 1
    var marks: [Mark] = []
    var pending: [NSPoint] = []
    /// 行内编辑时隐藏旧文字，避免新旧文字叠在一起；提交后恢复正常绘制。
    var suppressedMark: Int?
    /// 马赛克只缓存已提交对象；拖动预览不积累随机 ID 缓存。
    private var mosaicCache: [UUID: (CGRect, CGFloat, NSImage)] = [:]
    /// 只有首次使用马赛克才获取原始图像，避免把图像转换放在截图启动路径上。
    private lazy var mosaicSource: CGImage? = {
        var rect = CGRect(origin: .zero, size: pixelSize)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }()

    /// 从 PNG 像素信息初始化，避免 NSImage 的 DPI 改变导出尺寸。
    init(image: NSImage, pixelSize: NSSize) {
        self.image = image
        self.pixelSize = pixelSize
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("不使用 storyboard") }
    override var acceptsFirstResponder: Bool { true }

    /// 保持宽高比，四周留出可见边距，防止窗口缩放裁掉截图。
    var imageRect: NSRect {
        let scale = min(max(1, bounds.width - 24) / pixelSize.width, max(1, bounds.height - 24) / pixelSize.height)
        let size = NSSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        return NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// 鼠标位置映射到图像像素；拖出图片时将终点约束到边界。
    func point(_ event: NSEvent) -> NSPoint {
        let local = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        return NSPoint(x: min(pixelSize.width, max(0, (local.x - rect.minX) * pixelSize.width / rect.width)),
                       y: min(pixelSize.height, max(0, (local.y - rect.minY) * pixelSize.height / rect.height)))
    }

    /// 绘制屏幕预览；背景不包含在最终 PNG 中。
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let rect = imageRect
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scaleX(by: rect.width / pixelSize.width, yBy: rect.height / pixelSize.height)
        transform.concat()
        paint(includePending: true)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 子类可限定标注的可见区域（图像像素坐标）；原图仍完整显示，裁剪不会移动标注。
    var annotationClipRect: CGRect? { nil }

    /// 将截图和标注渲染到当前图形上下文，预览与导出共用同一绘制路径。
    func paint(includePending: Bool) {
        image.draw(in: NSRect(origin: .zero, size: pixelSize), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.saveGraphicsState()
        if let clip = annotationClipRect { NSBezierPath(rect: clip).addClip() }
        defer { NSGraphicsContext.restoreGraphicsState() }
        let visible = marks.enumerated().filter { $0.offset != suppressedMark }.map(\.element)
        let active = visible + (includePending && !pending.isEmpty ? [Mark(tool: tool, points: pending, color: ink, text: "", strokeWidth: strokeWidth)] : [])
        for mark in active { drawMark(mark) }
    }

    /// 使用像素坐标绘制形状，箭头方向支持任意拖动象限。
    func drawMark(_ mark: Mark) {
        guard let first = mark.points.first, let last = mark.points.last else { return }
        mark.color.setStroke()
        // 冻结全屏后不能按整屏宽度放大笔画或文字；按显示缩放保留对象的逻辑线宽与字号。
        let displayScale = max(1, pixelSize.width / max(1, bounds.width))
        let width = mark.strokeWidth * displayScale
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let rect = NSRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(first.x - last.x), height: abs(first.y - last.y))
        switch mark.tool {
        case .rectangle: path.appendRect(rect)
        case .ellipse: path.appendOval(in: rect)
        case .pen:
            path.move(to: first)
            for point in mark.points.dropFirst() { path.line(to: point) }
        case .line:
            path.move(to: first)
            path.line(to: last)
        case .mosaic:
            let brushWidth = AnnotationSizes.mosaicBrushWidth(mark.strokeWidth) * displayScale
            let region = MarkGeometry.bounds(mark, fontSize: 18 * displayScale).intersection(CGRect(origin: .zero, size: pixelSize))
            NSGraphicsContext.saveGraphicsState()
            let mask = CGMutablePath()
            if mark.points.count == 1 {
                mask.addEllipse(in: CGRect(x: first.x - brushWidth / 2, y: first.y - brushWidth / 2, width: brushWidth, height: brushWidth))
            } else {
                let centerline = CGMutablePath()
                centerline.addLines(between: mark.points)
                mask.addPath(centerline.copy(strokingWithWidth: brushWidth, lineCap: .round, lineJoin: .round, miterLimit: 10))
            }
            NSGraphicsContext.current?.cgContext.addPath(mask)
            NSGraphicsContext.current?.cgContext.clip()
            drawMosaic(mark, rect: region, blockSize: 6 * displayScale)
            NSGraphicsContext.restoreGraphicsState()
            return
        case .arrow:
            path.move(to: first)
            path.line(to: last)
            let angle = atan2(last.y - first.y, last.x - first.x)
            let length = max(14 * displayScale, width * 5)
            for offset in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                path.move(to: last)
                path.line(to: NSPoint(x: last.x - length * cos(angle + offset), y: last.y - length * sin(angle + offset)))
            }
        case .text:
            (mark.text as NSString).draw(at: first, withAttributes: [.foregroundColor: mark.color, .font: NSFont.systemFont(ofSize: 18 * displayScale * mark.textScale, weight: .semibold)])
        }
        path.stroke()
    }

    /// 用缩小采样再最近邻放大形成像素块，不依赖 GPU 滤镜；预览和导出使用相同结果。
    private func drawMosaic(_ mark: Mark, rect: CGRect, blockSize: CGFloat) {
        guard rect.width > 0, rect.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.imageInterpolation = .none
        if let cached = mosaicCache[mark.id], cached.0 == rect, cached.1 == blockSize {
            cached.2.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
            return
        }
        // CGImage 裁剪使用左上原点；标注使用左下原点，并可能有 Retina 比例。
        guard let source = mosaicSource else { NSColor.black.setFill(); rect.fill(); return }
        let sx = CGFloat(source.width) / pixelSize.width, sy = CGFloat(source.height) / pixelSize.height
        let sourceRect = CGRect(x: rect.minX * sx, y: (pixelSize.height - rect.maxY) * sy,
                                width: rect.width * sx, height: rect.height * sy).integral
        let width = max(1, Int(ceil(rect.width / blockSize)))
        let height = max(1, Int(ceil(rect.height / blockSize)))
        guard let cropped = source.cropping(to: sourceRect),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            NSColor.black.setFill(); rect.fill(); return
        }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { NSColor.black.setFill(); rect.fill(); return }
        let mosaic = NSImage(cgImage: result, size: rect.size)
        if marks.contains(where: { $0.id == mark.id }) {
            if mosaicCache.count > 64 { mosaicCache.removeAll() }
            mosaicCache[mark.id] = (rect, blockSize, mosaic)
        }
        mosaic.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
    }

    /// 几何标注从鼠标按下开始；文字输入由覆盖层的原生行内编辑器处理。
    override func mouseDown(with event: NSEvent) {
        guard tool != .text, imageRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        pending = [point(event)]
    }

    /// 画笔保留采样点，几何工具仅保留起点和当前终点。
    override func mouseDragged(with event: NSEvent) {
        guard !pending.isEmpty else { return }
        if tool == .pen || tool == .mosaic { pending.append(point(event)) }
        else { pending = [pending[0], point(event)] }
        needsDisplay = true
    }

    /// 释放鼠标时提交非零尺寸标注。
    override func mouseUp(with event: NSEvent) {
        if pending.count > 1 || (tool == .mosaic && !pending.isEmpty) { marks.append(Mark(tool: tool, points: pending, color: ink, text: "", strokeWidth: strokeWidth)) }
        pending = []
        needsDisplay = true
    }

    /// 不经由缩放视图截图，直接按源图像素大小导出，避免 Retina 模糊。
    func png() throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixelSize.width), pixelsHigh: Int(pixelSize.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw AnnotatorError(message: "无法创建导出画布。")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        paint(includePending: false)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AnnotatorError(message: "无法生成 PNG。") }
        return data
    }
}

/// 独立原生窗口的生命周期；完成或取消后退出，不常驻后台。
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// 当前会话及截图画布，窗口存活期间强引用。
    var session: Session?
    var window: NSWindow?
    var canvas: Canvas?
    /// 防止关闭事件覆盖成功状态，或重复点击造成多次粘贴。
    var finishing = false
    var confirmButton: NSButton?
    /// 持有系统截图子进程，直至用户完成选区或取消。
    var captureProcess: Process?
    /// 当前截图屏幕及底部工具栏，生命周期限于一次截图。
    var captureScreen: NSScreen?
    var floatingTools: FloatingTools?
    /// 冻结画面对应的正常窗口边界，按从前到后排序，不包含本截图进程。
    var captureWindowRects: [CGRect] = []
    /// 启动阶段耗时只写数值，不记录屏幕或聊天内容。
    var captureStartedAt = ProcessInfo.processInfo.systemUptime
    var captureBackend = "legacy-cli"

    /// 后台启动时只调用系统选区截图，目标聊天在用户点击完成时才选择；不自动触发编译。
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--check-permissions") {
            // 独立诊断不创建截图会话，不读取 Codex 窗口，也不改变剪贴板。
            finishing = true
            showPermissionStatus()
            NSApp.terminate(nil)
            return
        }
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出截图标注", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        do {
            let session: Session
            if CommandLine.arguments.contains("--start-session") { session = try Session() }
            else { session = try Session(arguments: CommandLine.arguments) }
            self.session = session
            let screens = NSScreen.screens
            guard let screen = screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? screens.first,
                  let index = screens.firstIndex(of: screen) else { throw AnnotatorError(message: "未找到可截图的屏幕。") }
            captureScreen = screen
            captureWindowRects = windowRects(on: screen)
            session.update("capturing", "正在准备屏幕截图，随后拖动选择范围。")
            captureStartedAt = ProcessInfo.processInfo.systemUptime
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
            let captureRect = CGRect(x: screen.frame.minX, y: primaryTop - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
            if #available(macOS 26.0, *) {
                captureBackend = "ScreenCaptureKit-memory"
                let config = SCScreenshotConfiguration()
                config.width = Int(screen.frame.width * screen.backingScaleFactor)
                config.height = Int(screen.frame.height * screen.backingScaleFactor)
                config.showsCursor = false
                config.dynamicRange = .sdr
                SCScreenshotManager.captureScreenshot(rect: captureRect, configuration: config) { [weak self] output, error in
                    DispatchQueue.main.async { self?.receivedCapture(output?.sdrImage, error: error) }
                }
                return
            } else if #available(macOS 15.2, *) {
                captureBackend = "ScreenCaptureKit-memory"
                SCScreenshotManager.captureImage(in: captureRect) { [weak self] image, error in
                    DispatchQueue.main.async { self?.receivedCapture(image, error: error) }
                }
                return
            }
            let rawURL = session.directory.appendingPathComponent("capture.png")
            let capture = Process()
            captureProcess = capture
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-t", "png", "-D", String(index + 1), rawURL.path]
            // 系统截图交互由用户结束，不在主线程阻塞 App 生命周期。
            capture.terminationHandler = { _ in
                DispatchQueue.main.async {
                    self.captureProcess = nil
                    guard let data = try? Data(contentsOf: rawURL), let bitmap = NSBitmapImageRep(data: data), let image = NSImage(data: data) else {
                        self.finishing = true
                        session.update("error", "未能读取屏幕截图，请检查屏幕录制权限。")
                        self.showError("未能读取屏幕截图，请从菜单栏“检查权限”，并确认系统弹窗已允许。")
                        NSApp.terminate(nil)
                        return
                    }
                    self.showEditor(image: image, pixels: NSSize(width: CGFloat(bitmap.pixelsWide), height: CGFloat(bitmap.pixelsHigh)))
                }
            }
            try capture.run()
        } catch {
            finishing = true
            session?.update("error", error.localizedDescription)
            showError(error.localizedDescription)
            NSApp.terminate(nil)
        }
    }

    /// 内存截图直接交给画布，避免整屏 PNG 写盘再解码；系统错误保留原始提示。
    func receivedCapture(_ image: CGImage?, error: Error?) {
        guard !finishing else { return }
        guard let image = image else {
            finishing = true
            let message = error?.localizedDescription ?? "未能读取屏幕截图，请检查屏幕录制权限。"
            session?.update("error", message)
            showError(message)
            NSApp.terminate(nil)
            return
        }
        showEditor(image: NSImage(cgImage: image, size: captureScreen?.frame.size ?? .zero),
                   pixels: CGSize(width: image.width, height: image.height))
    }

    /// 仅在截图前读取一次窗口几何信息；悬停时不用辅助功能、不扫描控件或读取窗口正文。
    func windowRects(on screen: NSScreen) -> [CGRect] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        return windows.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowOwnerPID as String] as? Int32) != ProcessInfo.processInfo.processIdentifier,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let values = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: values) else { return nil }
            return SelectionGeometry.localWindowRect(rect, screen: screen.frame, primaryTop: primaryTop)
        }
    }

    /// 在当前屏幕上显示冻结画面与可拖动选区，使用底部浮动工具栏完成标注。
    func showEditor(image: NSImage, pixels: NSSize) {
        guard let screen = captureScreen ?? NSScreen.main else { return }
        NSApp.setActivationPolicy(.accessory)
        let window = SelectionWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        self.window = window
        window.title = "screenshotForCodex · 截图标注"
        // 输入法候选窗口必须能显示在截图界面上方，不能使用屏幕保护程序层级。
        window.level = .floating
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        let canvas = SelectionCanvas(image: image, pixelSize: pixels)
        canvas.frame = CGRect(origin: .zero, size: screen.frame.size)
        canvas.windowCandidates = captureWindowRects
        canvas.updateWindowPreview(at: CGPoint(x: NSEvent.mouseLocation.x - screen.frame.minX,
                                              y: NSEvent.mouseLocation.y - screen.frame.minY))
        self.canvas = canvas
        window.contentView = canvas
        let tools = FloatingTools()
        floatingTools = tools
        confirmButton = tools.confirmButton
        tools.isHidden = true
        canvas.addSubview(tools)
        canvas.selectionChanged = { [weak self] in self?.layoutTools() }
        window.confirmSelection = { [weak self, weak canvas] in if canvas?.selection != nil { self?.finish() } }
        window.cancelSelection = { [weak self] in self?.cancelCapture() }
        canvas.confirm = { [weak self] in self?.finish() }
        canvas.cancel = { [weak self] in self?.cancelCapture() }
        canvas.undo = { [weak self] in self?.undoMark() }
        tools.chooseTool = { [weak self, weak canvas] index in
            guard let canvas = canvas else { return }
            canvas.chooseDrawingTool(index)
            window.makeFirstResponder(canvas)
            window.invalidateCursorRects(for: canvas)
            self?.layoutTools()
        }
        tools.chooseStrokeWidth = { [weak canvas] width in canvas?.applyStrokeWidth(width); window.makeFirstResponder(canvas) }
        tools.chooseFontSize = { [weak canvas] size in canvas?.applyFontSize(size); window.makeFirstResponder(canvas) }
        tools.chooseColor = { [weak canvas] color in canvas?.applyColor(color); window.makeFirstResponder(canvas) }
        canvas.markSelectionChanged = { [weak tools] mark in tools?.reflectSelection(mark) }
        tools.confirm = { [weak self] in self?.finish() }
        tools.cancel = { [weak self] in self?.cancelCapture() }
        tools.undo = { [weak self] in self?.undoMark() }
        tools.relayout = { [weak self] in self?.layoutTools() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)
        session?.update("annotating", "单击采用预选窗口，拖动可自选范围；双击空白或回车完成，Esc 取消。")
        // 从快捷键到覆盖层显示的真实耗时留待用户试用后读取，不能用离线启动替代端到端数据。
        if let directory = session?.directory {
            let now = ProcessInfo.processInfo.systemUptime
            let arguments = CommandLine.arguments
            let index = arguments.firstIndex(of: "--request-uptime")
            let requested = index.flatMap { $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil } ?? captureStartedAt
            let metrics: [String: Any] = ["backend": captureBackend, "capture_to_editor_ms": (now - captureStartedAt) * 1000,
                                        "request_to_editor_ms": (now - requested) * 1000]
            if let data = try? JSONSerialization.data(withJSONObject: metrics) {
                try? data.write(to: directory.appendingPathComponent("performance.json"), options: .atomic)
            }
        }
    }

    /// 选区拖动时隐藏工具条，释放后按屏幕剩余空间自动重新定位。
    func layoutTools() {
        guard let canvas = canvas as? SelectionCanvas, let tools = floatingTools else { return }
        guard let selection = canvas.selection, !canvas.isAdjusting else { tools.isHidden = true; return }
        tools.position(below: selection, in: canvas.bounds)
        tools.isHidden = false
    }

    /// 撤销最近的一次标注，不影响源截图。
    @objc func undoMark() {
        (canvas as? SelectionCanvas)?.undoEdit()
        window?.makeFirstResponder(canvas)
    }

    /// 取消不写剪贴板、不粘贴，也不保留原始截图。
    @objc func cancelCapture() {
        guard !finishing else { return }
        finishing = true
        if let directory = session?.directory { try? FileManager.default.removeItem(at: directory.appendingPathComponent("capture.png")) }
        session?.update("cancelled", "已取消标注，未附加图片。")
        NSApp.terminate(nil)
    }

    /// 点击对勾只生成 PNG、写剪贴板和发起一次保护性粘贴；从不发送聊天消息。
    @objc func finish() {
        guard !finishing, let canvas = canvas, let session = session else { return }
        finishing = true
        confirmButton?.isEnabled = false
        do {
            let data = try canvas.png()
            let file = session.directory.appendingPathComponent("annotated.png")
            try data.write(to: file, options: .atomic)
            let clipboard = NSPasteboard.general
            clipboard.clearContents()
            guard clipboard.setData(data, forType: .png) else { throw AnnotatorError(message: "PNG 已保存，但无法写入剪贴板。") }
            try? FileManager.default.removeItem(at: session.directory.appendingPathComponent("capture.png"))
            window?.orderOut(nil)
            // 每次只重新查找当前聊天；恢复后才调用一次粘贴，避免重试产生重复附件。
            ComposerLookup.resolve(prepare: PasteTarget.requestFullAccessibilityIfNeeded, lookup: {
                try PasteTarget(allowFocused: CommandLine.arguments.contains("--focused-composer"))
            }) { result in
                switch result {
                case .failure(let error):
                    session.update("saved", error.localizedDescription, image: file)
                    self.showError("图片已保存并复制，但未自动附图。\n\(error.localizedDescription)\n\n可在目标聊天按 ⌘V。")
                    NSApp.terminate(nil)
                case .success(let target):
                    target.paste(imageData: data) { result in
                        switch result {
                        case .success:
                            // 文件证据说明 Codex 接收了匹配图片；是否显示在正确聊天仍以缩略图为准。
                            session.update("paste_requested", "检测到 Codex 接收的匹配图片，请确认当前聊天的附件缩略图；标注图仍在剪贴板，未自动发送。", image: file)
                        case .failure(let error):
                            session.update("saved", error.localizedDescription, image: file)
                            self.showError("图片已保存并复制，但未自动附图。\n\(error.localizedDescription)\n\n可在目标聊天按 ⌘V。")
                        }
                        NSApp.terminate(nil)
                    }
                }
            }
        } catch {
            finishing = false
            confirmButton?.isEnabled = true
            session.update("annotating", "导出失败：\(error.localizedDescription)，可重试。")
            showError(error.localizedDescription)
        }
    }

    /// 由标注进程查询自身权限；只在用户点击按钮后打开对应系统设置，不自动更改授权。
    func showPermissionStatus() {
        let status = PermissionStatus(accessibility: AXIsProcessTrusted(),
                                      screenRecording: CGPreflightScreenCaptureAccess())
        let alert = NSAlert()
        alert.messageText = "截图标注 · 权限检查"
        alert.informativeText = status.message
        alert.addButton(withTitle: "知道了")
        alert.addButton(withTitle: "打开辅助功能设置")
        alert.addButton(withTitle: "打开屏幕录制设置")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let pane: String
        switch response {
        case .alertSecondButtonReturn: pane = "Privacy_Accessibility"
        case .alertThirdButtonReturn: pane = "Privacy_ScreenCapture"
        default: return
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"),
              NSWorkspace.shared.open(url) else {
            showError("无法打开系统设置。请手动进入“系统设置 → 隐私与安全性”，查看辅助功能或屏幕录制权限。")
            return
        }
    }

    /// 显示可操作的错误，保留本地图片以便恢复。
    func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "截图标注"
        alert.informativeText = message
        alert.window.level = window?.level ?? .floating
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    /// 关闭窗口等同取消，防止会话永久停留在“标注中”。
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancelCapture(); return false }

    /// 从菜单退出也结束会话，避免正常退出遗留活动锁。
    func applicationWillTerminate(_ notification: Notification) {
        guard !finishing else { return }
        if captureProcess?.isRunning == true { captureProcess?.terminate() }
        if let directory = session?.directory { try? FileManager.default.removeItem(at: directory.appendingPathComponent("capture.png")) }
        session?.update("cancelled", "截图标注进程已退出。")
    }
}

#if !UI_TESTING
/// 多文件原生构建的明确入口；独立标注 App 完成一次操作后退出。
@main enum AnnotatorMain {
    static func main() {
        if CommandLine.arguments.contains("--startup-probe") { print("native-ready"); return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

#endif
