import Foundation
import CoreGraphics
import ImageIO

/// 只验证候选选择策略，不会创建 App、读取 AX 树或发送键盘事件。
@main struct ComposerPolicyTests {
    static func main() {
        func candidate(_ hint: String, focused: Bool = false, writable: Bool = true, role: String = "AXTextArea") -> ComposerCandidate {
            ComposerCandidate(role: role, hint: hint, focused: focused, writableRange: writable)
        }
        assert(ComposerPolicy.select([candidate("和 Codex 一起工作")], allowFocused: false) == 0)
        assert(ComposerPolicy.select([candidate("Message"), candidate("Message", focused: true)], allowFocused: false) == 1)
        assert(ComposerPolicy.select([candidate("Message"), candidate("Message")], allowFocused: false) == nil)
        assert(ComposerPolicy.select([candidate("", focused: true)], allowFocused: false) == nil)
        assert(ComposerPolicy.select([candidate("", focused: true)], allowFocused: true) == 0)
        assert(ComposerPolicy.select([candidate("", focused: true, writable: false)], allowFocused: true) == nil)
        assert(ComposerPolicy.select([candidate("Search", focused: true)], allowFocused: true) == nil)
        assert(ComposerPolicy.select([candidate("code editor", focused: true)], allowFocused: true) == nil)
        assert(ComposerPolicy.select([candidate("", focused: true), candidate("", focused: true)], allowFocused: true) == nil)
        assert(ComposerPolicy.select([candidate("", focused: true, role: "AXTextField")], allowFocused: true) == nil)
        // 用可控队列模拟 AX 树恢复；等待期间不触发粘贴或多次完成。
        var pending: [() -> Void] = []
        var lookups = 0
        var completions = 0
        ComposerLookup.resolve(lookup: { () throws -> Int in
            lookups += 1
            if lookups < 3 { throw ComposerNotFound(message: "not ready") }
            return 42
        }, schedule: { pending.append($0) }) { result in
            completions += 1
            assert(try! result.get() == 42)
        }
        assert(lookups == 1 && completions == 0 && pending.count == 1)
        pending.removeFirst()()
        assert(lookups == 2 && completions == 0 && pending.count == 1)
        pending.removeFirst()()
        assert(lookups == 3 && completions == 1 && pending.isEmpty)

        // 持续找不到时最多查找四次，最终只报一次最后的错误。
        lookups = 0
        completions = 0
        ComposerLookup.resolve(lookup: { () throws -> Int in
            lookups += 1
            throw ComposerNotFound(message: "scan \(lookups)")
        }, schedule: { pending.append($0) }) { result in
            completions += 1
            if case .failure(let error) = result { assert(error.localizedDescription == "scan 4") }
            else { assertionFailure("missing terminal failure") }
        }
        for _ in 0..<3 { assert(pending.count == 1); pending.removeFirst()() }
        assert(lookups == 4 && completions == 1 && pending.isEmpty)

        // 权限等非查找错误不重试；首轮成功同样不能排队再次执行。
        lookups = 0
        ComposerLookup.resolve(lookup: { () throws -> Int in
            lookups += 1
            throw NSError(domain: "permission", code: 1)
        }, schedule: { pending.append($0) }) { result in
            if case .success = result { assertionFailure("permission must fail") }
        }
        assert(lookups == 1 && pending.isEmpty)
        completions = 0
        ComposerLookup.resolve(lookup: { 7 }, schedule: { pending.append($0) }) { result in
            completions += 1
            assert(try! result.get() == 7)
        }
        assert(completions == 1 && pending.isEmpty)
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        let draft = "中文 😀"
        assert(PastePolicy.rejection(original: draft, current: draft, selection: NSRange(location: draft.utf16.count, length: 0), expectedPNG: png, clipboardPNG: png) == nil)
        assert(PastePolicy.rejection(original: draft, current: draft, selection: NSRange(location: 1, length: 0), expectedPNG: png, clipboardPNG: png) == nil)
        assert(PastePolicy.rejection(original: draft, current: draft, selection: NSRange(location: 0, length: 2), expectedPNG: png, clipboardPNG: png) != nil)
        assert(PastePolicy.rejection(original: draft, current: draft + "新文字", selection: NSRange(location: 0, length: 0), expectedPNG: png, clipboardPNG: png) != nil)
        assert(PastePolicy.rejection(original: "", current: "", selection: NSRange(location: 0, length: 0), expectedPNG: png, clipboardPNG: png) == nil)
        assert(PastePolicy.rejection(original: draft, current: draft, selection: NSRange(location: NSNotFound, length: 0), expectedPNG: png, clipboardPNG: png) != nil)
        assert(PastePolicy.rejection(original: draft, current: draft, selection: NSRange(location: 0, length: 0), expectedPNG: png, clipboardPNG: nil) != nil)
        assert(PastePolicy.rejection(original: draft, current: draft, selection: NSRange(location: 0, length: 0), expectedPNG: png, clipboardPNG: Data([1])) != nil)
        // 通过临时目录模拟 Codex 接收图片，避免测试读取或操作真实聊天。
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        /// 生成一个单像素测试 PNG；颜色变化必须导致接收证据不匹配。
        func image(_ red: CGFloat, width: Int = 1) -> Data {
            let context = CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(red: red, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: 1))
            let data = NSMutableData()
            let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            assert(CGImageDestinationFinalize(destination))
            return data as Data
        }
        let red = image(1)
        try! red.write(to: directory.appendingPathComponent("codex-clipboard-old.png"))
        let observation = AttachmentObservation(imageData: red, directory: directory)
        assert(!observation.hasMatchingImage())
        try! red.write(to: directory.appendingPathComponent("unrelated.png"))
        assert(!observation.hasMatchingImage())
        let fresh = directory.appendingPathComponent("codex-clipboard-new.png")
        try! image(0).write(to: fresh)
        assert(!observation.hasMatchingImage())
        try! Data([1, 2, 3]).write(to: fresh)
        assert(!observation.hasMatchingImage())
        try! image(1, width: 2).write(to: fresh)
        assert(!observation.hasMatchingImage())
        try! red.write(to: fresh)
        assert(observation.hasMatchingImage())
        assert(!AttachmentObservation(imageData: Data(), directory: directory).hasMatchingImage())
        assert(PermissionStatus(accessibility: true, screenRecording: true).message.contains("基础权限已开启"))
        assert(PermissionStatus(accessibility: false, screenRecording: true).message.contains("辅助功能：未开启\n屏幕录制：已开启"))
        assert(PermissionStatus(accessibility: true, screenRecording: false).message.contains("辅助功能：已开启\n屏幕录制：未开启"))
        assert(PermissionStatus(accessibility: false, screenRecording: false).message.contains("辅助功能：未开启\n屏幕录制：未开启"))
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 80)
        assert(SelectionGeometry.rectangle(from: CGPoint(x: 90, y: 70), to: CGPoint(x: -20, y: -5), in: bounds) == CGRect(x: 0, y: 0, width: 90, height: 70))
        let rect = CGRect(x: 20, y: 20, width: 40, height: 30)
        assert(SelectionGeometry.moved(rect, by: CGPoint(x: 100, y: -100), in: bounds) == CGRect(x: 60, y: 0, width: 40, height: 30))
        assert(SelectionGeometry.resized(rect, handle: 0, by: CGPoint(x: 100, y: 100), in: bounds) == CGRect(x: 52, y: 42, width: 8, height: 8))
        assert(SelectionGeometry.resized(rect, handle: 4, by: CGPoint(x: 100, y: 100), in: bounds) == CGRect(x: 20, y: 20, width: 80, height: 60))
        assert(SelectionGeometry.resized(rect, handle: 7, by: CGPoint(x: -100, y: 100), in: bounds) == CGRect(x: 0, y: 20, width: 60, height: 30))
        assert(SelectionGeometry.pixels(rect, viewSize: bounds.size, pixelSize: CGSize(width: 200, height: 160)) == CGRect(x: 40, y: 60, width: 80, height: 60))
        assert(SelectionGeometry.pixels(bounds, viewSize: bounds.size, pixelSize: bounds.size) == bounds)
        assert(SelectionGeometry.pixels(rect, viewSize: .zero, pixelSize: bounds.size) == .zero)
        let largeRect = CGRect(x: 100, y: 100, width: 500, height: 400)
        assert(SelectionGeometry.hitHandle(CGPoint(x: 100, y: 150), rect: largeRect) == 7)
        assert(SelectionGeometry.hitHandle(CGPoint(x: 100, y: 100), rect: largeRect) == 0)
        assert(SelectionGeometry.hitHandle(CGPoint(x: 250, y: 250), rect: largeRect) == nil)
        print("Composer, paste, attachment, permission and geometry policies: including lookup retries passed; no desktop access")
    }
}
