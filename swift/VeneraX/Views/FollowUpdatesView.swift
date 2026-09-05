import SwiftUI
import VeneraKit

/// 追更列表页面（对齐原版 follow_updates_page.dart）。
/// 集中展示追更范围内有更新的漫画，支持手动触发检查、范围与周期设置、
/// 标记已读。
struct FollowUpdatesView: View {
    @State private var updatedComics: [(folder: String, item: FavoriteItem)] = []
    @State private var isChecking = false
    @State private var progressText = ""
    @State private var checkTask: Task<Void, Never>?
    @State private var showSettings = false

    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Follow Updates".tl)
                            .font(.headline)
                        Text(isChecking ? progressText : "\(updatedComics.count) updated comics".tl)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isChecking {
                        ProgressView()
                    } else {
                        Button {
                            checkUpdates()
                        } label: {
                            Label("Check Now".tl, systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            }

            if updatedComics.isEmpty && !isChecking {
                if !FollowUpdateScope.isConfigured {
                    ContentUnavailableView {
                        Label("Follow Updates".tl, systemImage: "bell.slash")
                    } description: {
                        Text("Choose which favorite folders to track in settings".tl)
                    }
                } else {
                    ContentUnavailableView {
                        Label("No updates".tl, systemImage: "bell.slash")
                    } description: {
                        Text("Comics with new chapters will appear here".tl)
                    }
                }
            } else {
                Section("Updated Comics".tl) {
                    ForEach(updatedComics, id: \.item.id) { pair in
                        NavigationLink(value: ComicTarget.details(FavoriteItemBridge.comic(from: pair.item))) {
                            HStack(spacing: 12) {
                                ComicCover(url: pair.item.coverPath)
                                    .frame(width: 48, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(verbatim: pair.item.name)
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                            .lineLimit(1)
                                        Spacer()
                                        Text("NEW".tl)
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(.red, in: Capsule())
                                    }

                                    if !pair.item.author.isEmpty {
                                        Text(verbatim: pair.item.author)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    HStack {
                                        Text(verbatim: pair.folder)
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.quaternary, in: Capsule())

                                        if let lastUpdate = pair.item.lastUpdateTime, !lastUpdate.isEmpty {
                                            Text(verbatim: lastUpdate)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                FollowUpdatesManager.shared.markComicRead(
                                    id: pair.item.id,
                                    type: pair.item.type,
                                    folder: pair.folder
                                )
                                reload()
                            } label: {
                                Label("Mark Read".tl, systemImage: "checkmark.circle")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
        }
        .navigationTitle("Updates".tl)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            // 空状态分支读取 FollowUpdateScope.isConfigured（非观察对象），
            // 关闭设置表后必须主动触发一次 body 重算。
            reload()
        }) {
            FollowUpdatesSettingsSheet()
                .presentationDetents([.medium, .large])
        }
        .onAppear(perform: reload)
        .onDisappear {
            checkTask?.cancel()
            checkTask = nil
        }
    }

    private func reload() {
        updatedComics = FollowUpdatesManager.shared.getAllUpdatedComics()
    }

    private func checkUpdates() {
        // 与上游一致：范围未配置时先打开设置，而不是空跑一次检查。
        guard FollowUpdateScope.isConfigured else {
            showSettings = true
            return
        }
        guard checkTask == nil else { return }
        checkTask = Task { @MainActor in
            isChecking = true
            progressText = "Checking updates...".tl
            defer {
                isChecking = false
                checkTask = nil
            }
            await FollowUpdatesManager.shared.checkAllFolders(force: true)
            guard !Task.isCancelled else { return }
            reload()
        }
    }
}

/// 追更范围与周期设置（对齐上游 follow_updates_page 的设置对话框）。
/// 所有选项在确认时统一应用。
private struct FollowUpdatesSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var allFolders = FollowUpdateScope.allFolders
    @State private var selected: Set<String> = Set(FollowUpdateScope.selected)
    @State private var intervalHours = FollowUpdateScope.intervalHours
    @State private var checkOnStart = FollowUpdateScope.checkOnStart
    @State private var hasFixedTime = !FollowUpdateScope.fixedTime.isEmpty
    @State private var fixedTime: Date = {
        let fallback = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
        guard let time = FollowUpdateScope.parseFixedTime(FollowUpdateScope.fixedTime) else { return fallback }
        return Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? fallback
    }()
    @State private var existingFolders: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("All favorite folders".tl, isOn: $allFolders)
                    if !allFolders {
                        if existingFolders.isEmpty {
                            Text("No folders to select".tl)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(existingFolders, id: \.self) { folder in
                            Button {
                                if selected.contains(folder) {
                                    selected.remove(folder)
                                } else {
                                    selected.insert(folder)
                                }
                            } label: {
                                HStack {
                                    Text(verbatim: folder)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selected.contains(folder) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Folders to check".tl)
                } footer: {
                    Text("All folders also covers folders created later. The scope is stored on this device only.".tl)
                }

                Section {
                    Picker("Check interval".tl, selection: $intervalHours) {
                        ForEach(FollowUpdateScope.intervalOptions, id: \.self) { hours in
                            Text(intervalLabel(hours)).tag(hours)
                        }
                    }
                    Toggle("Check on app start".tl, isOn: $checkOnStart)
                    Toggle("Check daily at fixed time".tl, isOn: $hasFixedTime)
                    if hasFixedTime {
                        DatePicker("Check time".tl, selection: $fixedTime, displayedComponents: .hourAndMinute)
                    }
                } header: {
                    Text("Schedule".tl)
                } footer: {
                    Text("Each comic is re-checked only after this interval has passed since its last check.".tl)
                }
            }
            .navigationTitle("Follow Updates".tl)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel".tl) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save".tl) { apply() }
                }
            }
            .onAppear {
                existingFolders = LocalFavoritesManager.shared.getFolders()
            }
        }
    }

    private func apply() {
        let fixedTimeString = hasFixedTime
            ? Self.timeFormatter.string(from: fixedTime)
            : ""
        FollowUpdateScope.save(
            allFolders: allFolders,
            folders: allFolders ? [] : existingFolders.filter { selected.contains($0) }
        )
        FollowUpdateScope.saveSchedule(
            intervalHours: intervalHours,
            checkOnStart: checkOnStart,
            fixedTime: fixedTimeString
        )
        dismiss()
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private func intervalLabel(_ hours: Int) -> String {
        hours == 1
            ? "Every hour".tl
            : "Every @a hours".tl.replacingOccurrences(of: "@a", with: String(hours))
    }
}

/// 任务中心卡片用的范围摘要（无收藏夹 / 单个名称 / N 个收藏夹）。
func followUpdateFolderLabel(_ folders: [String]?) -> String {
    guard let folders, !folders.isEmpty else {
        return "No folder selected".tl
    }
    if folders.count == 1 {
        return folders[0]
    }
    return "@a folders".tl.replacingOccurrences(of: "@a", with: String(folders.count))
}
