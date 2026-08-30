import Foundation

/// 分类页数据（对齐 category.dart 的 FixedCategoryPart）：
/// `category = { title, enableRankingPage, parts: [{ name, type: "fixed",
/// categories: [...], categoryParams: [...] }] }`。
public struct SourceCategoryData: Sendable {
    public struct Part: Sendable {
        public var name: String
        public var categories: [String]
        /// 与 categories 一一对应的参数（缺省用分类名本身）。
        public var categoryParams: [String]?

        public func param(at index: Int) -> String {
            if let categoryParams, categoryParams.indices.contains(index) {
                return categoryParams[index]
            }
            return categories[index]
        }
    }

    public var title: String
    /// 分类页键（category.key，用于可见页列表；缺省回落 title）。
    public var key: String
    public var parts: [Part]
    public var enableRankingPage: Bool

    public static func parse(_ json: JSON) -> SourceCategoryData? {
        guard let object = json.objectValue else { return nil }
        let title = object["title"]?.stringValue ?? ""
        let key = object["key"]?.stringValue ?? title
        var parts: [Part] = []
        if let rawParts = object["parts"]?.arrayValue {
            for raw in rawParts {
                let type = raw["type"].stringValue ?? "fixed"
                guard type == "fixed" else { continue } // dynamic 部分后续里程碑
                let categories = raw["categories"].arrayValue?.compactMap { $0.stringValue } ?? []
                guard !categories.isEmpty else { continue }
                let params = raw["categoryParams"].arrayValue?.compactMap { $0.stringValue }
                parts.append(Part(
                    name: raw["name"].stringValue ?? "",
                    categories: categories,
                    categoryParams: (params?.count == categories.count) ? params : nil
                ))
            }
        }
        guard !parts.isEmpty else { return nil }
        return SourceCategoryData(
            title: title,
            key: key,
            parts: parts,
            enableRankingPage: object["enableRankingPage"]?.boolValue ?? false
        )
    }
}
