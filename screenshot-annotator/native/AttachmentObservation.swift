import Foundation
import CoreGraphics
import ImageIO

/// 将图片解码为统一 RGBA 像素，避免 Codex 重编码 PNG 后误判成另一张图。
enum ImageFingerprint {
    /// 同时比较尺寸和像素；限制解码大小，无法读取时绝不当成匹配成功。
    static func pixels(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0,
              image.width <= 16384, image.height <= 16384,
              image.width * image.height <= 64_000_000,
              let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let buffer = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var result = Data("\(image.width)x\(image.height):".utf8)
        result.append(Data(bytes: buffer, count: image.width * image.height * 4))
        return result
    }
}

/// 借鉴 Screen Voice Capture 的临时文件证据，并增加基线和像素比对以排除其他截图。
final class AttachmentObservation {
    /// 只扫描系统临时目录中的 Codex 剪贴板图片，不扫描聊天历史或用户文档。
    let directory: URL
    /// 粘贴前已有文件不能证明本次图片被接收。
    let baseline: Set<URL>
    /// 标注图片的标准化像素；失败时保持 nil，不能报成功。
    let expected: Data?

    /// 创建观察基线；directory 可注入到纯文件测试，测试不接触真实 Codex。
    init(imageData: Data, directory: URL = FileManager.default.temporaryDirectory) {
        self.directory = directory
        baseline = Set((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
        expected = ImageFingerprint.pixels(imageData)
    }

    /// 新增同名模式图片且内容匹配才提供接收证据；这不是聊天缩略图或上传完成的证明。
    func hasMatchingImage() -> Bool {
        guard let expected = expected,
              let files = try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return false }
        for file in files where !baseline.contains(file) && file.lastPathComponent.hasPrefix("codex-clipboard-") {
            guard ["png", "jpg", "jpeg", "webp"].contains(file.pathExtension.lowercased()),
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= 128_000_000,
                  let data = try? Data(contentsOf: file), ImageFingerprint.pixels(data) == expected else { continue }
            return true
        }
        return false
    }
}
