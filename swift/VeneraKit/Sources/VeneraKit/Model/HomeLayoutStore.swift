import Foundation

public struct HomeSectionItem: Equatable, Sendable, Identifiable {
    public let id: String
    public let titleKey: String
    public let systemIcon: String
    public var visible: Bool

    public init(id: String, titleKey: String, systemIcon: String, visible: Bool = true) {
        self.id = id
        self.titleKey = titleKey
        self.systemIcon = systemIcon
        self.visible = visible
    }
}

/// 首页区块编排管理器（对齐原版 home_layout.dart）。
public enum HomeLayoutStore {
    public static let defaultSections: [HomeSectionItem] = [
        HomeSectionItem(id: "history", titleKey: "Continue Reading", systemIcon: "clock.arrow.circlepath"),
        HomeSectionItem(id: "readLater", titleKey: "Read Later", systemIcon: "clock"),
        HomeSectionItem(id: "local", titleKey: "Local Comics", systemIcon: "folder.fill"),
        HomeSectionItem(id: "followUpdates", titleKey: "Follow Updates", systemIcon: "bell.badge.fill"),
        HomeSectionItem(id: "collections", titleKey: "Collections", systemIcon: "square.stack.3d.down.right"),
        HomeSectionItem(id: "imageFavorites", titleKey: "Image Favorites", systemIcon: "photo.on.rectangle.angled"),
        HomeSectionItem(id: "tasks", titleKey: "Task Center", systemIcon: "checklist"),
        HomeSectionItem(id: "randomDraw", titleKey: "Random Draw", systemIcon: "dice.fill"),
        HomeSectionItem(id: "statistics", titleKey: "Reading Statistics", systemIcon: "chart.bar.xaxis"),
    ]

    public static func loadSections() -> [HomeSectionItem] {
        let raw = AppData.shared.settings["homeSections"].arrayValue ?? []
        var result: [HomeSectionItem] = []
        var seen = Set<String>()

        for item in raw {
            guard let id = item["id"].stringValue,
                  let meta = defaultSections.first(where: { $0.id == id }) else { continue }
            if seen.insert(id).inserted {
                let vis = item["visible"].boolValue ?? true
                result.append(HomeSectionItem(id: id, titleKey: meta.titleKey, systemIcon: meta.systemIcon, visible: vis))
            }
        }

        for def in defaultSections {
            if !seen.contains(def.id) {
                result.append(def)
            }
        }
        return result
    }

    public static func saveSections(_ sections: [HomeSectionItem]) {
        let jsonArray = sections.map { item in
            JSON.object([
                "id": .string(item.id),
                "visible": .bool(item.visible),
            ])
        }
        AppData.shared.settings["homeSections"] = .array(jsonArray)
        AppData.shared.saveData(sync: true)
    }
}
