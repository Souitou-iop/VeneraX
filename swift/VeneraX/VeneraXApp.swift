import SwiftUI
import VeneraKit

@main
struct VeneraXApp: App {
    @State private var appState = AppState.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .tint(ThemeStore.shared.accent)
                .preferredColorScheme(ThemeStore.shared.preferredColorScheme)
                .onOpenURL { url in
                    // Defer routing until boot/migration/lock gates have settled.
                    appState.pendingExternalURL = url
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .active {
                Task.detached {
                    DataSync.shared.settlePendingChanges()
                }
            }
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var appState
    @State private var services = AppServices.shared

    var body: some View {
        Group {
            switch appState.phase {
            case .loading:
                ProgressView()
                    .task {
                        await appState.initialize()
                    }
            case .main:
                if appState.needsMigration {
                    MigrationWizard()
                } else if appState.isLocked {
                    AppLockView { appState.isLocked = false }
                } else {
                    MainTabView()
                        .overlay { AppOverlays() }
                        .modifier(ReaderAutoLaunchModifier())
                        .task(id: appState.pendingExternalURL) {
                            await handleExternalURL()
                        }
                        .task {
                            // Only boot runtime-backed services for the actual app UI.
                            // Migration and lock screens must not start the heavy JS path.
                            await Task.yield()
                            await services.boot()
                        }
                }
            }
        }
        .alert(
            "Boot Error".tl,
            isPresented: Binding(
                get: { services.bootError != nil },
                set: { if !$0 { services.bootError = nil } }
            )
        ) {
            Button("OK".tl) {}
        } message: {
            Text(verbatim: services.bootError ?? "")
        }
    }

    @MainActor
    private func handleExternalURL() async {
        guard let url = appState.pendingExternalURL else { return }
        appState.pendingExternalURL = nil
        guard let route = await AppLinksHandler.parse(url: url) else {
            AppServices.shared.showMessage("Unsupported link".tl)
            return
        }
        switch route {
        case .comic(let sourceKey, let id):
            guard let source = ComicSourceManager.shared.find(sourceKey) else {
                AppServices.shared.showMessage("Comic source not found".tl)
                return
            }
            do {
                let details = try await source.loadComicInfo(id: id)
                appState.autoOpenReader = ReaderAutoLaunch(
                    comic: Comic(
                        id: details.id,
                        title: details.title,
                        cover: details.cover,
                        subtitle: details.subtitle,
                        tags: details.tags.values.flatMap { $0 },
                        description: details.description,
                        sourceKey: sourceKey,
                        maxPage: details.maxPage,
                        stars: details.stars
                    ),
                    sourceKey: sourceKey,
                    epIndex: 0,
                    chapters: details.chapters
                )
            } catch {
                AppServices.shared.showMessage("Unable to open comic: \(error.localizedDescription)")
            }
        case .installSource(let scriptURL):
            let response = await HTTPClient.shared.request(method: "GET", url: scriptURL)
            guard let js = String(data: response.body, encoding: .utf8), !js.isEmpty else {
                AppServices.shared.showMessage("Source download failed".tl)
                return
            }
            let fileName = URL(string: scriptURL)?.lastPathComponent ?? "source.js"
            do {
                _ = try await ComicSourceManager.shared.install(js: js, fileName: fileName)
                AppServices.shared.showMessage("Source installed from link".tl)
            } catch {
                AppServices.shared.showMessage("Source installation failed: \(error.localizedDescription)")
            }
        case .syncConfig(let url, let user, let pass):
            AppData.shared.settings["webdav"] = .array([.string(url), .string(user), .string(pass)])
            AppData.shared.saveData(sync: false)
            AppServices.shared.showMessage("Sync config imported".tl)
        }
    }
}
