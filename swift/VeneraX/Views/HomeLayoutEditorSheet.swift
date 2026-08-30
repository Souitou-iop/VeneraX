import SwiftUI
import VeneraKit

/// 首页区块编排设置面板（对齐原版 settings/home_layout.dart）。
/// 允许用户拖拽重排首页展示区块与开启/隐藏特定分区。
struct HomeLayoutEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sections: [HomeSectionItem] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Customizable Sections".tl) {
                    ForEach($sections) { $item in
                        HStack {
                            Label(item.titleKey.tl, systemImage: item.systemIcon)
                            Spacer()
                            Toggle("", isOn: $item.visible)
                                .labelsHidden()
                        }
                    }
                    .onMove { from, to in
                        sections.move(fromOffsets: from, toOffset: to)
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Home Layout".tl)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel".tl) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done".tl) {
                        HomeLayoutStore.saveSections(sections)
                        dismiss()
                    }
                }
            }
            .onAppear {
                sections = HomeLayoutStore.loadSections()
            }
        }
    }
}
