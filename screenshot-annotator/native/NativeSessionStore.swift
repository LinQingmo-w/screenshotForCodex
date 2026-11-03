import Foundation
import Darwin

/// 原生入口与 MCP 共用磁盘会话锁，避免每次截图先启动 Node 再转交原生 App。
enum NativeSessionStore {
    /// 与服务端保持相同的终态集合；进行中的截图或未知状态不回收。
    static let terminal: Set<String> = ["attached", "paste_requested", "saved", "cancelled", "error"]

    /// 在固定应用目录分配一次会话；root 仅供离线文件测试注入，UI 不接受任意目录。
    static func create(root: URL) throws -> UUID {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let starting = root.appendingPathComponent("starting.lock")
        try exclusive(starting, text: String(ProcessInfo.processInfo.processIdentifier))
        defer { try? manager.removeItem(at: starting) }
        let active = root.appendingPathComponent("active.lock")
        if let old = try? String(contentsOf: active, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), UUID(uuidString: old) != nil {
            let status = root.appendingPathComponent(old).appendingPathComponent("status.json")
            if let data = try? Data(contentsOf: status),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let state = object["state"] as? String, terminal.contains(state) { try manager.removeItem(at: active) }
        }
        let id = UUID()
        try exclusive(active, text: id.uuidString.lowercased())
        do {
            let directory = root.appendingPathComponent(id.uuidString.lowercased())
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: ["state": "launching", "message": "正在准备截图。"])
            try data.write(to: directory.appendingPathComponent("status.json"), options: .atomic)
            return id
        } catch {
            try? manager.removeItem(at: active)
            throw error
        }
    }

    /// 与 Node 的 wx 一样原子排他创建锁，不能用存在检查再写入代替。
    private static func exclusive(_ url: URL, text: String) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            if errno == EEXIST { throw NSError(domain: "ScreenshotSession", code: 1, userInfo: [NSLocalizedDescriptionKey: "已有截图正在启动或标注，请先完成或取消。"] ) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        try file.write(contentsOf: Data(text.utf8))
    }
}
