import AppKit

/// 与选区联动的两层工具条；仅标注模式显示固定色条，不使用系统调色板。
final class FloatingTools: NSView {
    /// 主工具条和下方颜色条，均使用系统材质并圆角显示。
    private let bar = NSVisualEffectView()
    private let palette = NSVisualEffectView()
    /// 选择范围时为 nil；标注工具与现有 Tool 的 rawValue 一致。
    private var selectedTool: Int?
    /// 显示顺序与模型 rawValue 解耦，重新排列图标不会选错工具。
    private let displayedTools: [Tool?] = [nil, .rectangle, .ellipse, .line, .arrow, .pen, .mosaic, .text]
    private var colorIndex = 0
    /// 独立记住图形粗细和文字字号，两个工具组之间切换不互相覆盖。
    private var widthIndex = 1
    private var fontIndex = 1
    private let sizeControl = NSSegmentedControl()
    private var toolButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []
    /// 固定顺序为红、蓝、绿、黄、深灰、白，每次新截图默认红色。
    private let colors: [NSColor] = [.systemRed, .systemBlue, .systemGreen, .systemYellow, .darkGray, .white]
    /// 宿主持有完成按钮以便导出期间禁用，防止双击产生重复附件。
    private(set) var confirmButton = NSButton()
    /// 工具条只发布用户操作，不自行截图、写剪贴板或发送键盘事件。
    var chooseTool: ((Int?) -> Void)?
    var chooseColor: ((NSColor) -> Void)?
    var chooseStrokeWidth: ((CGFloat) -> Void)?
    var chooseFontSize: ((CGFloat) -> Void)?
    var confirm: (() -> Void)?
    var cancel: (() -> Void)?
    var undo: (() -> Void)?
    var relayout: (() -> Void)?

