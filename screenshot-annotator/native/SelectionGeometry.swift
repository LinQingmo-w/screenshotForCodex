import Foundation

/// 选区计算与界面解耦，坐标始终为当前屏幕左下角起算的逻辑点。
enum SelectionGeometry {
    /// 将任意拖动方向的两个端点变成屏幕内的矩形。
    static func rectangle(from start: CGPoint, to end: CGPoint, in bounds: CGRect) -> CGRect {
        let a = CGPoint(x: min(bounds.maxX, max(bounds.minX, start.x)), y: min(bounds.maxY, max(bounds.minY, start.y)))
        let b = CGPoint(x: min(bounds.maxX, max(bounds.minX, end.x)), y: min(bounds.maxY, max(bounds.minY, end.y)))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// 将 Window Server 的左上原点窗口边界映射到当前屏幕局部坐标，跨屏部分裁到屏幕内。
    static func localWindowRect(_ rect: CGRect, screen: CGRect, primaryTop: CGFloat) -> CGRect? {
        let local = CGRect(x: rect.minX - screen.minX, y: primaryTop - rect.maxY - screen.minY,
                           width: rect.width, height: rect.height)
            .intersection(CGRect(origin: .zero, size: screen.size))
        return !local.isNull && local.width >= 8 && local.height >= 8 ? local : nil
    }

    /// 移动时保持选区大小，禁止越过屏幕边缘。
    static func moved(_ rect: CGRect, by delta: CGPoint, in bounds: CGRect) -> CGRect {
        CGRect(x: min(bounds.maxX - rect.width, max(bounds.minX, rect.minX + delta.x)),
               y: min(bounds.maxY - rect.height, max(bounds.minY, rect.minY + delta.y)), width: rect.width, height: rect.height)
    }

    /// 八个手柄从左下角开始逆时针排列，顺序与绘制及命中检测一致。
    static func handles(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)]
    }

    /// 角点优先，其次是任意边缘；不要求精确点中边中间的小方块。
    static func hitHandle(_ point: CGPoint, rect: CGRect, tolerance: CGFloat = 9) -> Int? {
        if let index = handles(rect).firstIndex(where: { abs($0.x - point.x) <= tolerance && abs($0.y - point.y) <= tolerance }) { return index }
        guard rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return nil }
        if abs(point.x - rect.minX) <= tolerance { return 7 }
        if abs(point.x - rect.maxX) <= tolerance { return 3 }
        if abs(point.y - rect.minY) <= tolerance { return 1 }
        if abs(point.y - rect.maxY) <= tolerance { return 5 }
        return nil
    }

    /// 只改变被拖动的边；保留至少 8 点大小，避免手柄跨越后出现反向选区。
    static func resized(_ rect: CGRect, handle: Int, by delta: CGPoint, in bounds: CGRect) -> CGRect {
        var left = rect.minX, right = rect.maxX, bottom = rect.minY, top = rect.maxY
        if [0, 6, 7].contains(handle) { left = min(right - 8, max(bounds.minX, left + delta.x)) }
        if [2, 3, 4].contains(handle) { right = max(left + 8, min(bounds.maxX, right + delta.x)) }
        if [0, 1, 2].contains(handle) { bottom = min(top - 8, max(bounds.minY, bottom + delta.y)) }
        if [4, 5, 6].contains(handle) { top = max(bottom + 8, min(bounds.maxY, top + delta.y)) }
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }

    /// AppKit 左下原点转换为 PNG 左上原点；点坐标取整后严格限制到源像素内。
    static func pixels(_ rect: CGRect, viewSize: CGSize, pixelSize: CGSize) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let sx = pixelSize.width / viewSize.width, sy = pixelSize.height / viewSize.height
        let result = CGRect(x: rect.minX * sx, y: (viewSize.height - rect.maxY) * sy,
                            width: rect.width * sx, height: rect.height * sy).integral
        return result.intersection(CGRect(origin: .zero, size: pixelSize))
    }
}
