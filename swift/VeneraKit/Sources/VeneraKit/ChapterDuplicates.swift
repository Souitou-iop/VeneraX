import Foundation

/// 重复章节检测与隐藏开关（对齐原版 chapter_duplicates.dart）。
/// 「隐藏」只改变章节列表的呈现与阅读器的步进/预取，不改变平铺索引本身：
/// 详情页跳转、下载选择和历史记录都以平铺索引为准。

/// 平铺索引中，标题（trim 后）在同一 scope 内重复出现于更早条目的索引集合。
/// scopes 传 nil 时全体视为一个 scope；未被任何 scope 覆盖的索引不会上报。
/// 空白标题跳过——折叠它们会误藏只是没有名字的无关章节。
public func findDuplicateTitleIndices(
    count: Int,
    titleOf: (Int) -> String,
    scopes: [[Int]]? = nil
) -> Set<Int> {
    var result = Set<Int>()
    let effectiveScopes = scopes ?? [Array(0..<max(count, 0))]
    for scope in effectiveScopes {
        var seen = Set<String>()
        for i in scope {
            guard i >= 0, i < count else { continue }
            let title = titleOf(i).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            if !seen.insert(title).inserted {
                result.insert(i)
            }
        }
    }
    return result
}

/// 从 from 出发按 step 步进到达的第一个未隐藏章节（0 基）；不可达返回 nil。
/// 第一步允许离开 from 所在组（与普通 ±1 一致）；落点隐藏时继续步进，
/// 但只在 from 自己的组内搜索——跨组是调用方单独守卫的一步，
/// 越过它搜索会绕过组边界守卫、把读者丢在组中间。
public func nextVisibleChapter(
    from: Int,
    step: Int,
    chapterCount: Int,
    isHidden: (Int) -> Bool,
    groupOf: (Int) -> Int
) -> Int? {
    guard step != 0, from >= 0, from < chapterCount else { return nil }
    func valid(_ c: Int) -> Bool { c >= 0 && c < chapterCount }
    var c = from + step
    guard valid(c) else { return nil }
    if !isHidden(c) { return c }
    let group = groupOf(from)
    repeat {
        c += step
        guard valid(c), groupOf(c) == group else { return nil }
    } while isHidden(c)
    return c
}

/// 每部漫画「隐藏重复章节」开关（对齐原版 ChapterDuplicatePrefs）。
/// 设备本地（implicitData，不随备份同步）：它只改变一部漫画章节列表的
/// 渲染方式，所有消费方都以平铺索引为准，关闭该开关的设备读到的
/// 章节与下载完全相同。
public enum ChapterDuplicatePrefs {
    static let prefKey = "hideDuplicateChapters"

    public static func isHidden(comicId: String, sourceKey: String) -> Bool {
        let stored = AppData.shared.implicitValue(prefKey)
        guard let map = stored.objectValue else { return false }
        return map["\(comicId)@\(sourceKey)"]?.boolValue == true
    }

    public static func setHidden(_ value: Bool, comicId: String, sourceKey: String) {
        let stored = AppData.shared.implicitValue(prefKey)
        var map = stored.objectValue ?? [:]
        let comicKey = "\(comicId)@\(sourceKey)"
        if value {
            map[comicKey] = .bool(true)
        } else {
            map[comicKey] = nil
        }
        AppData.shared.setImplicitValue(prefKey, .object(map))
    }
}

extension ComicChapters {
    /// 标题在本组内重复出现的章节的平铺 0 基索引。组刻意保持独立：
    /// 不同版本（"English"、"Español"）各自合法地携带「第一话」。
    public func duplicateTitleIndices() -> Set<Int> {
        let all = titles
        var scopes: [[Int]]?
        if let groupEntries {
            var built: [[Int]] = []
            var flat = 0
            for group in groupEntries {
                built.append(Array(flat..<(flat + group.chapters.count)))
                flat += group.chapters.count
            }
            scopes = built
        }
        return findDuplicateTitleIndices(
            count: all.count,
            titleOf: { all[$0] },
            scopes: scopes
        )
    }

    /// 平铺索引 → 组序号（未分组恒为 0；越界返回 -1，永不与组合法值相等）。
    public func groupOfChapter(_ flatIndex: Int) -> Int {
        guard let groupEntries else { return 0 }
        var flat = 0
        for (g, group) in groupEntries.enumerated() {
            let size = group.chapters.count
            if flatIndex >= flat, flatIndex < flat + size { return g }
            flat += size
        }
        return -1
    }
}
