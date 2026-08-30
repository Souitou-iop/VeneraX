import SwiftUI
import VeneraKit

/// 自测用：阅读器启动参数。
struct ReaderAutoLaunch: Identifiable {
    let id = UUID()
    let comic: Comic
    let sourceKey: String
    let epIndex: Int
    let chapters: ComicChapters?
}

/// 全屏呈现（覆盖 Tab 栏），由 RootView 挂载。
struct ReaderAutoLaunchModifier: ViewModifier {
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content.fullScreenCover(item: Binding(
            get: { appState.autoOpenReader },
            set: { if $0 == nil { appState.autoOpenReader = nil } }
        )) { launch in
            ReaderView(
                comic: launch.comic,
                source: ComicSourceManager.shared.find(launch.sourceKey),
                epIndex: launch.epIndex,
                chapters: launch.chapters
            )
        }
    }
}
