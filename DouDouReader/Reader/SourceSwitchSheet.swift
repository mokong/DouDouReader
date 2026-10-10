import SwiftData
import SwiftUI

/// 按当前书名和作者，在其他已启用书源里找同一本书。
struct SourceSwitchSheet: View {
    var bookTitle: String
    var author: String
    var currentSourceID: String
    var currentBookID: String
    var onSelect: (SwitchableSource, CatalogBook) async -> String?

    @Query(sort: \SourceRecord.addedAt) private var sourceRecords: [SourceRecord]
    @State private var sources: [SwitchableSource] = []
    @State private var batches: [SourceSearchBatch] = []
    @State private var searching = false
    @State private var busyID: String?
    @State private var errorText: String?
    @State private var searchTask: Task<Void, Never>?

    private var hits: [SourceSwitchHit] {
        BookSearch.switchHits(
            title: bookTitle,
            author: author,
            excludingSourceID: currentSourceID,
            excludingBookID: currentBookID,
            batches: batches
        )
    }

    private var failedCount: Int {
        batches.reduce(into: 0) { count, batch in
            if case .failed = batch.phase { count += 1 }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if sources.isEmpty && !searching {
                        Text("没有其他可用书源")
                            .foregroundStyle(.secondary)
                    } else if hits.isEmpty && !searching {
                        Text("其他书源没有这本书")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(hits) { hit in
                            row(hit)
                        }
                    }
                } header: {
                    Text(header)
                }
            }
            .navigationTitle("换源")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge: .bottom) {
                notice
            }
        }
        .onAppear(perform: start)
        .onDisappear { searchTask?.cancel() }
    }

    private var header: String {
        let name = bookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = author.trimmingCharacters(in: .whitespacesAndNewlines)
        if who.isEmpty || who == "未知作者" { return name.isEmpty ? "当前这本书" : name }
        return "\(name) · \(who)"
    }

    @ViewBuilder
    private var notice: some View {
        if let errorText, !errorText.isEmpty {
            Text(errorText)
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.bar)
        } else if searching {
            HStack(spacing: 8) {
                ProgressView()
                Text("正在其他书源查找")
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.bar)
        } else if failedCount > 0 {
            Text("\(failedCount) 个书源没有连上")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.bar)
        }
    }

    private func row(_ hit: SourceSwitchHit) -> some View {
        Button {
            choose(hit)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(hit.book.title.isEmpty ? bookTitle : hit.book.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(meta(hit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if busyID == hit.id {
                    Text("正在换到这个书源")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                } else if !latestLine(hit).isEmpty {
                    Text(latestLine(hit))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busyID != nil)
    }

    private func latestLine(_ hit: SourceSwitchHit) -> String {
        let summary = hit.book.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return "" }
        if summary.contains("章") || summary.contains("回") {
            return "最新 \(summary)"
        }
        return summary
    }

    private func meta(_ hit: SourceSwitchHit) -> String {
        let who = hit.book.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let authorText = who.isEmpty || who == "未知作者" ? "" : who
        return [authorText, hit.sourceName].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func start() {
        guard searchTask == nil else { return }
        let others = BookSourceLibrary.switchable(records: sourceRecords).filter { source in
            source.id != currentSourceID
        }
        sources = others
        let needle = bookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !others.isEmpty else { return }
        searching = true
        batches = others.map {
            SourceSearchBatch(sourceID: $0.id, sourceName: $0.name, phase: .searching)
        }
        searchTask = Task { @MainActor in
            let stream = BookSearch.updates(query: needle, sources: others)
            for await batch in stream {
                guard !Task.isCancelled else { break }
                if let index = batches.firstIndex(where: { $0.sourceID == batch.sourceID }) {
                    batches[index] = batch
                }
            }
            guard !Task.isCancelled else { return }
            searching = false
        }
    }

    private func choose(_ hit: SourceSwitchHit) {
        guard busyID == nil, let source = sources.first(where: { $0.id == hit.sourceID }) else { return }
        busyID = hit.id
        errorText = nil
        Task { @MainActor in
            let message = await onSelect(source, hit.book)
            busyID = nil
            errorText = message
        }
    }
}
