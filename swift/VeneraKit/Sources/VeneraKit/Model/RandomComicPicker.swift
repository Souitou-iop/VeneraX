import Foundation

/// 负责从收藏候选池中均匀抽取漫画。
/// 同一轮抽取会排除已经出现过的漫画，候选池耗尽后由调用方开启新一轮。
public struct UniformRandomComicPicker: Sendable {
    public init() {}

    public func pick(
        _ candidates: [FavoriteItem],
        excluding excluded: Set<ComicID> = []
    ) -> FavoriteItem? {
        let eligible = candidates.filter { !excluded.contains($0.comicID) }
        guard !eligible.isEmpty else { return nil }
        return eligible[Int.random(in: 0..<eligible.count)]
    }
}
