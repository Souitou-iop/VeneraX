import Foundation
import VeneraKit

/// 自测模式：`simctl launch <dev> <bundle> -venerax-selftest` 触发。
/// 自动执行 源加载→探索→搜索→详情→章节→图片 全链路，
/// 结果写入 Application Support/selftest-result.json。
@MainActor
enum SelfTest {
    static func shouldRun() -> Bool {
        ProcessInfo.processInfo.arguments.contains("-venerax-selftest")
    }

    static func run() async {
        var results: [String: Any] = [:]
        var steps: [[String: Any]] = []

        func record(_ name: String, _ ok: Bool, _ detail: String = "") {
            steps.append(["step": name, "ok": ok, "detail": detail])
            Log.info("SelfTest", "\(ok ? "PASS" : "FAIL") \(name) \(detail)")
        }

        let source = ComicSourceManager.shared.find("Komiic")
        record("source-loaded", source != nil, source?.version ?? "nil")

        // 数据层 UI 验证：写入历史与收藏（供主界面渲染检查）
        let type = ComicID.forSource("Komiic")
        HistoryManager.shared.addHistory(History(
            id: "30055", type: type, title: "葬送的芙莉蓮", subtitle: "山田鐘人",
            cover: "https://public.komiic.com/bd/30055.jpg", ep: 2, page: 15, maxPage: 40
        ))
        LocalFavoritesManager.shared.addFolder("追更")
        LocalFavoritesManager.shared.addFavorite("追更", FavoriteItem(
            id: "30055", name: "葬送的芙莉蓮", coverPath: "https://public.komiic.com/bd/30055.jpg",
            author: "山田鐘人", type: type, tags: ["奇幻"]
        ))
        record("data-write", true, "history + favorite written")

        if let source {
            do {
                let explore = try await source.loadExplorePage(0, page: 1)
                record("explore", explore.comics.count > 0, "\(explore.comics.count) comics, first=\(explore.comics.first?.title ?? "-")")
                if let comic = explore.comics.first {
                    do {
                        let details = try await source.loadComicInfo(id: comic.id)
                        record("details", !details.title.isEmpty, "title=\(details.title), chapters=\(details.chapters?.ids.count ?? 0)")
                        if details.chapters?.ids.isEmpty == false {
                            let epId = details.chapters?.ids.first
                            let pages = try await source.loadComicPages(id: comic.id, ep: epId)
                            record("pages", pages.count > 0, "\(pages.count) images")
                            if let first = pages.first {
                                let data = await ImageDownloader.shared.load(
                                    imageKey: first, sourceKey: "Komiic",
                                    cid: comic.id, eid: epId ?? "", source: source
                                )
                                record("image", (data?.count ?? 0) > 1000, "\(data?.count ?? 0) bytes")
                            }
                        }
                        let search = try await source.search(keyword: "芙莉蓮", page: 1, options: [:])
                        record("search", search.comics.count > 0, "\(search.comics.count) results")
                    } catch {
                        record("details-flow", false, error.localizedDescription)
                    }
                }
            } catch {
                record("explore", false, error.localizedDescription)
            }
        }

        // 自动打开阅读器（供无头截图验证：Tab 栏隐藏 + 图片 contain）
        if let source {
            do {
                let explore = try await source.loadExplorePage(0, page: 1)
                if let comic = explore.comics.first {
                    let details = try await source.loadComicInfo(id: comic.id)
                    await MainActor.run {
                        AppState.shared.autoOpenReader = ReaderAutoLaunch(
                            comic: comic,
                            sourceKey: source.key,
                            epIndex: 0,
                            chapters: details.chapters
                        )
                    }
                }
            } catch {
                Log.info("SelfTest", "auto-open reader failed: \(error)")
            }
        }

        results["steps"] = steps
        results["allPassed"] = steps.allSatisfy { ($0["ok"] as? Bool) ?? false }
        results["timestamp"] = Date().timeIntervalSince1970
        if let json = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted]) {
            let path = AppPaths.join(AppPaths.dataPath, "selftest-result.json")
            try? json.write(to: URL(fileURLWithPath: path))
            Log.info("SelfTest", "Result written to \(path)")
        }
    }
}
