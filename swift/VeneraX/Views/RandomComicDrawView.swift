import SwiftUI
import VeneraKit

/// 随机抽漫画弹窗（对齐原版 random_comic_draw_dialog.dart）。
/// 支持按收藏夹/阅读状态筛选候选池，带卡牌翻转动效与直接开读。
struct RandomComicDrawView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [String] = []
    @State private var selectedFolder: String? = nil
    @State private var candidates: [FavoriteItem] = []
    @State private var drawnComic: FavoriteItem?
    @State private var drawnComicIDs: Set<ComicID> = []
    @State private var isDrawing = false
    @State private var cardFlipped = false
    @State private var navigateToComic: Comic?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                scopePicker

                Spacer()

                cardArea

                Spacer()

                actionButtons
            }
            .padding(20)
            .navigationTitle("Random Draw".tl)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close".tl) { dismiss() }
                }
            }
            .navigationDestination(item: $navigateToComic) { comic in
                ComicDetailsView(comic: comic)
            }
            .onAppear(perform: loadCandidates)
            .onChange(of: selectedFolder) { _, _ in loadCandidates() }
        }
    }

    private var scopePicker: some View {
        HStack {
            Text("Pool".tl)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("Folder".tl, selection: $selectedFolder) {
                Text("All Favorites".tl).tag(Optional<String>.none)
                ForEach(folders, id: \.self) { f in
                    Text(f).tag(Optional(f))
                }
            }
            .pickerStyle(.menu)

            Spacer()

            Text("\(candidates.count) candidates".tl)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var cardArea: some View {
        ZStack {
            // 卡牌背面（未抽中）
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors: [.purple.opacity(0.8), .blue.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 220, height: 310)
                .overlay {
                    VStack(spacing: 12) {
                        Image(systemName: "dice.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.white)
                        Text("Tap Draw".tl)
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                }
                .shadow(radius: 8)
                .opacity(cardFlipped ? 0 : 1)
                .rotation3DEffect(.degrees(cardFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))

            // 卡牌正面（已抽中）
            if let comic = drawnComic {
                VStack(spacing: 10) {
                    ComicCover(url: comic.coverPath)
                        .frame(width: 170, height: 230)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Text(verbatim: comic.name)
                        .font(.headline)
                        .lineLimit(1)

                    if !comic.author.isEmpty {
                        Text(verbatim: comic.author)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: 220, height: 310)
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 8)
                .opacity(cardFlipped ? 1 : 0)
                .rotation3DEffect(.degrees(cardFlipped ? 0 : -180), axis: (x: 0, y: 1, z: 0))
            }
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.7), value: cardFlipped)
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            if cardFlipped, let comic = drawnComic {
                HStack(spacing: 16) {
                    Button {
                        performDraw()
                    } label: {
                        Label("Draw Again".tl, systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button {
                        navigateToComic = FavoriteItemBridge.comic(from: comic)
                    } label: {
                        Label("Read Now".tl, systemImage: "book.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            } else {
                Button {
                    performDraw()
                } label: {
                    Label(isDrawing ? "Drawing...".tl : "Draw Comic".tl, systemImage: "dice.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(candidates.isEmpty || isDrawing)
            }
        }
    }

    private func loadCandidates() {
        folders = LocalFavoritesManager.shared.getFoldersSorted()
        if let folder = selectedFolder {
            candidates = LocalFavoritesManager.shared.getComics(folder)
        } else {
            var all: [FavoriteItem] = []
            for f in folders {
                all.append(contentsOf: LocalFavoritesManager.shared.getComics(f))
            }
            // 依据 ID 去重
            var seen = Set<String>()
            candidates = all.filter { seen.insert("\($0.type):\($0.id)").inserted }
        }
        drawnComic = nil
        drawnComicIDs.removeAll()
        cardFlipped = false
    }

    private func performDraw() {
        guard !candidates.isEmpty else { return }
        isDrawing = true
        cardFlipped = false

        let feedback = UIImpactFeedbackGenerator(style: .medium)
        feedback.impactOccurred()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            // 与原版一致：一轮内不重复；候选池耗尽后自动开始下一轮。
            if drawnComicIDs.count >= candidates.count {
                drawnComicIDs.removeAll()
            }
            guard let comic = UniformRandomComicPicker().pick(candidates, excluding: drawnComicIDs) else {
                isDrawing = false
                return
            }
            drawnComic = comic
            drawnComicIDs.insert(comic.comicID)
            cardFlipped = true
            isDrawing = false
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}
