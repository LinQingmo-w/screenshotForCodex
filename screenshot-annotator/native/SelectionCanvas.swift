import AppKit

/// 无标题屏幕覆盖层也必须允许键盘焦点，才能响应回车和 Esc。
final class SelectionWindow: NSWindow {
    /// 主窗口优先处理完成/取消快捷键；原生行内文字编辑器拥有独立的回车行为。
    var confirmSelection: (() -> Void)?
    var cancelSelection: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// 即使焦点落在工具按钮上，回车也表示完成；不拦截行内文字编辑器的按键。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // 原生文本编辑器必须先处理组合输入、候选词确认、复制和撤销。
        if firstResponder is NSTextView || firstResponder is NSTextField { return super.performKeyEquivalent(with: event) }
        if NSApp.modalWindow == nil, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if event.keyCode == 36 || event.keyCode == 76 { confirmSelection?(); return true }
            if event.keyCode == 53 { cancelSelection?(); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// 冻结屏幕上的可调整选区；标注仍使用父类的原始像素坐标与绘制逻辑。
final class SelectionCanvas: Canvas, NSTextFieldDelegate {
    /// 当前裁剪范围为逻辑点；nil 表示等待用户拖出第一个选区。
    var selection: CGRect?
    /// 冻结时的窗口边界按前后层叠排列，仅在尚未确认范围时用于鼠标预选。
    var windowCandidates: [CGRect] = []
    private(set) var previewSelection: CGRect?
    /// 未选工具且无标注时可移动选区；有标注后仅允许调整边界，标注坐标保持不变。
    var annotationEnabled = false
    /// 布局、完成、取消与撤销由宿主处理，闭包不读取或操作聊天界面。
    var selectionChanged: (() -> Void)?
    var confirm: (() -> Void)?
    var cancel: (() -> Void)?
    var undo: (() -> Void)?
    /// 每次拖动保留起点与原选区，避免累计鼠标位移造成漂移。
    private enum Drag {
        case none, previewing(CGRect, CGPoint), selecting(CGPoint), moving(CGRect, CGPoint), resizing(CGRect, Int, CGPoint), marking([Mark])
        case movingMark(Int, Mark, CGPoint, [Mark]), resizingMark(Int, Mark, CGRect, Int, CGPoint, [Mark])
    }
    private var drag = Drag.none
    /// 标注编辑状态只属于当前截图；撤销快照也覆盖移动、缩放、文字和颜色修改。
    private(set) var selectedMark: Int?
    private var hoveredMark: Int?
    private var history: [[Mark]] = []
    private var tracking: NSTrackingArea?
    /// 马赛克单击点涂若成为双击的第一下，第二下先撤掉这个临时点再按原内容判断。
    private var lastDabID: UUID?
    /// 使用系统原生行内编辑框，中文输入法的预编辑文字和候选窗口由 AppKit 管理。
    private(set) var textEditor: NSTextField?
    private var editingIndex: Int?
    private var textOrigin = CGPoint.zero
    var markSelectionChanged: ((Mark?) -> Void)?

    /// 源像素与屏幕逻辑点的比例，供对象命中与字体尺寸使用。
    private var pixelScale: CGFloat { max(1, pixelSize.width / max(1, bounds.width)) }

    /// 将标注包围框映射到界面，选中框本身不进入导出的 PNG。
    private func markRect(_ index: Int) -> CGRect {
        let rect = MarkGeometry.bounds(marks[index], fontSize: 18 * pixelScale)
        return CGRect(x: rect.minX / pixelScale, y: rect.minY / pixelScale, width: rect.width / pixelScale, height: rect.height / pixelScale)
    }

    /// 仅在裁剪范围内从后往前命中最上层图形，避免大矩形内部挡住其他标注。
    private func markAt(_ point: CGPoint) -> Int? {
        guard selection?.contains(point) == true else { return nil }
        let pixel = CGPoint(x: point.x * pixelScale, y: point.y * pixelScale)
        return marks.indices.reversed().first { MarkGeometry.contains(pixel, mark: marks[$0], tolerance: 6 * pixelScale, fontSize: 18 * pixelScale) }
    }

    /// 选中对象时同步颜色和工具；取消选择不会删除对象。
    private func selectMark(_ index: Int?) {
        selectedMark = index
        if let index = index, marks.indices.contains(index) {
            ink = marks[index].color
            if marks[index].tool == .text { currentTextScale = marks[index].textScale }
            else { strokeWidth = marks[index].strokeWidth }
            tool = marks[index].tool
            annotationEnabled = true
            markSelectionChanged?(marks[index])
        } else { markSelectionChanged?(nil) }
        needsDisplay = true
    }

    /// 只为实际内容变化保留撤销快照，避免一次点击占用一条撤销记录。
    private func remember(_ before: [Mark]) {
        if before != marks { history.append(before); if history.count > 50 { history.removeFirst() } }
    }

    /// 切换工具先提交当前文字；新工具用于之后的绘制，不修改已选对象的类型。
    func chooseDrawingTool(_ index: Int?) {
        commitTextEditing()
        selectMark(nil)
        pending = []
        annotationEnabled = index != nil
        if let index = index { tool = Tool(rawValue: index) ?? .rectangle }
    }

    /// 颜色既用于后续绘制，也立即应用到当前选中的对象。
    func applyColor(_ color: NSColor) {
        commitTextEditing()
        ink = color
        if let index = selectedMark, marks.indices.contains(index) {
            let before = marks
            marks[index].color = color
            remember(before)
        }
        needsDisplay = true
    }

    /// 粗细用于后续图形/画笔，也更新已选中的对象；纯粗细调整不占用撤销记录。
    func applyStrokeWidth(_ width: CGFloat) {
        guard AnnotationSizes.strokeWidths.contains(width) else { return }
        commitTextEditing()
        strokeWidth = width
        if let index = selectedMark, marks.indices.contains(index), marks[index].tool != .text {
            marks[index].strokeWidth = width
        }
        needsDisplay = true
    }

    /// 四档字号用于后续文字，也能修改当前文字；输入中点击字号先提交再调整。
    func applyFontSize(_ size: CGFloat) {
        guard AnnotationSizes.fontSizes.contains(size) else { return }
        commitTextEditing()
        currentTextScale = size / 18
        if let index = selectedMark, marks.indices.contains(index), marks[index].tool == .text {
            let before = marks
            marks[index].textScale = currentTextScale
            remember(before)
        }
        needsDisplay = true
    }

    /// 撤销绘制及编辑；文字正在输入时由原生文本编辑器处理自己的撤销。
    func undoEdit() {
        commitTextEditing()
        guard let previous = history.popLast() else { return }
        // 撤销内容、位置等修改时，保留仍存在对象的最新粗细；不能被旧快照顺带还原。
        let currentWidths = Dictionary(marks.map { ($0.id, $0.strokeWidth) }, uniquingKeysWith: { _, latest in latest })
        marks = previous.map { saved in
            var restored = saved
            if let width = currentWidths[saved.id] { restored.strokeWidth = width }
            return restored
        }
        selectMark(nil)
    }

    /// 原生编辑框固定在文字位置，不启动模态窗口，不阻塞其他工具。
    func beginText(at pixel: CGPoint, editing index: Int? = nil) {
        commitTextEditing()
        let old = index.flatMap { marks.indices.contains($0) ? marks[$0] : nil }
        textOrigin = old?.points.first ?? pixel
        editingIndex = index
        suppressedMark = index
        selectMark(index)
        let font = NSFont.systemFont(ofSize: 18 * (old?.textScale ?? currentTextScale), weight: .semibold)
        let width = max(160, ((old?.text ?? "") as NSString).size(withAttributes: [.font: font]).width + 20)
        let x = min(bounds.maxX - 60, max(0, textOrigin.x / pixelScale - 5))
        let y = min(bounds.maxY - font.pointSize - 14, max(0, textOrigin.y / pixelScale - 5))
        let field = NSTextField(frame: CGRect(x: x, y: y, width: min(width, bounds.maxX - x - 4), height: font.pointSize + 14))
        field.stringValue = old?.text ?? ""
        field.font = font
        field.textColor = old?.color ?? ink
        field.backgroundColor = NSColor.white.withAlphaComponent(0.96)
        field.isBordered = true
        field.isEditable = true
        field.isSelectable = true
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.target = self
        field.action = #selector(commitTextAction)
        textEditor = field
        addSubview(field)
        window?.makeFirstResponder(field)
        if let editor = field.currentEditor() as? NSTextView {
            editor.insertionPointColor = .darkGray
            editor.setSelectedRange(NSRange(location: field.stringValue.utf16.count, length: 0))
        }
        needsDisplay = true
    }

    /// 回车只提交当前文字；下一次回车才由画布触发整张图完成。
    @objc private func commitTextAction() { commitTextEditing() }

    /// 在点击其他工具、完成或失焦时提交；空白文字不会产生空对象。
    func commitTextEditing() {
        guard let field = textEditor else { return }
        let value = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
        let index = editingIndex
        textEditor = nil
        editingIndex = nil
        suppressedMark = nil
        window?.makeFirstResponder(self)
        field.removeFromSuperview()
        let before = marks
        if let index = index, marks.indices.contains(index) {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { marks.remove(at: index); selectMark(nil) }
            else { marks[index].text = value; selectMark(index) }
        } else if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            marks.append(Mark(tool: .text, points: [textOrigin], color: ink, text: value, textScale: currentTextScale))
            selectMark(marks.count - 1)
        }
        remember(before)
        needsDisplay = true
    }

    /// Esc 放弃本次文字修改并保留原标注，不取消整张截图。
    private func cancelTextEditing() {
        guard let field = textEditor else { return }
        textEditor = nil
        editingIndex = nil
        suppressedMark = nil
        window?.makeFirstResponder(self)
        field.removeFromSuperview()
        needsDisplay = true
    }

    /// 正在组合输入时让输入法自行处理回车与 Esc，不提前提交标注。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { commitTextEditing(); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { cancelTextEditing(); return true }
        return false
    }

