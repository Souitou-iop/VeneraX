import Foundation

/// 应用数据目录定位。与 Flutter 版一致：数据在 Application Support，
/// 缓存在 Caches；下载的漫画存于数据目录下 `local`。
public enum AppPaths {
    /// 供单元测试与工具进程覆盖。
    nonisolated(unsafe) public static var overrideDataPath: String?
    nonisolated(unsafe) public static var overrideCachePath: String?

    public static var dataPath: String {
        if let overrideDataPath { return overrideDataPath }
        #if os(iOS)
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensureDirectory(url).path
        #elseif os(macOS)
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VeneraX", isDirectory: true)
        return ensureDirectory(url).path
        #else
        return NSTemporaryDirectory()
        #endif
    }

    public static var cachePath: String {
        if let overrideCachePath { return overrideCachePath }
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return ensureDirectory(url).path
    }

    /// 下载/导入漫画的根目录（原版可通过设置改到任意目录，
    /// 实际路径存于 `<dataPath>/local_path` 纯文本文件）。
    public static var localComicsPath: String {
        let pathFile = join(dataPath, "local_path")
        if let custom = try? String(contentsOfFile: pathFile, encoding: .utf8),
           !custom.isEmpty
        {
            return custom
        }
        return join(dataPath, "local")
    }

    public static func setLocalComicsPath(_ path: String) {
        let pathFile = join(dataPath, "local_path")
        try? path.write(toFile: pathFile, atomically: true, encoding: .utf8)
    }

    public static func join(_ base: String, _ components: String...) -> String {
        var result = base
        for component in components {
            result = URL(fileURLWithPath: result).appendingPathComponent(component).path
        }
        return result
    }

    public static var comicSourcePath: String { join(dataPath, "comic_source") }

    private static func ensureDirectory(_ url: URL) -> URL {
        let path = url.path
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        return url
    }
}

/// 原子写文件。原版以「先写临时文件再替换」避免进程被杀导致文件截断
/// （appdata.json 截断会静默丢失全部设置）。
public enum FileIO {
    public static func writeStringAtomic(_ path: String, _ content: String) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).tmp.\(UUID().uuidString)")
        try content.write(to: temporary, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    public static func deleteIgnoringErrors(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    public static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}
