import SwiftUI
import Charts
import VeneraKit

/// 阅读统计页面（对齐原版 reading_statistics_page.dart）。
/// 展示今日/近7天/累计阅读时长、近7天阅读趋势图表及近30天阅读漫画分布。
struct ReadingStatisticsView: View {
    @State private var summary: ReadingStatisticsSummary = ReadingStatisticsSummary()
    @State private var sortType: ReadingSort = .lastRead
    @State private var showClearConfirm = false

    enum ReadingSort: String, CaseIterable {
        case lastRead
        case durationDesc
        case durationAsc
        case nameAsc
        case nameDesc
    }

    var body: some View {
        List {
            Section {
                summaryCards
            }

            if summary.total > 0 {
                Section("Last 7 Days Trend".tl) {
                    trendChart
                }

                Section("Comics Read in Last 30 Days".tl) {
                    if sortedComics.isEmpty {
                        Text("No comics read in the last 30 days".tl)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sortedComics) { item in
                            NavigationLink(value: ComicTarget.details(item.toComic())) {
                                HStack(spacing: 12) {
                                    ComicCover(url: item.cover)
                                        .frame(width: 44, height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(verbatim: item.title)
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                            .lineLimit(1)

                                        if !item.subtitle.isEmpty {
                                            Text(verbatim: item.subtitle)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }

                                        Text(verbatim: item.sourceKey)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }

                                    Spacer()

                                    Text(formatDuration(item.duration))
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.tint)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("No reading statistics yet".tl, systemImage: "chart.bar.xaxis")
                } description: {
                    Text("Read comics for at least 30 seconds to record statistics".tl)
                }
            }
        }
        .navigationTitle("Reading Statistics".tl)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if summary.total > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort".tl, selection: $sortType) {
                            Text("Last Read".tl).tag(ReadingSort.lastRead)
                            Text("Duration Desc".tl).tag(ReadingSort.durationDesc)
                            Text("Duration Asc".tl).tag(ReadingSort.durationAsc)
                            Text("Name Asc".tl).tag(ReadingSort.nameAsc)
                            Text("Name Desc".tl).tag(ReadingSort.nameDesc)
                        }

                        Divider()

                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Label("Clear Reading Statistics".tl, systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .confirmationDialog(
            "Are you sure you want to clear reading statistics?".tl,
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Confirm".tl, role: .destructive) {
                HistoryManager.shared.clearReadingStatistics()
                reload()
            }
            Button("Cancel".tl, role: .cancel) {}
        }
        .onAppear(perform: reload)
    }

    private var summaryCards: some View {
        HStack(spacing: 12) {
            summaryCard(title: "Today".tl, duration: summary.today, color: .blue)
            summaryCard(title: "Last 7 Days".tl, duration: summary.lastSevenDays, color: .purple)
            summaryCard(title: "All Time".tl, duration: summary.total, color: .orange)
        }
        .padding(.vertical, 4)
    }

    private func summaryCard(title: String, duration: TimeInterval, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(formatDuration(duration))
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private var trendChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Chart(summary.daily) { item in
                BarMark(
                    x: .value("Day", item.dayKey),
                    y: .value("Minutes", item.duration / 60.0)
                )
                .foregroundStyle(.blue.gradient)
                .cornerRadius(4)
            }
            .frame(height: 160)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let min = value.as(Double.self) {
                            Text("\(Int(min))m")
                                .font(.caption2)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var sortedComics: [ComicReadingStatistics] {
        var list = summary.recentComics
        switch sortType {
        case .lastRead:
            list.sort { $0.lastReadAt > $1.lastReadAt }
        case .durationDesc:
            list.sort { $0.duration > $1.duration }
        case .durationAsc:
            list.sort { $0.duration < $1.duration }
        case .nameAsc:
            list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .nameDesc:
            list.sort { $0.title.localizedStandardCompare($1.title) == .orderedDescending }
        }
        return list
    }

    private func reload() {
        summary = HistoryManager.shared.getReadingStatisticsSummary()
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "Less than a minute".tl
        }
        let totalMin = Int(seconds / 60)
        let hours = totalMin / 60
        let minutes = totalMin % 60
        if hours > 0 && minutes > 0 {
            return "\(hours) h \(minutes) min".tl
        } else if hours > 0 {
            return "\(hours) h".tl
        } else {
            return "\(minutes) min".tl
        }
    }
}