    /// 图标工具不占用截图内容；辅助功能标签与悬停提示均为中文。
    init() {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .aqua)
        for view in [bar, palette] {
            view.material = .popover
            view.blendingMode = .withinWindow
            view.state = .active
            view.wantsLayer = true
            view.layer?.cornerRadius = 10
            view.layer?.masksToBounds = true
            addSubview(view)
        }
        let labels = ["调整范围", "矩形", "圆形", "直线", "箭头", "画笔", "马赛克画笔", "文字", "撤销", "取消", "完成并附图（回车）"]
        let symbols = ["crop", "square", "circle", "line.diagonal", "arrow.up.right", "pencil", "rectangle.pattern.checkered", "textformat", "arrow.uturn.backward", "xmark", "checkmark"]
        for index in labels.indices {
            let button = NSButton(frame: CGRect(x: 10 + index * 44, y: 6, width: 40, height: 40))
            button.isBordered = false
            button.title = ""
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.image = NSImage(systemSymbolName: symbols[index], accessibilityDescription: labels[index])
            button.image = button.image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 22, weight: .regular))
            // 所有工具均使用模板图标，由同一套 tintColor 控制普通与选中状态。
            button.image?.isTemplate = true
            button.toolTip = labels[index]
            button.setAccessibilityLabel(labels[index])
            button.target = self
            button.action = #selector(pressed(_:))
            button.tag = index
            if index == 9 { button.contentTintColor = .systemRed }
            if index == 10 { button.contentTintColor = .systemGreen; confirmButton = button }
            bar.addSubview(button)
            toolButtons.append(button)
        }
        let names = ["红色", "蓝色", "绿色", "黄色", "深灰色", "白色"]
        for index in colors.indices {
            let button = NSButton(frame: CGRect(x: 10 + index * 38, y: 7, width: 30, height: 30))
            button.isBordered = false
            button.wantsLayer = true
            button.title = ""
            button.layer?.cornerRadius = 5
            button.layer?.backgroundColor = colors[index].cgColor
            button.tag = index
            button.target = self
            button.action = #selector(colorPressed(_:))
            button.toolTip = names[index]
            button.setAccessibilityLabel(names[index])
            palette.addSubview(button)
            colorButtons.append(button)
        }
        sizeControl.frame = CGRect(x: 246, y: 7, width: 160, height: 30)
        sizeControl.segmentStyle = .rounded
        sizeControl.font = NSFont.systemFont(ofSize: 12)
        sizeControl.trackingMode = .selectOne
        sizeControl.target = self
        sizeControl.action = #selector(sizeChanged(_:))
        palette.addSubview(sizeControl)
        updateSelection()
    }
    required init?(coder: NSCoder) { fatalError("不使用 storyboard") }

    /// 主工具条位置只由选区与屏幕决定；展开颜色条不能导致主栏从下方跳到上方。
    func position(below selection: CGRect, in bounds: CGRect) {
        let width: CGFloat = 504
        let x = min(bounds.maxX - width - 8, max(bounds.minX + 8, selection.maxX - width))
        let below = selection.minY - 64
        let barY = below >= 8 ? below : (selection.maxY + 64 <= bounds.maxY ? selection.maxY + 12 : 8)
        let barRect = CGRect(x: x, y: barY, width: width, height: 52)
        let paletteY = barY - 50 >= 8 ? barY - 50 : barY + 58
        let mosaic = selectedTool == Tool.mosaic.rawValue
        let paletteRect = CGRect(x: x + (mosaic ? 204 : 0), y: paletteY, width: mosaic ? 180 : 416, height: 44)
        sizeControl.frame.origin.x = mosaic ? 10 : 246
        let union = selectedTool == nil ? barRect : barRect.union(paletteRect)
        frame = union
        bar.frame = barRect.offsetBy(dx: -union.minX, dy: -union.minY)
        palette.frame = paletteRect.offsetBy(dx: -union.minX, dy: -union.minY)
        palette.isHidden = selectedTool == nil
    }

    /// 选中已有标注时同步工具和色块，不再次触发用户操作回调。
    func reflectSelection(_ mark: Mark?) {
        guard let mark = mark else { return }
        selectedTool = mark.tool.rawValue
        if let index = colors.firstIndex(of: mark.color) { colorIndex = index }
        if mark.tool == .text { fontIndex = AnnotationSizes.nearest(mark.textScale * 18, in: AnnotationSizes.fontSizes) }
        else { widthIndex = AnnotationSizes.nearest(mark.strokeWidth, in: AnnotationSizes.strokeWidths) }
        updateSelection()
        relayout?()
    }

    /// 颜色条右侧的透明空白不拦截屏幕选区拖动。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bar.frame.contains(local) || (!palette.isHidden && palette.frame.contains(local)) else { return nil }
        return super.hitTest(point)
    }

    /// 工具选择只影响后续标注；范围模式隐藏颜色条，颜色跨工具保留。
    @objc private func pressed(_ sender: NSButton) {
        switch sender.tag {
        case 0...7:
            let next = displayedTools[sender.tag]?.rawValue
            chooseTool?(next)
            selectedTool = next
            updateSelection()
            relayout?()
        case 8: undo?()
        case 9: cancel?()
        case 10: confirm?()
        default: break
        }
    }

    /// 固定色块立即生效；保持当前工具和已经完成的标注。
    @objc private func colorPressed(_ sender: NSButton) {
        let next = sender.tag
        chooseColor?(colors[next])
        colorIndex = next
        updateSelection()
    }

    /// 点击档位后更新画布；先执行回调，最后同步控件，防止文字提交的回调覆盖本次选择。
    @objc private func sizeChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        if selectedTool == Tool.text.rawValue {
            guard AnnotationSizes.fontSizes.indices.contains(index) else { return }
            chooseFontSize?(AnnotationSizes.fontSizes[index])
            fontIndex = index
        } else {
            guard AnnotationSizes.strokeWidths.indices.contains(index) else { return }
            chooseStrokeWidth?(AnnotationSizes.strokeWidths[index])
            widthIndex = index
        }
        updateSelection()
    }

    /// 文字与图形共用同一位置的档位选择器，始终保持主工具条锚点不变。
    private func updateSizeControl() {
        let isText = selectedTool == Tool.text.rawValue
        let labels = isText ? ["小", "中", "大", "特大"] : ["细", "中", "粗"]
        sizeControl.segmentCount = labels.count
        for (index, label) in labels.enumerated() {
            sizeControl.setLabel(label, forSegment: index)
            sizeControl.setWidth(152 / CGFloat(labels.count), forSegment: index)
        }
        sizeControl.selectedSegment = isText ? fontIndex : widthIndex
        let isMosaic = selectedTool == Tool.mosaic.rawValue
        for button in colorButtons { button.isEnabled = !isMosaic; button.isHidden = isMosaic }
        sizeControl.toolTip = isText ? "文字字号：小、中、大、特大" : (isMosaic ? "马赛克笔刷宽度：细、中、粗" : "边框/画笔粗细：细、中、粗")
        sizeControl.setAccessibilityLabel(isText ? "文字字号" : "边框粗细")
    }

    /// 选中工具用绿色，选中色块用双层深色边框区分，包括白色色块。
    private func updateSelection() {
        updateSizeControl()
        for (index, button) in toolButtons.enumerated() where index <= 7 {
            let selected = displayedTools[index]?.rawValue == selectedTool
            button.contentTintColor = selected ? .systemGreen : .darkGray
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.layer?.backgroundColor = selected ? NSColor.black.withAlphaComponent(0.06).cgColor : NSColor.clear.cgColor
        }
        for (index, button) in colorButtons.enumerated() {
            button.layer?.borderColor = NSColor.darkGray.cgColor
            button.layer?.borderWidth = index == colorIndex ? 3 : 0.5
        }
    }
}
