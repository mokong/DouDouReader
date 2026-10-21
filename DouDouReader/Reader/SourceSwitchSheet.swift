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
    /// 目录拉回来的最新章节。搜索卡片上没有这一章时才去补。
    @State private var fetchedChapters: [String: String] = [:]
    @State private var failedChapterIDs: Set<String> = []
    @State private var loadingChapterIDs: Set<String> = []
    @State private var catalogGeneration = 0
    @State private var catalogGate = SwitchCatalogGate()
    @State private var catalogTasks: [Task<Void, Never>] = []

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
        .onDisappear {
            searchTask?.cancel()
            catalogGeneration += 1
            catalogTasks.forEach { $0.cancel() }
            catalogTasks.removeAll()
        }
        .onChange(of: hits.map(\.id)) { _, _ in
            loadLatestChapters()
        }
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
        let chapter = shownChapter(hit)
        let hasChapter = !chapter.isEmpty
        return Button {
            choose(hit)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(hasChapter ? chapter : placeholder(hit))
                        .font(.body)
                        .foregroundStyle(hasChapter ? Color.primary : Color.secondary)
                        .lineLimit(2)
                    Text(hit.sourceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if busyID == hit.id || (chapter.isEmpty && loadingChapterIDs.contains(hit.id)) {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busyID != nil)
        .accessibilityLabel(accessibilityText(hit, chapter: chapter))
    }

    /// 主行是最新章节。搜索结果里有就先用，没有就等目录拉回来。
    private func shownChapter(_ hit: SourceSwitchHit) -> String {
        if let fetched = fetchedChapters[hit.id], !fetched.isEmpty { return fetched }
        return LatestChapterLabel.fromSearch(latestChapter: hit.book.latestChapter, summary: hit.book.summary)
    }

    private func placeholder(_ hit: SourceSwitchHit) -> String {
        if failedChapterIDs.contains(hit.id) { return "没有读到最新章节" }
        return "正在读取最新章节"
    }

    private func accessibilityText(_ hit: SourceSwitchHit, chapter: String) -> String {
        let chapterText = chapter.isEmpty ? placeholder(hit) : chapter
        return "\(chapterText)，\(hit.sourceName)"
    }

    private func loadLatestChapters() {
        let generation = catalogGeneration
        for hit in hits {
            let stated = hit.book.latestChapter.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stated.isEmpty { continue }
            if fetchedChapters[hit.id] != nil || failedChapterIDs.contains(hit.id) || loadingChapterIDs.contains(hit.id) {
                continue
            }
            loadingChapterIDs.insert(hit.id)
            guard let source = sources.first(where: { $0.id == hit.sourceID }) else {
                loadingChapterIDs.remove(hit.id)
                failedChapterIDs.insert(hit.id)
                continue
            }
            let bookID = hit.book.id
            let hitID = hit.id
            let gate = catalogGate
            let task = Task { @MainActor in
                await gate.acquire()
                if Task.isCancelled || generation != catalogGeneration {
                    await gate.release()
                    return
                }
                // 目录解析离开主线程。停在主线程上时，列表一滚动就和建树抢同一条栈。
                let title = await latestChapterTitle(source: source, bookID: bookID)
                await gate.release()
                guard !Task.isCancelled, generation == catalogGeneration else { return }
                loadingChapterIDs.remove(hitID)
                if let title, !title.isEmpty {
                    fetchedChapters[hitID] = title
                } else {
                    failedChapterIDs.insert(hitID)
                }
            }
            catalogTasks.append(task)
        }
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

/// 拉目录并取出最后一章。走并发线程池，避免在主线程上解析整份目录。
@concurrent
private func latestChapterTitle(source: SwitchableSource, bookID: String) async -> String? {
    guard let catalog = BookSourceLibrary.catalog(for: source) as? IncrementalBookCatalog else { return nil }
    do {
        let toc = try await catalog.fetchTOC(bookID: bookID)
        let title = LatestChapterLabel.pick(toc.chapters)
        return title.isEmpty ? nil : title
    } catch {
        return nil
    }
}

/// 换源时同时拉多个书源的目录，最多三路，避免把站点打满。
private actor SwitchCatalogGate {
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let limit = 3

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }
}