    /// 点击工具或画布造成失焦时完成行内编辑，避免留下隐藏的编辑状态。
    func controlTextDidEndEditing(_ obj: Notification) { commitTextEditing() }

    /// 输入时随内容扩展编辑框，长文字仍可在原生单行编辑器内水平滚动。
    func controlTextDidChange(_ obj: Notification) {
        guard let field = textEditor else { return }
        let value = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
        let width = max(160, (value as NSString).size(withAttributes: [.font: field.font!]).width + 20)
        field.frame.size.width = min(width, bounds.maxX - field.frame.minX - 4)
    }

    /// 预选只显示边框，不开启工具栏；按窗口快照的前后顺序选择鼠标所在最上层窗口。
    func updateWindowPreview(at point: CGPoint) {
        guard selection == nil else { return }
        previewSelection = windowCandidates.first { $0.contains(point) }
        needsDisplay = true
    }

    /// 裁剪只限制标注的显示与导出，不修改标注模型的位置或大小。
    override var annotationClipRect: CGRect? {
        selection.map { CGRect(x: $0.minX * pixelScale, y: $0.minY * pixelScale,
                               width: $0.width * pixelScale, height: $0.height * pixelScale) }
    }

    /// 跟踪鼠标以高亮可编辑对象；所有命中都局限于本地标注模型。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    /// 悬停显示对象轮廓，单击可选中，双击文字进入编辑。
    override func mouseMoved(with event: NSEvent) {
        guard textEditor == nil else { return }
        if selection == nil { updateWindowPreview(at: convert(event.locationInWindow, from: nil)); return }
        hoveredMark = annotationEnabled && tool == .mosaic && selectedMark == nil ? nil : markAt(convert(event.locationInWindow, from: nil))
        if hoveredMark != nil { NSCursor.pointingHand.set() }
        needsDisplay = true
    }

