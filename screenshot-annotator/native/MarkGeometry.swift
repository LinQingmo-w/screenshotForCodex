import AppKit

/// 标注对象的命中与变换统一使用源图像素，拖动、导出和 Retina 显示共用相同坐标。
enum MarkGeometry {
    /// 文字使用实际字体尺寸；细线也保留非零包围框，以支持缩放手柄。
    static func bounds(_ mark: Mark, fontSize: CGFloat) -> CGRect {
        guard let first = mark.points.first else { return .zero }
        if mark.tool == .text {
            let size = (mark.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize * mark.textScale, weight: .semibold)])
            return CGRect(origin: first, size: CGSize(width: max(8, size.width), height: max(8, size.height)))
        }
        let xs = mark.points.map(\.x), ys = mark.points.map(\.y)
        let rect = CGRect(x: xs.min()!, y: ys.min()!, width: max(1, xs.max()! - xs.min()!), height: max(1, ys.max()! - ys.min()!))
        if mark.tool == .mosaic {
            let radius = AnnotationSizes.mosaicBrushWidth(mark.strokeWidth) * (fontSize / 18) / 2
            return rect.insetBy(dx: -radius, dy: -radius)
        }
        return rect
    }

    /// 图形只命中轮廓，允许在框内部继续画图；文字命中整个文字区域。
    static func contains(_ point: CGPoint, mark: Mark, tolerance: CGFloat, fontSize: CGFloat) -> Bool {
        let rect = bounds(mark, fontSize: fontSize)
        guard rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
        switch mark.tool {
        case .text: return true
        case .rectangle:
            return abs(point.x - rect.minX) <= tolerance || abs(point.x - rect.maxX) <= tolerance
                || abs(point.y - rect.minY) <= tolerance || abs(point.y - rect.maxY) <= tolerance
        case .ellipse:
            let dx = (point.x - rect.midX) / max(1, rect.width / 2)
            let dy = (point.y - rect.midY) / max(1, rect.height / 2)
            return abs(sqrt(dx * dx + dy * dy) - 1) * min(rect.width, rect.height) / 2 <= tolerance
        case .arrow, .pen, .line, .mosaic:
            let hitTolerance = tolerance + (mark.tool == .mosaic ? AnnotationSizes.mosaicBrushWidth(mark.strokeWidth) * (fontSize / 18) / 2 : 0)
            if mark.points.count == 1 { return hypot(point.x - mark.points[0].x, point.y - mark.points[0].y) <= hitTolerance }
            return zip(mark.points, mark.points.dropFirst()).contains { a, b in
                let vx = b.x - a.x, vy = b.y - a.y
                let denominator = vx * vx + vy * vy
                let t = denominator == 0 ? 0 : min(1, max(0, ((point.x - a.x) * vx + (point.y - a.y) * vy) / denominator))
                return hypot(point.x - a.x - t * vx, point.y - a.y - t * vy) <= hitTolerance
            }
        }
    }

    /// 从原包围框仿射变换全部控制点；文字使用统一字号缩放，保持字形比例。
    static func transformed(_ mark: Mark, from old: CGRect, to new: CGRect) -> Mark {
        var result = mark
        var source = old, destination = new
        if mark.tool == .mosaic, !mark.points.isEmpty {
            // 笔刷边缘包含半径，缩放轨迹时扣除固定笔刷半径，避免选中框与实际笔划错位。
            let xs = mark.points.map(\.x), ys = mark.points.map(\.y)
            let radius = max(0, min((old.width - max(1, xs.max()! - xs.min()!)) / 2,
                                    (old.height - max(1, ys.max()! - ys.min()!)) / 2))
            source = old.insetBy(dx: radius, dy: radius)
            destination = CGRect(x: new.minX + radius, y: new.minY + radius,
                                 width: max(1, new.width - radius * 2), height: max(1, new.height - radius * 2))
        }
        let sx = destination.width / max(1, source.width), sy = destination.height / max(1, source.height)
        result.points = mark.points.map { CGPoint(x: destination.minX + ($0.x - source.minX) * sx, y: destination.minY + ($0.y - source.minY) * sy) }
        if mark.tool == .text {
            let factor = abs(sx - 1) > abs(sy - 1) ? sx : sy
            result.textScale = min(8, max(0.25, mark.textScale * factor))
        }
        return result
    }
}

/// 工具条与画布共用的尺寸档位，单位为屏幕逻辑点。
enum AnnotationSizes {
    /// 图形/画笔：细 2pt、中 4pt、粗 8pt。
    static let strokeWidths: [CGFloat] = [2, 4, 8]
    /// 马赛克为宽笔刷，细/中/粗对应 8/12/24pt，始终比普通画笔更宽。
    static func mosaicBrushWidth(_ strokeWidth: CGFloat) -> CGFloat { max(8, strokeWidth * 3) }
    /// 文字：小 14pt、中 18pt、大 24pt、特大 36pt。
    static let fontSizes: [CGFloat] = [14, 18, 24, 36]

    /// 自由缩放后的文字选中时显示最接近的字号档位，不改变对象实际大小。
    static func nearest(_ value: CGFloat, in values: [CGFloat]) -> Int {
        values.indices.min { abs(values[$0] - value) < abs(values[$1] - value) } ?? 0
    }
}
