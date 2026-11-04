import AppKit

/// 用合成屏幕验证导出、工具栏与快捷键，不读取屏幕、不接触 Codex。
@main struct OverlayTests {
    static func main() throws {
        _ = NSApplication.shared
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 100, height: 40).fill()
        NSColor.red.setFill(); NSRect(x: 0, y: 40, width: 100, height: 40).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: CGSize(width: 100, height: 80))
        image.addRepresentation(bitmap)
        let canvas = SelectionCanvas(image: image, pixelSize: CGSize(width: 100, height: 80))
        canvas.frame = CGRect(x: 0, y: 0, width: 50, height: 40)
        canvas.selection = CGRect(x: 10, y: 0, width: 20, height: 10)
        let bottom = NSBitmapImageRep(data: try canvas.png())!
        assert(bottom.pixelsWide == 40 && bottom.pixelsHigh == 20)
        let blue = bottom.colorAt(x: 10, y: 10)!.usingColorSpace(.deviceRGB)!
        assert(blue.blueComponent > 0.9 && blue.redComponent < 0.1)
        canvas.selection = CGRect(x: 10, y: 30, width: 20, height: 10)
        let top = NSBitmapImageRep(data: try canvas.png())!
        let red = top.colorAt(x: 10, y: 10)!.usingColorSpace(.deviceRGB)!
        assert(red.redComponent > 0.9 && red.blueComponent < 0.1)
        canvas.selection = nil
        do { _ = try canvas.png(); assertionFailure("Empty selection must fail") } catch {}

        let toolbar = FloatingTools()
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        toolbar.position(below: CGRect(x: 100, y: 300, width: 600, height: 300), in: screen)
        assert(toolbar.frame.maxY < 300)
        let bar = toolbar.subviews[0], palette = toolbar.subviews[1]
        assert(palette.isHidden)
        let buttons = bar.subviews.compactMap { $0 as? NSButton }
        let colors = palette.subviews.compactMap { $0 as? NSButton }
        assert(colors.count == 6 && colors[0].layer?.borderWidth == 3)
        assert(colors.allSatisfy { $0.title.isEmpty })
        assert(buttons.count == 10 && buttons.allSatisfy { $0.toolTip != "调整范围" })
        assert(buttons.allSatisfy { $0.title.isEmpty && $0.image != nil })
        var tool: Int? = nil
        var selectedColor: NSColor?
        toolbar.chooseTool = { tool = $0 }
        toolbar.chooseColor = { selectedColor = $0 }
        toolbar.relayout = { toolbar.position(below: CGRect(x: 900, y: 1, width: 500, height: 500), in: screen) }
        buttons[0].performClick(nil)
        assert(tool == 0 && !palette.isHidden)
        assert(bar.frame.offsetBy(dx: toolbar.frame.minX, dy: toolbar.frame.minY).minY > 501 && screen.contains(toolbar.frame))
        colors[1].performClick(nil)
        assert(selectedColor == NSColor.systemBlue && colors[1].layer?.borderWidth == 3)
        buttons[3].performClick(nil)
        assert(tool == 2 && colors[1].layer?.borderWidth == 3)
        buttons[3].performClick(nil)
        assert(tool == nil && palette.isHidden)

        // 颜色条出现前后，主工具栏的屏幕位置必须一致。
        let nearBottom = CGRect(x: 500, y: 90, width: 500, height: 400)
        toolbar.relayout = { toolbar.position(below: nearBottom, in: screen) }
        toolbar.position(below: nearBottom, in: screen)
        let beforePalette = bar.frame.offsetBy(dx: toolbar.frame.minX, dy: toolbar.frame.minY)
        buttons[0].performClick(nil)
        let afterPalette = bar.frame.offsetBy(dx: toolbar.frame.minX, dy: toolbar.frame.minY)
        assert(beforePalette == afterPalette)
        buttons[0].performClick(nil)
        assert(bar.frame.offsetBy(dx: toolbar.frame.minX, dy: toolbar.frame.minY) == beforePalette)

        let rectangle = Mark(tool: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 50)], color: .systemRed, text: "")
        assert(MarkGeometry.contains(CGPoint(x: 60, y: 30), mark: rectangle, tolerance: 3, fontSize: 18))
        assert(!MarkGeometry.contains(CGPoint(x: 30, y: 30), mark: rectangle, tolerance: 3, fontSize: 18))
        let ellipse = Mark(tool: .ellipse, points: rectangle.points, color: .systemRed, text: "")
        assert(MarkGeometry.contains(CGPoint(x: 35, y: 50), mark: ellipse, tolerance: 3, fontSize: 18))
        assert(!MarkGeometry.contains(CGPoint(x: 35, y: 30), mark: ellipse, tolerance: 3, fontSize: 18))
        let arrow = Mark(tool: .arrow, points: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 50)], color: .systemRed, text: "")
        assert(MarkGeometry.contains(CGPoint(x: 30, y: 31), mark: arrow, tolerance: 3, fontSize: 18))
        let transformed = MarkGeometry.transformed(rectangle, from: CGRect(x: 10, y: 10, width: 50, height: 40), to: CGRect(x: 20, y: 20, width: 100, height: 80))
        assert(transformed.points == [CGPoint(x: 20, y: 20), CGPoint(x: 120, y: 100)])

        let editable = SelectionCanvas(image: image, pixelSize: CGSize(width: 100, height: 80))
        editable.frame = CGRect(x: 0, y: 0, width: 100, height: 80)
        editable.selection = editable.bounds
        editable.marks = [rectangle]
        let editingWindow = SelectionWindow(contentRect: editable.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        editingWindow.contentView = editable
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: editingWindow.windowNumber,
                context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
        }
        editable.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 60, y: 30)))
        assert(editable.selectedMark == 0)
        editable.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 65, y: 35)))
        editable.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 65, y: 35)))
        assert(editable.marks[0].points == [CGPoint(x: 15, y: 15), CGPoint(x: 65, y: 55)])
        editable.applyColor(.systemBlue)
        assert(editable.marks[0].color == NSColor.systemBlue)
        editable.undoEdit()
        assert(editable.marks[0].color == NSColor.systemRed)
        editable.undoEdit()
        assert(editable.marks[0].points == rectangle.points)
        editable.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 60, y: 30)))
        editable.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 60, y: 30)))
        editable.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 63, y: 53)))
        editable.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 73, y: 63)))
        editable.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 73, y: 63)))
        assert(editable.marks[0].points == [CGPoint(x: 10, y: 10), CGPoint(x: 70, y: 60)])
        editable.undoEdit()
        assert(editable.marks[0] == rectangle)
        editable.beginText(at: CGPoint(x: 20, y: 55))
        assert(editable.textEditor != nil)
        func typeText(_ value: String) {
            if let field = editable.textEditor {
                field.stringValue = value
                (field.currentEditor() as? NSTextView)?.string = value
            }
        }
        typeText("中文输入 😀")
        let composing = NSTextView()
        composing.setMarkedText("wan", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        assert(composing.hasMarkedText())
        assert(!editable.control(editable.textEditor!, textView: composing, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        assert(editable.textEditor != nil)
        composing.unmarkText()
        editable.commitTextEditing()
        assert(editable.textEditor == nil && editable.marks.last?.text == "中文输入 😀")
        let textIndex = editable.marks.count - 1
        editable.beginText(at: .zero, editing: textIndex)
        typeText("重新编辑")
        editable.commitTextEditing()
        assert(editable.marks.count == 2 && editable.marks[textIndex].text == "重新编辑")
        editable.undoEdit()
        assert(editable.marks[textIndex].text == "中文输入 😀")

        let editingTools = FloatingTools()
        let editButtons = editingTools.subviews[0].subviews.compactMap { $0 as? NSButton }
        let editColors = editingTools.subviews[1].subviews.compactMap { $0 as? NSButton }
        editingTools.chooseTool = { editable.chooseDrawingTool($0) }
        editingTools.chooseColor = { editable.applyColor($0) }
        editingTools.chooseStrokeWidth = { editable.applyStrokeWidth($0) }
        editingTools.chooseFontSize = { editable.applyFontSize($0) }
        editable.markSelectionChanged = { editingTools.reflectSelection($0) }
        editable.beginText(at: .zero, editing: textIndex)
        typeText("输入中直接切工具")
        editButtons[0].performClick(nil)
        assert(editable.textEditor == nil && editable.tool == .rectangle)
        assert(editable.marks[textIndex].text == "输入中直接切工具")
        assert(editButtons[0].contentTintColor == NSColor.systemGreen)
        editable.beginText(at: .zero, editing: textIndex)
        typeText("输入中直接改颜色")
        editColors[1].performClick(nil)
        assert(editable.textEditor == nil && editable.marks[textIndex].color == NSColor.systemBlue)
        assert(editColors[1].layer?.borderWidth == 3)

        // 四档字号更新已有文字，撤销可恢复；输入框与绘制模型使用同一字号。
        let sizeControl = editingTools.subviews[1].subviews.compactMap { $0 as? NSSegmentedControl }.first!
        assert(sizeControl.segmentCount == 4 && sizeControl.selectedSegment == 1)
        sizeControl.selectedSegment = 3
        _ = sizeControl.sendAction(sizeControl.action, to: sizeControl.target)
        assert(editable.marks[textIndex].textScale == 2 && editable.currentTextScale == 2)
        editable.undoEdit()
        assert(editable.marks[textIndex].textScale == 1)
        editable.applyFontSize(24)
        editable.beginText(at: CGPoint(x: 20, y: 20))
        assert(editable.textEditor?.font?.pointSize == 24)
        editable.commitTextEditing()
        editButtons[0].performClick(nil)
        assert(sizeControl.segmentCount == 3 && sizeControl.selectedSegment == 1)
        sizeControl.selectedSegment = 2
        _ = sizeControl.sendAction(sizeControl.action, to: sizeControl.target)
        assert(editable.strokeWidth == 8)
        editable.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 25, y: 25)))
        editable.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 45, y: 40)))
        editable.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 45, y: 40)))
        assert(editable.marks.last?.strokeWidth == 8)
        editable.undoEdit()
        assert(editable.marks.count == 2)
        editable.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 60, y: 30)))
        editable.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 60, y: 30)))
        assert(sizeControl.selectedSegment == 1)
        editable.applyStrokeWidth(2)
        assert(editable.marks[0].strokeWidth == 2)
        assert(AnnotationSizes.nearest(27, in: AnnotationSizes.fontSizes) == 2)
        assert(AnnotationSizes.nearest(4, in: AnnotationSizes.strokeWidths) == 1)

        let strokeCanvas = SelectionCanvas(image: image, pixelSize: CGSize(width: 100, height: 80))
        strokeCanvas.frame = CGRect(x: 0, y: 0, width: 100, height: 80)
        strokeCanvas.selection = strokeCanvas.bounds
        /// 从导出图像中测量绿色竖边，确保粗细档位确实改变 PNG 像素。
        func exportedStrokePixels(_ width: CGFloat) throws -> Int {
            var mark = rectangle; mark.strokeWidth = width; mark.color = .green
            strokeCanvas.marks = [mark]
            let result = NSBitmapImageRep(data: try strokeCanvas.png())!
            return (5...15).filter { x in
                let color = result.colorAt(x: x, y: 50)!.usingColorSpace(.deviceRGB)!
                return color.greenComponent > 0.4 && color.redComponent < 0.4 && color.blueComponent < 0.4
            }.count
        }
        let thickPixels = try exportedStrokePixels(8)
        let thinPixels = try exportedStrokePixels(2)
        assert(thickPixels > thinPixels)

        var confirmations = 0, cancellations = 0
        canvas.confirm = { confirmations += 1 }
        canvas.cancel = { cancellations += 1 }
        func key(_ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        canvas.keyDown(with: key(36))
        assert(confirmations == 0)
        canvas.selection = CGRect(x: 0, y: 0, width: 20, height: 20)
        canvas.keyDown(with: key(36)); canvas.keyDown(with: key(76))
        assert(confirmations == 2)
        canvas.keyDown(with: key(53))
        assert(cancellations == 1)
        editable.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 60, y: 30)))
        editable.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 60, y: 30)))
        editable.keyDown(with: key(51))
        assert(editable.marks.count == 1)
        editable.undoEdit()
        assert(editable.marks.count == 2)

        // 调整粗细不消耗撤销：第一次撤销应直接恢复位置，且粗细保持最新值。
        let widthHistory = SelectionCanvas(image: image, pixelSize: CGSize(width: 100, height: 80))
        widthHistory.frame = editable.frame
        widthHistory.selection = widthHistory.bounds
        widthHistory.marks = [rectangle]
        let widthWindow = SelectionWindow(contentRect: widthHistory.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        widthWindow.contentView = widthHistory
        widthHistory.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 60, y: 30)))
        widthHistory.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 65, y: 35)))
        widthHistory.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 65, y: 35)))
        widthHistory.applyStrokeWidth(8)
        widthHistory.undoEdit()
        assert(widthHistory.marks[0].points == rectangle.points)
        assert(widthHistory.marks[0].strokeWidth == 8)
        widthHistory.undoEdit()
        assert(widthHistory.marks.count == 1 && widthHistory.marks[0].strokeWidth == 8)
        widthHistory.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 60, y: 30)))
        widthHistory.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 60, y: 30)))
        widthHistory.keyDown(with: key(51))
        assert(widthHistory.marks.isEmpty)
        widthHistory.undoEdit()
        assert(widthHistory.marks.count == 1 && widthHistory.marks[0].strokeWidth == 8)

        // 删除改变数组下标后，粗细也必须按对象身份匹配，而不是覆盖到另一个框。
        let secondRectangle = Mark(tool: .rectangle, points: [CGPoint(x: 20, y: 20), CGPoint(x: 80, y: 60)], color: .systemRed, text: "")
        widthHistory.marks.append(secondRectangle)
        widthHistory.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 60, y: 30)))
        widthHistory.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 60, y: 30)))
        widthHistory.keyDown(with: key(51))
        widthHistory.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 80, y: 40)))
        widthHistory.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 80, y: 40)))
        widthHistory.applyStrokeWidth(2)
        widthHistory.undoEdit()
        assert(widthHistory.marks.count == 2)
        assert(widthHistory.marks[0].strokeWidth == 8)
        assert(widthHistory.marks[1].id == secondRectangle.id && widthHistory.marks[1].strokeWidth == 2)

        // 直线可命中与仿射缩放，不产生箭头的额外端点。
        let lineMark = Mark(tool: .line, points: [CGPoint(x: 10, y: 10), CGPoint(x: 70, y: 50)], color: .systemRed, text: "")
        assert(MarkGeometry.contains(CGPoint(x: 40, y: 30), mark: lineMark, tolerance: 3, fontSize: 18))
        assert(!MarkGeometry.contains(CGPoint(x: 40, y: 50), mark: lineMark, tolerance: 3, fontSize: 18))
        assert(MarkGeometry.transformed(lineMark, from: CGRect(x: 10, y: 10, width: 60, height: 40), to: CGRect(x: 20, y: 20, width: 120, height: 80)).points.last == CGPoint(x: 140, y: 100))

        // 原生会话锁与 MCP 使用相同格式；活动会话不可重入，终态可回收。
        let sessionRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sessionRoot) }
        let firstSession = try NativeSessionStore.create(root: sessionRoot)
        do { _ = try NativeSessionStore.create(root: sessionRoot); assertionFailure("Active session must block another start") } catch {}
        assert(!FileManager.default.fileExists(atPath: sessionRoot.appendingPathComponent("starting.lock").path))
        try JSONSerialization.data(withJSONObject: ["state": "saved"]).write(to: sessionRoot.appendingPathComponent(firstSession.uuidString.lowercased()).appendingPathComponent("status.json"))
        let secondSession = try NativeSessionStore.create(root: sessionRoot)
        assert(firstSession != secondSession)
        let activeSession = try String(contentsOf: sessionRoot.appendingPathComponent("active.lock"), encoding: .utf8)
        assert(activeSession == secondSession.uuidString.lowercased())

        // 用高频黑白棋盘验证马赛克确实改变区域内像素，区外像素不受影响。
        let checker = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 80, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let bytes = checker.bitmapData!
        for y in 0..<80 { for x in 0..<100 {
            let value: UInt8 = (x + y) % 2 == 0 ? 230 : 80
            let offset = y * checker.bytesPerRow + x * 4
            bytes[offset] = value; bytes[offset + 1] = value; bytes[offset + 2] = value; bytes[offset + 3] = 255
        } }
        let checkerImage = NSImage(size: CGSize(width: 100, height: 80)); checkerImage.addRepresentation(checker)
        let obscured = SelectionCanvas(image: checkerImage, pixelSize: checkerImage.size)
        obscured.frame = CGRect(origin: .zero, size: checkerImage.size)
        obscured.selection = obscured.bounds
        let beforeMosaic = NSBitmapImageRep(data: try obscured.png())!
        obscured.marks = [Mark(tool: .mosaic, points: [CGPoint(x: 20, y: 20), CGPoint(x: 80, y: 60)], color: .systemRed, text: "")]
        let afterMosaic = NSBitmapImageRep(data: try obscured.png())!
        assert(MarkGeometry.contains(CGPoint(x: 50, y: 40), mark: obscured.marks[0], tolerance: 3, fontSize: 18))
        var changed = 0
        for y in 25..<55 { for x in 25..<75 {
            if abs(afterMosaic.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!.redComponent - beforeMosaic.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!.redComponent) > 0.05 { changed += 1 }
        } }
        assert(changed > 300)
        assert(afterMosaic.colorAt(x: 50, y: 40)!.usingColorSpace(.deviceRGB)!.redComponent > 0.2)
        assert(afterMosaic.colorAt(x: 5, y: 5) == beforeMosaic.colorAt(x: 5, y: 5))
        let mosaicButton = buttons[5]
        mosaicButton.performClick(nil)
        assert(tool == Tool.mosaic.rawValue && colors.allSatisfy { $0.isHidden })
        buttons[2].performClick(nil)
        assert(tool == Tool.line.rawValue && colors.allSatisfy { $0.isEnabled })

        // 马赛克仅覆盖圆头笔刷路径，不再填满拖动的外接矩形。
        assert(afterMosaic.colorAt(x: 25, y: 25) == beforeMosaic.colorAt(x: 25, y: 25))
        assert(!MarkGeometry.contains(CGPoint(x: 25, y: 55), mark: obscured.marks[0], tolerance: 1, fontSize: 18))
        assert(AnnotationSizes.mosaicBrushWidth(4) == 12)
        assert(AnnotationSizes.mosaicBrushWidth(2) > 2)
        assert(AnnotationSizes.mosaicBrushWidth(8) > 8)
        let brush = SelectionCanvas(image: checkerImage, pixelSize: checkerImage.size)
        brush.frame = CGRect(origin: .zero, size: checkerImage.size)
        brush.selection = brush.bounds
        brush.chooseDrawingTool(Tool.mosaic.rawValue)
        brush.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 20, y: 20)))
        brush.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 50, y: 55)))
        brush.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 80, y: 20)))
        brush.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 80, y: 20)))
        assert(brush.marks.count == 1 && brush.marks[0].points.count == 3 && brush.selectedMark == nil)
        let brushed = NSBitmapImageRep(data: try brush.png())!
        // V 字笔刷覆盖顶部交点，底部中间不在路径上，应保持原图。
        assert(abs(brushed.colorAt(x: 50, y: 25)!.usingColorSpace(.deviceRGB)!.redComponent - beforeMosaic.colorAt(x: 50, y: 25)!.usingColorSpace(.deviceRGB)!.redComponent) > 0.05)
        assert(brushed.colorAt(x: 50, y: 60) == beforeMosaic.colorAt(x: 50, y: 60))
        let oldBrushBounds = MarkGeometry.bounds(brush.marks[0], fontSize: 18)
        let resizedBrushBounds = CGRect(x: oldBrushBounds.minX + 3, y: oldBrushBounds.minY + 4, width: oldBrushBounds.width + 20, height: oldBrushBounds.height + 10)
        let resizedBrush = MarkGeometry.transformed(brush.marks[0], from: oldBrushBounds, to: resizedBrushBounds)
        assert(MarkGeometry.bounds(resizedBrush, fontSize: 18) == resizedBrushBounds)
        // 重叠涂抹应新增笔划，而不是抓起上一笔移动；每笔只占一个撤销步骤。
        brush.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 50, y: 55)))
        brush.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 70, y: 55)))
        brush.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 70, y: 55)))
        assert(brush.marks.count == 2)
        brush.undoEdit()
        assert(brush.marks.count == 1)
        brush.undoEdit()
        assert(brush.marks.isEmpty)
        brush.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 50, y: 40)))
        brush.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 50, y: 40)))
        assert(brush.marks.count == 1 && brush.marks[0].points.count == 1)
        let dab = NSBitmapImageRep(data: try brush.png())!
        assert(abs(dab.colorAt(x: 50, y: 40)!.usingColorSpace(.deviceRGB)!.redComponent - beforeMosaic.colorAt(x: 50, y: 40)!.usingColorSpace(.deviceRGB)!.redComponent) > 0.05)
        assert(dab.colorAt(x: 55, y: 35) == beforeMosaic.colorAt(x: 55, y: 35))
        assert(buttons[2].toolTip == "直线" && buttons[3].toolTip == "箭头")
        assert(buttons[4].toolTip == "画笔" && buttons[5].toolTip == "马赛克画笔" && buttons[6].toolTip == "文字")
        buttons[5].performClick(nil)
        assert(palette.frame.width == 180 && colors.allSatisfy { $0.isHidden })
        buttons[4].performClick(nil)
        assert(colors.allSatisfy { !$0.isHidden })

        // 窗口快照保持前后顺序；坐标映射覆盖主屏、左侧屏和跨屏裁剪。
        assert(SelectionGeometry.localWindowRect(CGRect(x: 20, y: 10, width: 50, height: 30),
            screen: CGRect(x: 0, y: 0, width: 100, height: 80), primaryTop: 80) == CGRect(x: 20, y: 40, width: 50, height: 30))
        assert(SelectionGeometry.localWindowRect(CGRect(x: -50, y: 10, width: 70, height: 30),
            screen: CGRect(x: -100, y: 0, width: 100, height: 80), primaryTop: 80) == CGRect(x: 50, y: 40, width: 50, height: 30))
        assert(SelectionGeometry.localWindowRect(CGRect(x: 200, y: 10, width: 50, height: 30),
            screen: CGRect(x: 0, y: 0, width: 100, height: 80), primaryTop: 80) == nil)
        let snapping = SelectionCanvas(image: image, pixelSize: CGSize(width: 100, height: 80))
        snapping.frame = CGRect(x: 0, y: 0, width: 100, height: 80)
        let front = CGRect(x: 15, y: 15, width: 40, height: 40)
        let back = CGRect(x: 5, y: 5, width: 90, height: 70)
        snapping.windowCandidates = [front, back]
        snapping.updateWindowPreview(at: CGPoint(x: 30, y: 30))
        assert(snapping.previewSelection == front && snapping.selection == nil)
        do { _ = try snapping.png(); assertionFailure("Hover preview must not silently become a confirmed selection") } catch {}
        snapping.updateWindowPreview(at: CGPoint(x: 80, y: 60))
        assert(snapping.previewSelection == back)
        snapping.updateWindowPreview(at: CGPoint(x: 1, y: 1))
        assert(snapping.previewSelection == nil)
        snapping.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 30, y: 30)))
        snapping.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 30, y: 30)))
        assert(snapping.selection == front && snapping.previewSelection == nil)
        snapping.selection = nil
        snapping.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 30, y: 30)))
        snapping.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 60, y: 50)))
        snapping.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 60, y: 50)))
        assert(snapping.selection == CGRect(x: 30, y: 30, width: 30, height: 20))

        // 无标注可整体移动；有标注后空白拖动及范围外拖动均不能改变裁剪位置。
        let movable = SelectionCanvas(image: image, pixelSize: CGSize(width: 100, height: 80))
        movable.frame = snapping.frame
        let originalCrop = CGRect(x: 10, y: 10, width: 70, height: 55)
        movable.selection = originalCrop
        movable.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 40, y: 40)))
        movable.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 45, y: 43)))
        movable.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 45, y: 43)))
        assert(movable.selection == originalCrop.offsetBy(dx: 5, dy: 3))
        movable.selection = originalCrop
        let fixedMark = Mark(tool: .rectangle, points: [CGPoint(x: 20, y: 20), CGPoint(x: 75, y: 45)], color: .systemRed, text: "")
        movable.marks = [fixedMark]
        movable.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 40, y: 53)))
        movable.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 45, y: 55)))
        movable.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 45, y: 55)))
        assert(movable.selection == originalCrop && movable.marks == [fixedMark])
        movable.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 95, y: 75)))
        movable.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 90, y: 70)))
        movable.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 90, y: 70)))
        assert(movable.selection == originalCrop)
        movable.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 80, y: 35)))
        movable.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 60, y: 35)))
        movable.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 60, y: 35)))
        assert(movable.selection == CGRect(x: 10, y: 10, width: 50, height: 55) && movable.marks == [fixedMark])
        let croppedMark = NSBitmapImageRep(data: try movable.png())!
        assert(croppedMark.pixelsWide == 50 && croppedMark.pixelsHigh == 55)
        assert(croppedMark.colorAt(x: 35, y: 45)!.usingColorSpace(.deviceRGB)!.redComponent > 0.8)
        let previewPixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: previewPixels)
        movable.paint(includePending: false)
        NSGraphicsContext.restoreGraphicsState()
        let outsideCrop = previewPixels.colorAt(x: 75, y: 50)!.usingColorSpace(.deviceRGB)!
        assert(outsideCrop.blueComponent > 0.9 && outsideCrop.redComponent < 0.1)

        // 空白双击只确认一次；双击文字仍打开编辑器，普通对象仍可选中编辑。
        var doubleConfirmations = 0
        movable.confirm = { doubleConfirmations += 1 }
        movable.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 40, y: 53), clicks: 2))
        movable.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 40, y: 53), clicks: 2))
        assert(doubleConfirmations == 1)
        movable.selection = movable.bounds
        movable.marks = [Mark(tool: .text, points: [CGPoint(x: 25, y: 25)], color: .systemRed, text: "edit")]
        movable.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 30, y: 30), clicks: 2))
        assert(movable.textEditor != nil && doubleConfirmations == 1)
        movable.commitTextEditing()
        movable.marks = []
        movable.chooseDrawingTool(Tool.mosaic.rawValue)
        movable.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 45, y: 40)))
        movable.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 45, y: 40)))
        assert(movable.marks.count == 1)
        movable.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 45, y: 40), clicks: 2))
        assert(movable.marks.isEmpty && doubleConfirmations == 2)

        let shortcutWindow = SelectionWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        shortcutWindow.confirmSelection = { confirmations += 1 }
        assert(shortcutWindow.performKeyEquivalent(with: key(36)))
        assert(confirmations == 3)
        // 离屏渲染合成界面供视觉检查，绝不截取真实桌面。
        let fixture = NSImage(size: CGSize(width: 1440, height: 900))
        fixture.lockFocus()
        NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: 1440, height: 900).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: CGRect(x: 280, y: 180, width: 900, height: 620), xRadius: 16, yRadius: 16).fill()
        ("截图标注 · 合成测试画面" as NSString).draw(at: CGPoint(x: 340, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.darkGray])
        ("拖动边框调整范围，选择工具后显示颜色" as NSString).draw(at: CGPoint(x: 340, y: 620), withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.gray])
        fixture.unlockFocus()
        let preview = SelectionCanvas(image: fixture, pixelSize: fixture.size)
        preview.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        preview.selection = CGRect(x: 300, y: 230, width: 850, height: 540)
        let previewWindow = SelectionWindow(contentRect: preview.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        previewWindow.contentView = preview
        let previewTools = FloatingTools()
        preview.addSubview(previewTools)
        previewTools.subviews[0].subviews.compactMap { $0 as? NSButton }[1].performClick(nil)
        previewTools.position(below: preview.selection!, in: preview.bounds)
        preview.marks = [Mark(tool: .rectangle, points: [CGPoint(x: 420, y: 360), CGPoint(x: 900, y: 540)], color: .systemRed, text: ""),
                          Mark(tool: .text, points: [CGPoint(x: 450, y: 650)], color: .systemRed, text: "双击编辑文字")]
        let selectEvent = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 420, y: 420), modifierFlags: [], timestamp: 0,
            windowNumber: previewWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        preview.mouseDown(with: selectEvent)
        preview.layoutSubtreeIfNeeded()
        let rendered = preview.bitmapImageRepForCachingDisplay(in: preview.bounds)!
        preview.cacheDisplay(in: preview.bounds, to: rendered)
        let renderPath = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("overlay-check.png")
        try rendered.representation(using: .png, properties: [:])!.write(to: renderPath)
        preview.beginText(at: .zero, editing: 1)
        preview.cacheDisplay(in: preview.bounds, to: rendered)
        try rendered.representation(using: .png, properties: [:])!.write(to: renderPath.deletingLastPathComponent().appendingPathComponent("inline-text-check.png"))
        preview.commitTextEditing()
        preview.chooseDrawingTool(Tool.mosaic.rawValue)
        preview.marks.append(Mark(tool: .mosaic, points: [CGPoint(x: 350, y: 630), CGPoint(x: 740, y: 630), CGPoint(x: 800, y: 590)], color: .systemRed, text: ""))
        previewTools.subviews[0].subviews.compactMap { $0 as? NSButton }[6].performClick(nil)
        previewTools.position(below: preview.selection!, in: preview.bounds)
        preview.cacheDisplay(in: preview.bounds, to: rendered)
        try rendered.representation(using: .png, properties: [:])!.write(to: renderPath.deletingLastPathComponent().appendingPathComponent("mosaic-brush-check.png"))
        print("Synthetic overlay: window hover/click/drag, locked annotated crop, preview/export clipping, double-click confirmation, toolbar and editing passed")
    }
}
