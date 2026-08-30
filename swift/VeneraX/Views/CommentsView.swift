import SwiftUI
import VeneraKit

/// 评论页：分页加载、楼中楼（回复指定评论）、发送评论，支持关键词过滤屏蔽。
struct CommentsView: View {
    let details: ComicDetails

    @State private var comments: [Comment] = []
    @State private var currentPage = 1
    @State private var maxPage: Int?
    @State private var replyTo: Comment?
    @State private var draft = ""
    @State private var isLoading = false
    @State private var error: String?

    private var source: ComicSource? {
        ComicSourceManager.shared.find(details.sourceKey)
    }

    var body: some View {
        List {
            if let replyTo {
                Section {
                    HStack {
                        Label {
                            Text(verbatim: "Replying to \(replyTo.userName)".tl)
                                .font(.footnote)
                        } icon: {
                            Image(systemName: "arrowshape.turn.up.left")
                        }
                        Spacer()
                        Button("Cancel".tl) { self.replyTo = nil }
                            .font(.caption)
                    }
                }
            }
            ForEach(Array(comments.enumerated()), id: \.offset) { _, comment in
                commentRow(comment)
            }
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            if let error {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle("Comments".tl)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            inputBar
        }
        .task {
            if comments.isEmpty {
                await loadNextPage()
            }
        }
    }

    private func commentRow(_ comment: Comment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let avatar = comment.avatar, let url = URL(string: avatar) {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Circle().fill(.quaternary)
                    }
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
                }
                Text(verbatim: comment.userName)
                    .font(.footnote.weight(.medium))
                Spacer()
                if let score = comment.score {
                    Text(verbatim: String(format: "%.1f", score / 2))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Text(verbatim: comment.content)
                .font(.subheadline)
            HStack {
                if let time = comment.time {
                    Text(verbatim: time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let replyCount = comment.replyCount, replyCount > 0 {
                    Button("\(replyCount) replies".tl) {
                        replyTo = comment
                        Task { await loadReplies(comment) }
                    }
                    .font(.caption2)
                }
                Button {
                    replyTo = comment
                } label: {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
            }
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .onAppear {
            if comment.id == comments.last?.id {
                Task { await loadNextPage() }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Write a comment".tl, text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            Button {
                Task { await send() }
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var subId: String {
        details.subId ?? details.id
    }

    private func loadNextPage() async {
        guard let source, !isLoading else { return }
        if let maxPage, currentPage > maxPage { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (pageComments, pageMax) = try await source.loadComments(subId: subId, page: currentPage, replyTo: nil)
            let filtered = BlockListFilter.filterComments(pageComments)
            comments.append(contentsOf: filtered)
            maxPage = pageMax ?? maxPage
            if pageComments.isEmpty { maxPage = currentPage - 1 < 1 ? 1 : currentPage - 1 }
            currentPage += 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadReplies(_ comment: Comment) async {
        guard let source else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            comments = []
            currentPage = 1
            maxPage = nil
            let (replies, _) = try await source.loadComments(subId: subId, page: 1, replyTo: comment.id)
            comments = BlockListFilter.filterComments(replies)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func send() async {
        guard let source else { return }
        let content = draft
        draft = ""
        do {
            try await source.sendComment(subId: subId, content: content, replyTo: replyTo?.id)
            replyTo = nil
            comments = []
            currentPage = 1
            maxPage = nil
            await loadNextPage()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 阅读器章节评论：复用评论过滤、分页和回复交互，但调用源的章节评论 API。
struct ChapterCommentsView: View {
    let comicID: String
    let epID: String
    let comicTitle: String
    let chapterTitle: String
    let source: ComicSource

    @State private var comments: [Comment] = []
    @State private var currentPage = 1
    @State private var maxPage: Int?
    @State private var replyTo: Comment?
    @State private var draft = ""
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: comicTitle).font(.headline)
                    Text(verbatim: chapterTitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let replyTo {
                Section {
                    HStack {
                        Label("Replying to \(replyTo.userName)".tl, systemImage: "arrowshape.turn.up.left")
                        Spacer()
                        Button("Cancel".tl) { self.replyTo = nil }
                            .font(.caption)
                    }
                }
            }
            ForEach(Array(comments.enumerated()), id: \.offset) { index, comment in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(verbatim: comment.userName).font(.footnote.weight(.medium))
                        Spacer()
                        if let time = comment.time {
                            Text(verbatim: time).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Text(verbatim: comment.content).font(.subheadline)
                    if let replyCount = comment.replyCount, replyCount > 0 {
                        Button("Replies (\(replyCount))".tl) { replyTo = comment }
                            .font(.caption)
                    }
                }
                .padding(.vertical, 4)
                .onAppear {
                    guard index == comments.count - 1 else { return }
                    Task { await loadNextPage() }
                }
                .contextMenu {
                    Button("Reply".tl) { replyTo = comment }
                }
            }
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            if let error {
                Text(verbatim: error).font(.caption).foregroundStyle(.red)
            }
        }
        .navigationTitle("Chapter Comments".tl)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { inputBar }
        .task {
            if comments.isEmpty { await loadNextPage() }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Comment".tl, text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            Button {
                Task { await send() }
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func loadNextPage() async {
        guard !isLoading else { return }
        if let maxPage, currentPage > maxPage { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await source.loadChapterComments(
                comicId: comicID,
                epId: epID,
                page: currentPage,
                replyTo: replyTo?.id
            )
            let filtered = BlockListFilter.filterComments(result.comments)
            comments.append(contentsOf: filtered)
            maxPage = result.maxPage
            currentPage += 1
            if result.comments.isEmpty { maxPage = currentPage - 1 }
            error = nil
        } catch let caughtError {
            error = caughtError.localizedDescription
        }
    }

    private func send() async {
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        do {
            try await source.sendChapterComment(comicId: comicID, epId: epID, content: content, replyTo: replyTo?.id)
            draft = ""
            replyTo = nil
            comments = []
            currentPage = 1
            maxPage = nil
            await loadNextPage()
        } catch let caughtError {
            error = caughtError.localizedDescription
        }
    }
}
