import SwiftData
import SwiftUI

/// 找书页。输入一次，搜索已启用的全部书源；还没搜的时候只显示搜索历史。
struct BookSearchView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var books: [BookRecord]
    @Query(sort: \SourceRecord.addedAt) private var sourceRecords: [SourceRecord]
    var onOpen: (UUID) -> Void

    @State private var query = ""
    @State private var history: [String] = []
    @State private var batches: [SourceSearchBatch] = []
    @State private var selectedTab: SearchTab = .all
    @State private var didSearch = false
    @State private var searching = false
    @State private var searchGeneration = 0
    @State private var searchTask: Task<Void, Never>?
    @State private var debounceTask: Task<Void, Never>?
    @State private var addingID: String?
    @State private var status = ""
    @State private var errorText: String?
    @FocusState private var focused: Bool

    private var needle: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shelfMatches: [BookRecord] {
        books.filter { BookSearch.shelfHit(title: $0.title, author: $0.author, query: query) }
    }

    private var listedSources: [SourceSearchBatch] {
        BookSearch.listed(batches)
    }

    private var finishedCount: Int {
        batches.filter { !$0.isSearching }.count
    }

    private var missedCount: Int {
        batches.filter { batch in
            if case .books(let books) = batch.phase { return books.isEmpty }
            return false
        }.count
    }

    private var failedCount: Int {
        batches.filter {
            if case .failed = $0.phase { return true }
            return false
        }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if didSearch {
                resultBody
            } else {
                historyBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ShelfInk.paper.ignoresSafeArea())
        .navigationTitle("搜索")
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(ShelfInk.paper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        #endif
        .preferredColorScheme(.light)
        .tint(ShelfInk.accent)
        .alert("搜索", isPresented: errorPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .onAppear {
            history = BookSearchHistory.load()
        }
        .onChange(of: query) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                debounceTask?.cancel()
                guard didSearch else { return }
                stopSearch()
                return
            }
            // 输入停顿约 500ms 自动搜索；回车仍立即触发 startSearch。
            debounceTask?.cancel()
            debounceTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
                startSearch()
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(350))
            if query.isEmpty {
                focused = true
            }
        }
        .onDisappear {
            searchTask?.cancel()
            debounceTask?.cancel()
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.medium))
                    .foregroundStyle(ShelfInk.secondary)
                TextField(
                    "",
                    text: $query,
                    prompt: Text("搜索书名或作者").foregroundStyle(ShelfInk.secondary)
                )
                .focused($focused)
                .textFieldStyle(.plain)
                .foregroundStyle(ShelfInk.ink)
                .submitLabel(.search)
                #if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .onSubmit(startSearch)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(ShelfInk.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(ShelfInk.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(ShelfInk.line, lineWidth: 1)
            )

            Button("搜索", action: startSearch)
                .font(.body.weight(.semibold))
                .foregroundStyle(needle.isEmpty ? ShelfInk.secondary : ShelfInk.accent)
                .disabled(needle.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var historyBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("搜索历史")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ShelfInk.ink)
                    Spacer()
                    if !history.isEmpty {
                        Button("清空") {
                            BookSearchHistory.clear()
                            history = []
                        }
                        .font(.subheadline)
                        .foregroundStyle(ShelfInk.accent)
                    }
                }
                if history.isEmpty {
                    Text("输入书名或作者，会同时搜索已启用的书源。")
                        .font(.subheadline)
                        .foregroundStyle(ShelfInk.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ChipFlow(spacing: 8) {
                        ForEach(history, id: \.self) { item in
                            Button {
                                query = item
                                startSearch()
                            } label: {
                                Text(item)
                                    .font(.subheadline)
                                    .foregroundStyle(ShelfInk.ink)
                                    .lineLimit(1)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(ShelfInk.chip, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var resultBody: some View {
        VStack(spacing: 0) {
            if batches.isEmpty {
                message(
                    symbol: "books.vertical",
                    title: "没有可用书源",
                    detail: "先在书架右上角的添加里打开书源，并勾选要使用的站点。"
                )
            } else {
                sourceTabs
                resultList
            }
        }
    }

    private var sourceTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 18) {
                tabButton(.all, title: "全部", count: allCount, spinning: false)
                if !shelfMatches.isEmpty {
                    tabButton(.shelf, title: "书架", count: shelfMatches.count, spinning: false)
                }
                ForEach(listedSources) { batch in
                    tabButton(
                        .source(batch.sourceID),
                        title: batch.sourceName,
                        count: batch.books.count,
                        spinning: batch.isSearching
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }

    private var allCount: Int {
        shelfMatches.count + batches.reduce(0) { $0 + $1.books.count }
    }

    private func tabButton(_ tab: SearchTab, title: String, count: Int, spinning: Bool) -> some View {
        let chosen = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(chosen ? .semibold : .regular))
                        .lineLimit(1)
                    if spinning {
                        ProgressView()
                            .controlSize(.mini)
                    } else if didSearch && count > 0 {
                        Text("\(count)")
                            .font(.caption2.weight(.semibold))
                    }
                }
                .foregroundStyle(chosen ? ShelfInk.accent : ShelfInk.secondary)
                Rectangle()
                    .fill(chosen ? ShelfInk.accent : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var resultList: some View {
        let rows = displayedRows
        if rows.isEmpty && searching {
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                Text(progressText)
                    .font(.subheadline)
                    .foregroundStyle(ShelfInk.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty && selectedFailure != nil {
            message(
                symbol: "wifi.exclamationmark",
                title: selectedFailure ?? "这个书源没有连上",
                detail: "其他书源的结果在「全部」里。"
            )
        } else if rows.isEmpty && failedCount == batches.count && !batches.isEmpty {
            message(symbol: "wifi.exclamationmark", title: "没有连上书源", detail: "已启用的书源这次都没有连上。")
        } else if rows.isEmpty, case .source = selectedTab {
            message(symbol: "magnifyingglass", title: "这个书源没有这本书", detail: progressText)
        } else if rows.isEmpty {
            message(
                symbol: "magnifyingglass",
                title: "没有找到「\(needle)」",
                detail: footerText.isEmpty ? "换个书名，或再到书源里勾选别的站点。" : footerText
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if searching {
                        Text(progressText)
                            .font(.caption)
                            .foregroundStyle(ShelfInk.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 6)
                    }
                    ForEach(rows) { row in
                        resultRow(row)
                        Rectangle()
                            .fill(ShelfInk.line)
                            .frame(height: 1)
                            .padding(.leading, 74)
                    }
                    if selectedTab == .all, !searching, missedCount > 0 || failedCount > 0 {
                        Text(footerText)
                            .font(.caption)
                            .foregroundStyle(ShelfInk.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                    }
                }
                .padding(.top, 6)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var progressText: String {
        if batches.isEmpty { return "" }
        if searching {
            return "正在搜索 \(finishedCount)/\(batches.count)"
        }
        return "已搜索 \(batches.count) 个书源"
    }

    private var footerText: String {
        var parts: [String] = []
        if missedCount > 0 {
            parts.append("另外 \(missedCount) 个书源没有这本书")
        }
        if failedCount > 0 {
            parts.append("\(failedCount) 个书源没有连上")
        }
        return parts.joined(separator: "，")
    }

    private var selectedFailure: String? {
        guard case .source(let id) = selectedTab,
              let batch = batches.first(where: { $0.sourceID == id }),
              case .failed(let message) = batch.phase else { return nil }
        return message
    }

    private var displayedRows: [SearchRow] {
        switch selectedTab {
        case .all:
            return shelfRows + onlineRows
        case .shelf:
            return shelfRows
        case .source(let id):
            guard let batch = batches.first(where: { $0.sourceID == id }) else { return [] }
            return batch.books.map { book in
                SearchRow(
                    id: "\(batch.sourceID)\n\(book.id)",
                    title: book.title,
                    author: book.author,
                    detail: meta(book),
                    summary: book.summary,
                    sourceName: nil,
                    shelfBookID: nil,
                    sourceID: batch.sourceID,
                    remoteBookID: book.id,
                    coverURL: book.coverURL
                )
            }
        }
    }

    private var shelfRows: [SearchRow] {
        shelfMatches.map { book in
            SearchRow(
                id: "shelf-\(book.id.uuidString)",
                title: book.title,
                author: book.author,
                detail: book.author.isEmpty ? "书架" : book.author,
                summary: book.currentChapterTitle,
                sourceName: "书架",
                shelfBookID: book.id,
                sourceID: nil,
                remoteBookID: book.remoteBookID
            )
        }
    }

    private var onlineRows: [SearchRow] {
        // 按书名+作者合并多源命中。batches 已按 source weight 降序，首个出现即权重最高的源。
        var rowsByKey = [String: SearchRow]()
        var keyOrder: [String] = []
        var hitCount = [String: Int]()
        for batch in batches {
            for book in batch.books {
                let key = (book.title + "|" + book.author).lowercased()
                hitCount[key, default: 0] += 1
                guard rowsByKey[key] == nil else { continue }
                let row = SearchRow(
                    id: "\(batch.sourceID)\n\(book.id)",
                    title: book.title,
                    author: book.author,
                    detail: meta(book),
                    summary: book.summary,
                    sourceName: batch.sourceName,
                    shelfBookID: nil,
                    sourceID: batch.sourceID,
                    remoteBookID: book.id,
                    coverURL: book.coverURL
                )
                rowsByKey[key] = row
                keyOrder.append(key)
            }
        }
        return keyOrder.compactMap { key in
            guard var row = rowsByKey[key] else { return nil }
            if (hitCount[key] ?? 0) > 1 {
                row.sourceName = "多源×\(hitCount[key] ?? 0)"
            }
            return row
        }
    }

    private func meta(_ book: CatalogBook) -> String {
        [book.author.isEmpty ? "未知作者" : book.author, book.category, book.status]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func resultRow(_ row: SearchRow) -> some View {
        Button {
            Task { await open(row) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                if let shelfID = row.shelfBookID, let book = books.first(where: { $0.id == shelfID }) {
                    BookCover(book: book, compact: true)
                } else {
                    SearchCover(title: row.title, coverURL: row.coverURL)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title.isEmpty ? "未命名" : row.title)
                        .font(.headline)
                        .foregroundStyle(ShelfInk.ink)
                        .lineLimit(1)
                    Text(row.detail)
                        .font(.subheadline)
                        .foregroundStyle(ShelfInk.secondary)
                        .lineLimit(1)
                    if addingID == row.id {
                        Text(status.isEmpty ? "正在读取第一章..." : status)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(ShelfInk.accent)
                            .lineLimit(1)
                    } else if !row.summary.isEmpty {
                        Text(row.summary)
                            .font(.caption)
                            .foregroundStyle(ShelfInk.secondary)
                            .lineLimit(2)
                    }
                    if let sourceName = row.sourceName {
                        Text(owned(row) ? "\(sourceName) · 已在书架" : sourceName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ShelfInk.accent)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(addingID != nil)
    }

    private func owned(_ row: SearchRow) -> Bool {
        guard row.shelfBookID == nil else { return false }
        let remoteID = row.remoteBookID.trimmingCharacters(in: .whitespacesAndNewlines)
        return books.contains { book in
            if !remoteID.isEmpty, book.remoteBookID == remoteID { return true }
            guard !book.remoteBookID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return BookIdentity.same(title: row.title, author: row.author, otherTitle: book.title, otherAuthor: book.author)
        }
    }

    private func startSearch() {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return }
        query = needle
        history = BookSearchHistory.remember(needle)
        focused = false
        let sources = BookSourceLibrary.switchable(records: sourceRecords)
        didSearch = true
        selectedTab = .all
        searchGeneration += 1
        let generation = searchGeneration
        searchTask?.cancel()
        guard !sources.isEmpty else {
            batches = []
            searching = false
            searchTask = nil
            return
        }
        batches = sources.map {
            SourceSearchBatch(sourceID: $0.id, sourceName: $0.name, phase: .searching)
        }
        searching = true
        searchTask = Task { @MainActor in
            let stream = BookSearch.updates(query: needle, sources: sources)
            for await batch in stream {
                guard generation == searchGeneration, !Task.isCancelled else { break }
                replace(batch)
            }
            guard generation == searchGeneration, !Task.isCancelled else { return }
            searching = false
        }
    }

    private func stopSearch() {
        searchGeneration += 1
        searchTask?.cancel()
        searchTask = nil
        didSearch = false
        searching = false
        batches = []
        selectedTab = .all
        status = ""
    }

    private func replace(_ batch: SourceSearchBatch) {
        guard let index = batches.firstIndex(where: { $0.sourceID == batch.sourceID }) else { return }
        batches[index] = batch
        if case .source(let id) = selectedTab, id == batch.sourceID, batch.books.isEmpty, !batch.isSearching {
            selectedTab = .all
        }
    }

    private func message(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 36))
                .foregroundStyle(ShelfInk.accent)
            Text(title)
                .font(.headline)
                .foregroundStyle(ShelfInk.ink)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(ShelfInk.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func open(_ row: SearchRow) async {
        if let shelfID = row.shelfBookID {
            onOpen(shelfID)
            return
        }
        let remoteID = row.remoteBookID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remoteID.isEmpty, let sourceID = row.sourceID else { return }
        addingID = row.id
        status = "正在读取第一章..."
        defer {
            addingID = nil
            status = ""
        }
        if let existing = BookLibrary.existingRemote(bookID: remoteID, context: modelContext) {
            onOpen(existing.id)
            return
        }
        let sources = BookSourceLibrary.switchable(records: sourceRecords)
        guard let source = sources.first(where: { $0.id == sourceID }),
              let catalog = BookSourceLibrary.catalog(for: source) as? any IncrementalBookCatalog else {
            errorText = "这个书源不能按章阅读"
            return
        }
        do {
            let opening = try await catalog.fetchOpening(bookID: remoteID)
            let importedTitle = opening.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let imported = try BookLibrary.importOnline(
                text: opening.text,
                suggestedTitle: importedTitle.isEmpty ? row.title : importedTitle,
                author: row.author,
                remoteBookID: remoteID,
                remoteSourceID: sourceID,
                chapters: opening.chapters,
                openingBody: opening.openingBody,
                context: modelContext
            )
            let listedAuthor = row.author.trimmingCharacters(in: .whitespacesAndNewlines)
            if imported.isNew, imported.book.author.isEmpty, !listedAuthor.isEmpty, listedAuthor != "未知作者" {
                imported.book.author = listedAuthor
                try? modelContext.save()
            }
            onOpen(imported.book.id)
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private enum SearchTab: Hashable {
    case all
    case shelf
    case source(String)
}

private struct SearchRow: Identifiable {
    var id: String
    var title: String
    var author: String
    var detail: String
    var summary: String
    var sourceName: String?
    var shelfBookID: UUID?
    var sourceID: String?
    var remoteBookID: String
    var coverURL: String = ""
}

private struct SearchCover: View {
    var title: String
    var coverURL: String

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(hue: BookMetadata.coverHue(for: title), saturation: 0.45, brightness: 0.62))
            if let url = URL(string: coverURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .failure:
                        coverLabel
                    case .success(let image):
                        image.resizable().scaledToFill()
                    @unknown default:
                        coverLabel
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                coverLabel
            }
        }
        .frame(width: 46, height: 66)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var coverLabel: some View {
        Text(title.isEmpty ? "未命名" : title)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(3)
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

private struct ChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        guard width > 1 else {
            let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            return CGSize(width: width, height: height)
        }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}
