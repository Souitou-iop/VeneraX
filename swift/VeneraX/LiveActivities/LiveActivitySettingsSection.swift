import ActivityKit
import SwiftUI
import VeneraKit

struct LiveActivitySettingsSection: View {
    @AppStorage(LiveActivityCoordinator.enabledKey) private var enabled = true
    @AppStorage(LiveActivityCoordinator.detailsKey) private var showDetails = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var systemEnabled = ActivityAuthorizationInfo().areActivitiesEnabled

    var body: some View {
        Section {
            Toggle("Live Activities".tl, isOn: $enabled)
            Toggle("Show comic titles and covers".tl, isOn: $showDetails)
                .disabled(!enabled)
            if !systemEnabled {
                Label("Live Activities are disabled in system settings".tl, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Settings".tl) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        } header: {
            Text("Live Activities".tl)
        } footer: {
            Text("Task progress only by default. Titles and covers may be visible on the Lock Screen. Live Activities do not extend background execution.".tl)
        }
        .onChange(of: enabled) { _, _ in LiveActivityCoordinator.shared.settingsChanged() }
        .onChange(of: showDetails) { _, _ in LiveActivityCoordinator.shared.settingsChanged() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { systemEnabled = ActivityAuthorizationInfo().areActivitiesEnabled }
        }
        .task {
            for await value in ActivityAuthorizationInfo().activityEnablementUpdates {
                if Task.isCancelled { return }
                systemEnabled = value
            }
        }
    }
}