    /// 覆盖层一比一覆盖当前屏幕，Retina 比例只在标注与导出时换算。
    override var imageRect: NSRect { bounds }

    /// 冻结画面与标注上方绘制暗色遮罩、选框和尺寸；这些 UI 不进入导出的图片。
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let mask = NSBezierPath(rect: bounds)
        if let rect = selection ?? previewSelection { mask.appendRect(rect) }
        mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.48).setFill()
        mask.fill()
        guard let rect = selection ?? previewSelection else { return }
        NSColor.systemGreen.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 2
        border.stroke()
        NSColor.systemGreen.setFill()
        for point in selection == nil ? [] : SelectionGeometry.handles(rect) {
            NSBezierPath(roundedRect: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7), xRadius: 1, yRadius: 1).fill()
        }
        if let index = selectedMark ?? hoveredMark, marks.indices.contains(index), suppressedMark != index {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            let box = markRect(index).insetBy(dx: -3, dy: -3)
            NSColor.gray.setStroke()
            let outline = NSBezierPath(rect: box)
            outline.lineWidth = 1
            outline.setLineDash([4, 3], count: 2, phase: 0)
            outline.stroke()
            if selectedMark == index {
                for point in SelectionGeometry.handles(box) {
                    let circle = NSBezierPath(ovalIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
                    NSColor.white.setFill(); circle.fill(); NSColor.gray.setStroke(); circle.stroke()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        let pixels = SelectionGeometry.pixels(rect, viewSize: bounds.size, pixelSize: pixelSize)
        let size = "\(Int(pixels.width)) × \(Int(pixels.height))" as NSString
        size.draw(at: CGPoint(x: rect.minX + 4, y: min(bounds.maxY - 25, rect.maxY + 6)),
                  withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white])
    }

    /// 单击采用窗口预选，拖动改为手动范围；双击空白完成，双击文字编辑，再处理边界和标注。
    override func mouseDown(with event: NSEvent) {
        commitTextEditing()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount >= 2, let id = lastDabID, marks.last?.id == id {
            marks.removeLast()
            _ = history.popLast()
        }
        lastDabID = nil
        if event.clickCount >= 2, let index = markAt(point), marks[index].tool == .text {
            beginText(at: self.point(event), editing: index)
            drag = .none
            return
        }
        if event.clickCount >= 2, let rect = selection, rect.contains(point),
           SelectionGeometry.hitHandle(point, rect: rect) == nil, markAt(point) == nil {
            drag = .none
            confirm?()
            return
        }
        if let index = selectedMark, marks.indices.contains(index), selection?.contains(point) == true,
           let handle = SelectionGeometry.hitHandle(point, rect: markRect(index).insetBy(dx: -3, dy: -3), tolerance: 6) {
            drag = .resizingMark(index, marks[index], markRect(index), handle, point, marks)
            return
        }
        if let rect = selection {
            if let handle = SelectionGeometry.hitHandle(point, rect: rect) {
                selectMark(nil)
                drag = .resizing(rect, handle, point)
            } else if rect.contains(point), !(annotationEnabled && tool == .mosaic && selectedMark == nil), let index = markAt(point) {
                selectMark(index)
                if marks[index].tool == .text && event.clickCount >= 2 {
                    beginText(at: self.point(event), editing: index)
                    drag = .none
                    return
                }
                drag = .movingMark(index, marks[index], point, marks)
            } else if rect.contains(point) && annotationEnabled {
                selectMark(nil)
                if tool == .text { beginText(at: self.point(event)); drag = .none; return }
                drag = .marking(marks)
                super.mouseDown(with: event)
                return
            } else if rect.contains(point) {
                selectMark(nil)
                drag = marks.isEmpty ? .moving(rect, point) : .none
            } else if marks.isEmpty {
                selectMark(nil)
                drag = .selecting(point)
                selection = CGRect(origin: point, size: .zero)
            } else { drag = .none }
        } else {
            updateWindowPreview(at: point)
            if let preview = previewSelection { drag = .previewing(preview, point) }
            else { drag = .selecting(point); selection = CGRect(origin: point, size: .zero) }
        }
        selectionChanged?()
        needsDisplay = true
    }

    /// 对象编辑始终从按下时的快照计算，避免连续位移造成误差。
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .previewing(_, let start):
            guard hypot(point.x - start.x, point.y - start.y) >= 3 else { return }
            previewSelection = nil
            drag = .selecting(start)
            selection = SelectionGeometry.rectangle(from: start, to: point, in: bounds)
        case .selecting(let start): selection = SelectionGeometry.rectangle(from: start, to: point, in: bounds)
        case .moving(let rect, let start): selection = SelectionGeometry.moved(rect, by: CGPoint(x: point.x - start.x, y: point.y - start.y), in: bounds)
        case .resizing(let rect, let handle, let start): selection = SelectionGeometry.resized(rect, handle: handle, by: CGPoint(x: point.x - start.x, y: point.y - start.y), in: bounds)
        case .marking: super.mouseDragged(with: event)
        case .movingMark(let index, let original, let start, _):
            let delta = CGPoint(x: (point.x - start.x) * pixelScale, y: (point.y - start.y) * pixelScale)
            marks[index] = original
            marks[index].points = original.points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
        case .resizingMark(let index, let original, let rect, let handle, let start, _):
            let resized = SelectionGeometry.resized(rect, handle: handle, by: CGPoint(x: point.x - start.x, y: point.y - start.y), in: bounds)
            let oldPixels = CGRect(x: rect.minX * pixelScale, y: rect.minY * pixelScale, width: rect.width * pixelScale, height: rect.height * pixelScale)
            let newPixels = CGRect(x: resized.minX * pixelScale, y: resized.minY * pixelScale, width: resized.width * pixelScale, height: resized.height * pixelScale)
            marks[index] = MarkGeometry.transformed(original, from: oldPixels, to: newPixels)
        case .none: return
        }
        selectionChanged?()
        needsDisplay = true
    }

    /// 一次拖动只记录一次撤销；新画出的标注立即可再次选中编辑。
    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .previewing(let rect, _):
            selection = rect
            previewSelection = nil
        case .marking(let before):
            let wasDab = tool == .mosaic && pending.count == 1
            super.mouseUp(with: event)
            remember(before)
            if marks.count > before.count {
                selectMark(tool == .mosaic ? nil : marks.count - 1)
                if wasDab { lastDabID = marks.last?.id }
            }
        case .movingMark(_, _, _, let before), .resizingMark(_, _, _, _, _, let before): remember(before)
        default: break
        }
        drag = .none
        if let rect = selection, rect.width < 8 || rect.height < 8 { selection = nil }
        selectionChanged?()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    /// 范围拖动期间隐藏浮动工具栏；画标注时保留工具栏。
    var isAdjusting: Bool {
        switch drag {
        case .selecting, .moving, .resizing: return true
        default: return false
        }
    }

    /// 根据手柄方向提供拖动光标，普通屏幕区域使用十字光标。
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        guard let rect = selection else { return }
        if !annotationEnabled && marks.isEmpty { addCursorRect(rect, cursor: .openHand) }
        for (index, point) in SelectionGeometry.handles(rect).enumerated() {
            addCursorRect(CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18),
                          cursor: [1, 5].contains(index) ? .resizeUpDown : .resizeLeftRight)
        }
    }

    /// 文字输入由原生编辑器处理；画布仅处理非编辑状态下的完成、删除与取消。
    override func keyDown(with event: NSEvent) {
        if textEditor != nil { commitTextEditing(); return }
        if (event.keyCode == 51 || event.keyCode == 117), let index = selectedMark, marks.indices.contains(index) {
            let before = marks; marks.remove(at: index); remember(before); selectMark(nil); return
        }
        if event.keyCode == 36 || event.keyCode == 76 { if selection != nil { confirm?() }; return }
        if event.keyCode == 53 { cancel?(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" { undo?(); return }
        super.keyDown(with: event)
    }

    /// 先用已有渲染导出原尺寸标注，再按选区裁剪，遮罩与工具栏不会混入 PNG。
    override func png() throws -> Data {
        commitTextEditing()
        guard let rect = selection, rect.width >= 8, rect.height >= 8,
              let full = NSBitmapImageRep(data: try super.png())?.cgImage else {
            throw AnnotatorError(message: "请先拖动选择截图范围。")
        }
        let crop = SelectionGeometry.pixels(rect, viewSize: bounds.size, pixelSize: pixelSize)
        guard let image = full.cropping(to: crop),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw AnnotatorError(message: "无法导出选定范围的图片。")
        }
        return data
    }
}
