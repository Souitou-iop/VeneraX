import Foundation

/// 屏蔽规则过滤器（对齐原版 explore_settings.dart 与 comic_state_repository.dart 中的屏蔽系统）。
/// 支持：
/// 1. 标题/副标题/简介关键字屏蔽 (`blockedWords`)
/// 2. 漫画标签屏蔽 (`blockedTags`，支持原文与翻译后标签双向匹配)
/// 3. 评论关键字屏蔽 (`blockedCommentWords`)
public enum BlockListFilter {

    /// 检查一部漫画是否应当被屏蔽。
    public static func isComicBlocked(_ comic: Comic) -> Bool {
        let settings = AppData.shared.settings

        // 1. 关键字屏蔽 (blockedWords)
        let blockedWords = settings["blockedWords"].arrayValue?.compactMap { $0.stringValue?.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
        if !blockedWords.isEmpty {
            let lowerTitle = comic.title.lowercased()
            let lowerSubtitle = comic.subtitle.lowercased()
            let lowerDesc = comic.description.lowercased()

            for word in blockedWords {
                if lowerTitle.contains(word) || lowerSubtitle.contains(word) || lowerDesc.contains(word) {
                    return true
                }
            }
        }

        // 2. 标签屏蔽 (blockedTags)
        let blockedTags = settings["blockedTags"].arrayValue?.compactMap { $0.stringValue?.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
        if !blockedTags.isEmpty {
            for tag in comic.tags {
                let lowerTag = tag.lowercased()
                let translatedTag = TagTranslator.shared.translate(tag).lowercased()
                for blocked in blockedTags {
                    if lowerTag.contains(blocked) || translatedTag.contains(blocked) {
                        return true
                    }
                }
            }
        }

        return false
    }

    /// 过滤漫画列表。
    public static func filterComics(_ comics: [Comic]) -> [Comic] {
        comics.filter { !isComicBlocked($0) }
    }

    /// 检查一条评论是否应当被屏蔽。
    public static func isCommentBlocked(_ content: String) -> Bool {
        let blockedComments = AppData.shared.settings["blockedCommentWords"].arrayValue?.compactMap { $0.stringValue?.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
        guard !blockedComments.isEmpty else { return false }
        let lowerContent = content.lowercased()
        for word in blockedComments {
            if lowerContent.contains(word) {
                return true
            }
        }
        return false
    }

    /// 过滤评论列表。
    public static func filterComments(_ comments: [Comment]) -> [Comment] {
        comments.filter { !isCommentBlocked($0.content) }
    }
}
