import SwiftData
import SwiftUI
#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - 主浏览界面（参考截图 1：可用书源发现与检索）

struct SourceBrowserView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SourceRecord.addedAt) private var sources: [SourceRecord]
    var onOpen: (UUID) -> Void

    // 当前选中的书源。切换后发现、搜索、下载都只走这一条。
    @State private var selectedSiteID = UserDefaults.standard.string(forKey: BookSourceLibrary.selectionKey) ?? "preset-xiangshu"
    @State private var selectedChannel = ""
    @State private var filterSelections: [String: String] = [:]
    @State private var showSwitchSheet = false

    // 搜索与发现
    @State private var query = ""
    @State private var searchResults: [CatalogBook] = []
    @State private var discoverBooks: [CatalogBook] = []
    @State private var searching = false
    @State private var discoverLoading = false
    @State private var discoverGeneration = 0
    @State private var discoverPage = 1
    @State private var loadingMore = false
    @State private var hasMoreDiscover = false
    @State private var addingID: String?
    @State private var status = ""
    @State private var errorText: String?
    @State private var discoverError: String?
    @State private var didPreview = false

    var body: some View {
        VStack(spacing: 0) {
            searchBarHeader

            // 一级频道分类（男频, 女频, 出版书籍...）
            channelTabBar

            // 二级多维属性筛选器（分类、字数、状态、免费/VIP、品质、更新、排序）
            filterDimensionsView

            Divider().background(Color.white.opacity(0.12))

            // 书籍列表流
            bookStreamView
        }
        .background(Color.black.ignoresSafeArea())
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    showSwitchSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedEntry?.name ?? "未选择书源")
                            .font(.system(size: 17, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .fixedSize()
                            .layoutPriority(1)
                    }
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换书源")
                .accessibilityHint("打开书源选择")
            }
        }
        #if os(iOS) || os(visionOS)
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
        .preferredColorScheme(.dark)
        .tint(Color(red: 0.2, green: 0.6, blue: 1.0))
        .sheet(isPresented: $showSwitchSheet) {
            SwitchSiteSheet(selectedID: $selectedSiteID) { item in
                updateSite(item)
            }
        }
        .onChange(of: showSwitchSheet) { _, isOpen in
            guard !isOpen, let entry = selectedEntry, entry.id != selectedSiteID else { return }
            selectedSiteID = entry.id
            UserDefaults.standard.set(entry.id, forKey: BookSourceLibrary.selectionKey)
            Task { await loadDiscover() }
        }
        .onChange(of: switchableSources.map(\.id)) { _, ids in
            guard !ids.contains(selectedSiteID) else { return }
            guard let first = switchableSources.first else {
                discoverBooks = []
                searchResults = []
                discoverError = "没有可用书源。请在书源管理里勾选要使用的书源。"
                return
            }
            updateSite(first)
        }
        .alert("书源", isPresented: errorPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .task {
            // 自动化自检支持
            if ProcessInfo.processInfo.arguments.contains("-openSwitchSite") {
                showSwitchSheet = true
            }
            if let initialIdx = ProcessInfo.processInfo.arguments.firstIndex(of: "-site"),
               initialIdx + 1 < ProcessInfo.processInfo.arguments.count {
                let siteKey = ProcessInfo.processInfo.arguments[initialIdx + 1]
                if let match = switchableSources.first(where: {
                    $0.id == siteKey || $0.name == siteKey || $0.host.contains(siteKey) || $0.source.sourceURL.contains(siteKey)
                }) {
                    selectedSiteID = match.id
                }
            }
            if let entry = selectedEntry, entry.id != selectedSiteID {
                selectedSiteID = entry.id
            }
            if ProcessInfo.processInfo.arguments.contains("-searchTest"), !didPreview {
                didPreview = true
                query = "灯塔"
                await search()
            } else {
                await loadDiscover()
            }
        }
    }

    // MARK: - 搜索栏

    private var searchBarHeader: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Color.white.opacity(0.6))
                TextField("搜索书名或作者", text: $query)
                    .foregroundColor(.white)
                    .font(.system(size: 14))
                    .onSubmit {
                        Task { await search() }
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                        searchResults = []
                        Task { await loadDiscover() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Color.white.opacity(0.5))
                            .font(.system(size: 14))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            Button("检索") {
                Task { await search() }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(Color(red: 0.2, green: 0.6, blue: 1.0))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(red: 0.08, green: 0.08, blue: 0.09))
    }

    // MARK: - 一级分类频道栏（根据当前书源实际频道动态渲染）

    private var channelTabBar: some View {
        Group {
            if exploreChannels.count > 1 || (exploreChannels.count == 1 && exploreChannels[0].title != "全部") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 24) {
                        ForEach(exploreChannels) { channel in
                            let chosen = currentChannel?.id == channel.id
                            VStack(spacing: 4) {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        selectedChannel = channel.title
                                        filterSelections = channel.defaultSelections()
                                    }
                                    Task { await loadDiscover() }
                                } label: {
                                    Text(channel.title)
                                        .font(.system(size: 15, weight: chosen ? .bold : .regular))
                                        .foregroundColor(
                                            chosen
                                                ? Color(red: 0.0, green: 0.85, blue: 0.95)
                                                : Color.white.opacity(0.85)
                                        )
                                }
                                .buttonStyle(.plain)

                                Rectangle()
                                    .fill(chosen ? Color(red: 0.0, green: 0.85, blue: 0.95) : Color.clear)
                                    .frame(height: 2)
                                    .cornerRadius(1)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                }
                .background(Color.black)
            }
        }
    }

    // MARK: - 二级多维属性筛选器（根据当前书源实际筛选行动态渲染）

    private var filterDimensionsView: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let channel = currentChannel {
                ForEach(channel.filters) { filter in
                    filterLineView(filter)
                }
            }
        }
        .padding(.vertical, currentChannel?.filters.isEmpty == false ? 6 : 0)
        .background(Color.black)
    }

    private func filterLineView(_ filter: ExploreFilter) -> some View {
        let currentValue = filterSelections[filter.key] ?? filter.options.first?.value
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(Array(filter.options.enumerated()), id: \.element.id) { index, option in
                    HStack(spacing: 5) {
                        Button {
                            filterSelections[filter.key] = option.value
                            Task { await loadDiscover() }
                        } label: {
                            Text(option.label)
                                .font(.system(size: 13, weight: currentValue == option.value ? .semibold : .regular))
                                .foregroundColor(
                                    currentValue == option.value
                                        ? Color(red: 0.0, green: 0.85, blue: 0.95)
                                        : Color.white.opacity(0.7)
                                )
                        }
                        .buttonStyle(.plain)

                        if index < filter.options.count - 1 {
                            Text("·")
                                .font(.system(size: 12))
                                .foregroundColor(Color.white.opacity(0.3))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - 书籍列表视图

    @ViewBuilder
    private var bookStreamView: some View {
        if searching || discoverLoading {
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                    .tint(Color.cyan)
                Text(status.isEmpty ? "正在连接 \(selectedEntry?.name ?? "书源")..." : status)
                    .font(.system(size: 14))
                    .foregroundColor(Color.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !searchResults.isEmpty {
            bookList(searchResults, badge: "搜索")
        } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messageView(
                symbol: "magnifyingglass",
                title: "在\(selectedEntry?.name ?? "当前书源")未找到匹配书籍",
                detail: "可点顶部书源名称，切换其他已启用书源"
            )
        } else if !discoverBooks.isEmpty {
            bookList(discoverBooks, badge: currentChannel?.title ?? "发现", isDiscover: true)
        } else {
            messageView(
                symbol: "books.vertical",
                title: discoverError ?? "当前书源没有可显示的书",
                detail: selectedEntry.map { "来源 \($0.host)" } ?? "请先在书源管理中勾选书源"
            )
        }
    }

    private func bookList(_ books: [CatalogBook], badge: String, isDiscover: Bool = false) -> some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(books) { book in
                    bookCard(
                        title: book.title,
                        author: book.author.isEmpty ? "未知作者" : book.author,
                        category: book.category.isEmpty ? (selectedEntry?.name ?? "发现") : book.category,
                        status: book.status.isEmpty ? "在线" : book.status,
                        summary: book.summary.isEmpty ? "点击阅读第一章。" : book.summary,
                        badge: badge,
                        bookID: book.id
                    )
                }
                if isDiscover {
                    loadMoreFooter
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var loadMoreFooter: some View {
        if hasMoreDiscover {
            Button {
                Task { await loadMoreDiscover() }
            } label: {
                HStack {
                    if loadingMore {
                        ProgressView().tint(Color.cyan)
                    }
                    Text(loadingMore ? "正在加载下一页..." : "加载更多")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color(red: 0.2, green: 0.6, blue: 1.0))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .disabled(loadingMore)
        } else {
            Text("已经到底啦")
                .font(.system(size: 12))
                .foregroundColor(Color.white.opacity(0.35))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }

    private func messageView(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 40))
                .foregroundColor(Color.white.opacity(0.3))
            Text(title)
                .font(.system(size: 15))
                .foregroundColor(Color.white.opacity(0.6))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 13))
                .foregroundColor(Color.white.opacity(0.4))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 书籍卡片组件（参考截图 1：左封面+右上红角标，右书名+作者标签+简介）

    private func bookCard(
        title: String,
        author: String,
        category: String,
        status: String,
        summary: String,
        badge: String,
        bookID: String
    ) -> some View {
        Button {
            Task { await openOrDownloadBook(title: title, author: author, bookID: bookID) }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                // 左侧封面图（艺术阴影与右上红角标）
                NovelCoverView(
                    title: title,
                    author: author,
                    badge: badge,
                    category: category
                )

                // 右侧信息区
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text("\(author) · \(category) · \(status)")
                        .font(.system(size: 13))
                        .foregroundColor(Color.white.opacity(0.6))
                        .lineLimit(1)

                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.4))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if addingID == bookID {
                        Text(self.status.isEmpty ? "正在加入书架..." : self.status)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(red: 0.0, green: 0.85, blue: 0.95))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(addingID != nil)
    }

    // MARK: - 当前书源（切换后立刻换成这一条，不再回退到别的源或本地假书单）

    private var switchableSources: [SwitchableSource] {
        BookSourceLibrary.switchable(records: sources)
    }

    private var selectedEntry: SwitchableSource? {
        switchableSources.first { $0.id == selectedSiteID } ?? switchableSources.first
    }

    private var exploreChannels: [ExploreChannel] {
        guard let source = selectedEntry?.source else { return [] }
        return ExploreURLParser.channels(from: source.exploreRule.urlTemplate)
    }

    private var currentChannel: ExploreChannel? {
        exploreChannels.first { $0.title == selectedChannel } ?? exploreChannels.first
    }

    private var activeCatalog: BookCatalog? {
        guard let entry = selectedEntry else { return nil }
        return BookSourceLibrary.catalog(for: entry)
    }

    private var ruleCatalog: RuleBasedBookCatalog? {
        guard let entry = selectedEntry, entry.source.kind != .doudou else { return nil }
        return RuleBasedBookCatalog(recordID: entry.id, source: entry.source)
    }

    private func updateSite(_ item: SwitchableSource) {
        selectedSiteID = item.id
        UserDefaults.standard.set(item.id, forKey: BookSourceLibrary.selectionKey)
        selectedChannel = ""
        filterSelections = [:]
        searchResults = []
        discoverBooks = []
        discoverError = nil
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task { await search() }
        } else {
            Task { await loadDiscover() }
        }
    }

    private func selectionsForLoad() -> [String: String] {
        guard let channel = currentChannel else { return [:] }
        var selections = channel.defaultSelections()
        for filter in channel.filters {
            if let chosen = filterSelections[filter.key] {
                selections[filter.key] = chosen
            }
        }
        return selections
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })
    }

    // MARK: - 搜索与下载

    private func search() async {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            searchResults = []
            await loadDiscover()
            return
        }
        guard let catalog = activeCatalog else {
            searchResults = []
            errorText = "没有选中书源"
            return
        }
        searching = true
        status = "正在检索 \(selectedEntry?.name ?? "书源")..."
        defer { searching = false }

        do {
            searchResults = try await catalog.search(query: needle)
            errorText = nil
        } catch {
            searchResults = []
            errorText = error.localizedDescription
        }
    }

    private func loadDiscover() async {
        discoverGeneration += 1
        let generation = discoverGeneration
        discoverPage = 1
        hasMoreDiscover = false
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.isEmpty else { return }

        guard let entry = selectedEntry else {
            discoverBooks = []
            discoverLoading = false
            discoverError = "没有可用书源。请在书源管理里勾选要使用的书源。"
            return
        }
        guard let channel = currentChannel, !channel.urlTemplate.isEmpty else {
            discoverBooks = []
            discoverLoading = false
            discoverError = "\(entry.name) 没有发现规则，请用上方搜索。"
            return
        }
        guard let catalog = ruleCatalog else {
            discoverBooks = []
            discoverLoading = false
            discoverError = "\(entry.name) 使用标准接口，请用搜索找书。"
            return
        }

        discoverLoading = true
        discoverError = nil
        status = "正在加载 \(entry.name)..."
        defer {
            if generation == discoverGeneration {
                discoverLoading = false
                status = ""
            }
        }

        do {
            let books = try await catalog.explore(
                channelURL: channel.urlTemplate,
                selections: selectionsForLoad(),
                page: 1
            )
            guard generation == discoverGeneration else { return }
            discoverBooks = books
            hasMoreDiscover = !books.isEmpty
            if books.isEmpty {
                discoverError = "\(entry.name) 的「\(channel.title)」没有解析到书籍。"
            }
        } catch {
            guard generation == discoverGeneration else { return }
            discoverBooks = []
            discoverError = error.localizedDescription
        }
    }

    /// 列表底部「加载更多」：追加下一页并按 book.id 去重。
    private func loadMoreDiscover() async {
        guard !discoverLoading, !loadingMore, hasMoreDiscover,
              let entry = selectedEntry, let channel = currentChannel, let catalog = ruleCatalog else {
            return
        }
        let generation = discoverGeneration
        let nextPage = discoverPage + 1
        loadingMore = true
        defer { loadingMore = false }
        do {
            let books = try await catalog.explore(
                channelURL: channel.urlTemplate,
                selections: selectionsForLoad(),
                page: nextPage
            )
            guard generation == discoverGeneration else { return }
            var seen = Set(discoverBooks.map(\.id))
            for book in books where seen.insert(book.id).inserted {
                discoverBooks.append(book)
            }
            discoverPage = nextPage
            hasMoreDiscover = !books.isEmpty
        } catch {
            // 翻页失败不打断已加载列表，仅停止继续加载。
            hasMoreDiscover = false
        }
    }

    private func openOrDownloadBook(title: String, author: String, bookID: String) async {
        addingID = bookID
        status = "正在读取第一章..."
        defer {
            addingID = nil
            if !discoverLoading && !searching {
                status = ""
            }
        }

        if let existing = BookLibrary.existingRemote(bookID: bookID, context: modelContext) {
            onOpen(existing.id)
            return
        }

        guard let catalog = activeCatalog as? IncrementalBookCatalog else {
            errorText = "这个书源不能按章阅读"
            return
        }

        do {
            let opening = try await catalog.fetchOpening(bookID: bookID)
            let importedTitle = opening.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let imported = try BookLibrary.importOnline(
                text: opening.text,
                suggestedTitle: importedTitle.isEmpty ? title : importedTitle,
                author: author,
                remoteBookID: bookID,
                remoteSourceID: selectedEntry?.id ?? "",
                chapters: opening.chapters,
                openingBody: opening.openingBody,
                context: modelContext
            )
            let listedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
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

// MARK: - 切换站点弹窗（参考截图 2：切换已勾选书源）

struct SwitchSiteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SourceRecord.addedAt) private var sources: [SourceRecord]

    @Binding var selectedID: String
    var onSelect: (SwitchableSource) -> Void

    @State private var tempSelectedID: String
    @State private var searchText = ""
    @State private var showingManager = false

    init(
        selectedID: Binding<String>,
        onSelect: @escaping (SwitchableSource) -> Void
    ) {
        self._selectedID = selectedID
        self.onSelect = onSelect
        self._tempSelectedID = State(initialValue: selectedID.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .trailing) {
                VStack(spacing: 0) {
                    // 顶部导航条（取消、切换站点、确定）
                    HStack {
                        Button("取消") {
                            dismiss()
                        }
                        .font(.system(size: 17))
                        .foregroundColor(Color(red: 0.2, green: 0.6, blue: 1.0))

                        Spacer()

                        Text("切换站点")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.white)

                        Spacer()

                        Button("确定") {
                            applySelection()
                            dismiss()
                        }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Color(red: 0.2, green: 0.6, blue: 1.0))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                    // 搜索框（搜索名称与 host）
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(Color.white.opacity(0.5))
                            .font(.system(size: 15))
                        TextField("搜索名称与 host", text: $searchText)
                            .foregroundColor(.white)
                            .font(.system(size: 15))
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(Color.white.opacity(0.5))
                                    .font(.system(size: 14))
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

                    // 站点分组平铺列表（参考截图 2：纯黑底、分割线）
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if groupedSites.isEmpty {
                                Text("没有已启用的书源。请到书源管理里勾选，或导入新书源。")
                                    .font(.system(size: 14))
                                    .foregroundColor(Color.white.opacity(0.55))
                                    .padding(24)
                            }
                            ForEach(Array(groupedSites.enumerated()), id: \.element.name) { index, group in
                                Text(group.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Color.white.opacity(0.45))
                                    .padding(.horizontal, 16)
                                    .padding(.top, index == 0 ? 10 : 18)
                                    .padding(.bottom, 6)

                                ForEach(group.sites) { site in
                                    siteRow(site: site)
                                        .padding(.horizontal, 16)
                                    Divider()
                                        .background(Color.white.opacity(0.08))
                                        .padding(.leading, 42)
                                }
                            }
                        }
                        .padding(.bottom, 24)
                    }
                    .background(Color.black)

                    // 底部管理与导入快捷入口
                    HStack {
                        Button {
                            showingManager = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "gearshape")
                                Text("管理与导入外部书源")
                            }
                            .font(.system(size: 14))
                            .foregroundColor(Color(red: 0.2, green: 0.6, blue: 1.0))
                        }
                    }
                    .padding(.vertical, 10)
                }
                .background(Color.black.ignoresSafeArea())

                // 右侧快速分类索引栏（参考截图 2：Top | 文 | 图 | 音 | 视）
                rightFastIndexBar
                    .padding(.trailing, 4)
            }
            .navigationDestination(isPresented: $showingManager) {
                SourceManagerView()
            }
        }
    }

    // MARK: - 站点行渲染（左文档图标，中名称+备注，右选中对勾）

    private func siteRow(site: SwitchableSource) -> some View {
        Button {
            tempSelectedID = site.id
        } label: {
            HStack(spacing: 10) {
                // 左侧统一文档图标（参考截图 2）
                Image(systemName: "doc.fill")
                    .font(.system(size: 15))
                    .foregroundColor(Color.white.opacity(0.85))

                // 中间站点名称与标签
                Text(site.siteTitle)
                    .font(.system(size: 14.5))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer()

                // 右侧亮蓝色选中对勾（参考截图 2）
                if tempSelectedID == site.id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Color(red: 0.0, green: 0.5, blue: 1.0))
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 右侧索引栏（参考截图 2）

    private var rightFastIndexBar: some View {
        VStack(spacing: 4) {
            Text("Top").font(.system(size: 10, weight: .medium))
            Text("|").font(.system(size: 9)).opacity(0.5)
            Text("文").font(.system(size: 11, weight: .medium))
            Text("|").font(.system(size: 9)).opacity(0.5)
            Text("图").font(.system(size: 11, weight: .medium))
            Text("|").font(.system(size: 9)).opacity(0.5)
            Text("音").font(.system(size: 11, weight: .medium))
            Text("|").font(.system(size: 9)).opacity(0.5)
            Text("视").font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(Color.white.opacity(0.45))
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }

    // MARK: - 数据分组与过滤

    private var filteredSites: [SwitchableSource] {
        let items = BookSourceLibrary.switchable(records: sources)
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return items }
        return items.filter {
            $0.name.lowercased().contains(needle) ||
            $0.note.lowercased().contains(needle) ||
            $0.host.lowercased().contains(needle) ||
            $0.group.lowercased().contains(needle)
        }
    }

    private struct SourceGroupSection: Identifiable {
        var name: String
        var sites: [SwitchableSource]
        var id: String { name }
    }

    private var groupedSites: [SourceGroupSection] {
        var order: [String] = []
        var map: [String: [SwitchableSource]] = [:]
        for item in filteredSites {
            let group = item.group.isEmpty ? "文本/小说" : item.group
            if map[group] == nil {
                order.append(group)
            }
            map[group, default: []].append(item)
        }
        let pinned = ["TOP", "文本/小说"]
        let rest = order.filter { !pinned.contains($0) }
        let finalOrder = pinned.filter { order.contains($0) } + rest
        return finalOrder.compactMap { name in
            guard let sites = map[name], !sites.isEmpty else { return nil }
            return SourceGroupSection(name: name, sites: sites)
        }
    }

    private func applySelection() {
        if let found = BookSourceLibrary.switchable(records: sources).first(where: { $0.id == tempSelectedID }) {
            selectedID = found.id
            onSelect(found)
        }
    }
}

// MARK: - 精致小说封面视图（参考截图 1：质感书脊、书名与右上角小红角标）

struct NovelCoverView: View {
    var title: String
    var author: String
    var badge: String
    var category: String

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // 背景渐变书封
            RoundedRectangle(cornerRadius: 4)
                .fill(gradientForCategory(category))
                .frame(width: 68, height: 92)
                .overlay(
                    // 书脊立体阴影
                    HStack {
                        LinearGradient(
                            colors: [Color.black.opacity(0.45), Color.clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 8)
                        Spacer()
                    }
                )
                .overlay(
                    // 书名与作者排版
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .shadow(color: .black.opacity(0.7), radius: 2, x: 0, y: 1)
                        Spacer()
                        if !author.isEmpty {
                            Text(author)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(Color.white.opacity(0.85))
                                .lineLimit(1)
                                .shadow(color: .black.opacity(0.6), radius: 1, x: 0, y: 1)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                )

            // 右上角红底白字小角标（如 "10万"、"完本"、"精选"）
            if !badge.isEmpty {
                Text(badge)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color(red: 0.9, green: 0.22, blue: 0.22))
                    .cornerRadius(3)
                    .padding(3)
            }
        }
        .frame(width: 68, height: 92)
        .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 2)
    }

    private func gradientForCategory(_ cat: String) -> LinearGradient {
        if cat.contains("玄幻") || cat.contains("奇幻") {
            return LinearGradient(
                colors: [Color(red: 0.10, green: 0.12, blue: 0.32), Color(red: 0.58, green: 0.22, blue: 0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else if cat.contains("仙侠") || cat.contains("武侠") {
            return LinearGradient(
                colors: [Color(red: 0.08, green: 0.24, blue: 0.28), Color(red: 0.16, green: 0.44, blue: 0.40)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else if cat.contains("科幻") || cat.contains("诸天") {
            return LinearGradient(
                colors: [Color(red: 0.10, green: 0.10, blue: 0.26), Color(red: 0.22, green: 0.16, blue: 0.48)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else if cat.contains("都市") || cat.contains("现实") {
            return LinearGradient(
                colors: [Color(red: 0.22, green: 0.16, blue: 0.16), Color(red: 0.38, green: 0.22, blue: 0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [Color(red: 0.16, green: 0.18, blue: 0.22), Color(red: 0.30, green: 0.34, blue: 0.40)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

// MARK: - 书源管理中心（保持 100% 向后兼容与外部导入功能）

struct SourceManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SourceRecord.addedAt) private var sources: [SourceRecord]

    @State private var name = ""
    @State private var address = ""
    @State private var errorText: String?
    @State private var showingImportSheet = false
    @State private var importSheetMode = 0

    var body: some View {
        List {
            Section {
                Button {
                    importSheetMode = 0
                    showingImportSheet = true
                } label: {
                    Label("导入精选推荐书源 (\(PresetBookSources.all.count))", systemImage: "sparkles")
                        .foregroundStyle(Color.accentColor)
                }

                Button {
                    importSheetMode = 1
                    showingImportSheet = true
                } label: {
                    Label("粘贴导入阅读 / 香色书源 JSON", systemImage: "doc.on.clipboard")
                }

                Button {
                    importSheetMode = 2
                    showingImportSheet = true
                } label: {
                    Label("通过网络 URL 一键订阅书源", systemImage: "link.badge.plus")
                }
            } header: {
                Text("快捷导入")
            }

            Section {
                TextField("名称（留空按主机名）", text: $name)
                TextField("地址（https://... 或局域网 http://...）", text: $address)
                    .autocorrectionDisabled()
                    #if os(iOS) || os(visionOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                Button("添加原生书源", action: add)
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("手动添加原生接口")
            }

            Section {
                if sources.isEmpty {
                    Text("还没有自定义书源，可点击上方导入推荐书源。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sources) { source in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(source.name).font(.headline)
                                Spacer()
                                badgeFor(source: source)
                                Toggle("", isOn: Bindable(source).enabled)
                                    .labelsHidden()
                            }
                            Text(source.baseURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete(perform: delete)
                }
            } header: {
                Text("已添加的书源 (\(sources.count))")
            }
        }
        .navigationTitle("书源管理")
        .sheet(isPresented: $showingImportSheet) {
            SourceImportSheet(initialMode: importSheetMode) { newSources in
                importSources(newSources)
            }
        }
        .alert("书源", isPresented: errorPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    @ViewBuilder
    private func badgeFor(source: SourceRecord) -> some View {
        switch source.format {
        case BookSourceKind.legado.rawValue:
            badgeView(title: "阅读 3.0", color: .green)
        case BookSourceKind.xiangse.rawValue:
            badgeView(title: "香色闺阁", color: .purple)
        default:
            badgeView(title: "标准接口", color: .blue)
        }
    }

    private func badgeView(title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })
    }

    private func add() {
        guard let url = SourceURL.parse(address) else {
            errorText = SourceError.badURL.errorDescription
            return
        }
        let normalized = url.absoluteString
        if sources.contains(where: { SourceURL.parse($0.baseURL)?.absoluteString == normalized }) {
            errorText = "这个书源已经添加"
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? (url.host ?? "书源") : trimmed
        modelContext.insert(SourceRecord(name: title, baseURL: normalized, format: "doudou"))
        try? modelContext.save()
        name = ""
        address = ""
    }

    private func importSources(_ parsedList: [UniversalBookSource]) {
        for source in parsedList {
            let normalizedURL = source.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if sources.contains(where: { $0.baseURL == normalizedURL && $0.name == source.name }) {
                continue
            }
            let rawJSON = (try? BookSourceParser.encode(source: source)) ?? source.rawJSON
            let record = SourceRecord(
                name: source.name,
                baseURL: normalizedURL,
                format: source.kind.rawValue,
                rawJSON: rawJSON
            )
            modelContext.insert(record)
        }
        try? modelContext.save()
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(sources[index])
        }
        try? modelContext.save()
    }
}

// MARK: - 书源导入弹窗

struct SourceImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    var initialMode: Int = 0
    var onImport: ([UniversalBookSource]) -> Void

    @State private var mode = 0
    @State private var textInput = ""
    @State private var urlInput = ""
    @State private var parsing = false
    @State private var errorText: String?
    @State private var previewSources: [UniversalBookSource] = []
    @State private var selectedIDs: Set<String> = []
    @State private var presetSelectedIDs: Set<String> = Set(PresetBookSources.all.map(\.id))

    init(initialMode: Int = 0, onImport: @escaping ([UniversalBookSource]) -> Void) {
        self.initialMode = initialMode
        self.onImport = onImport
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if previewSources.isEmpty {
                    Picker("导入方式", selection: $mode) {
                        Text("精选推荐 (10)").tag(0)
                        Text("粘贴书源").tag(1)
                        Text("网络链接").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding()

                    if mode == 0 {
                        presetSection
                    } else if mode == 1 {
                        pasteSection
                    } else {
                        urlSection
                    }
                } else {
                    previewSection
                }
            }
            .navigationTitle(previewSources.isEmpty ? (mode == 0 ? "精选推荐书源" : "导入书源") : "确认书源 (\(previewSources.count))")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(previewSources.isEmpty ? "取消" : "返回") {
                        if previewSources.isEmpty {
                            dismiss()
                        } else {
                            previewSources = []
                        }
                    }
                }
                if !previewSources.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("确认导入 (\(selectedIDs.count))") {
                            let chosen = previewSources.filter { selectedIDs.contains($0.id) }
                            onImport(chosen)
                            dismiss()
                        }
                        .disabled(selectedIDs.isEmpty)
                    }
                }
            }
            .alert("解析失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
    }

    private var presetSection: some View {
        VStack(spacing: 0) {
            HStack {
                Button(presetSelectedIDs.count == PresetBookSources.all.count ? "取消全选" : "全选 (\(PresetBookSources.all.count))") {
                    if presetSelectedIDs.count == PresetBookSources.all.count {
                        presetSelectedIDs.removeAll()
                    } else {
                        presetSelectedIDs = Set(PresetBookSources.all.map(\.id))
                    }
                }
                .font(.subheadline)
                Spacer()
                Text("已选 \(presetSelectedIDs.count) / \(PresetBookSources.all.count)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            List(PresetBookSources.all) { item in
                Button {
                    if presetSelectedIDs.contains(item.id) {
                        presetSelectedIDs.remove(item.id)
                    } else {
                        presetSelectedIDs.insert(item.id)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: presetSelectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(presetSelectedIDs.contains(item.id) ? .accentColor : .secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(item.fullDisplayName).font(.headline)
                                Spacer()
                                Text(item.kind.displayName)
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(item.kind == .legado ? Color.green.opacity(0.14) : Color.purple.opacity(0.14), in: Capsule())
                                    .foregroundStyle(item.kind == .legado ? Color.green : Color.purple)
                            }
                            Text(item.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            VStack {
                Button {
                    let chosen = PresetBookSources.all.filter { presetSelectedIDs.contains($0.id) }.map(\.source)
                    onImport(chosen)
                    dismiss()
                } label: {
                    Text("立即导入所选书源 (\(presetSelectedIDs.count))")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(presetSelectedIDs.isEmpty)
            }
            .padding()
        }
    }

    private var pasteSection: some View {
        VStack(spacing: 12) {
            Text("支持直接粘贴“阅读 3.0”单条或数组 JSON，以及“香色闺阁”书源配置。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

            TextEditor(text: $textInput)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)

            HStack {
                Button("从剪贴板粘贴") {
                    #if os(iOS) || os(visionOS)
                    if let string = UIPasteboard.general.string {
                        textInput = string
                    }
                    #elseif os(macOS)
                    if let string = NSPasteboard.general.string(forType: .string) {
                        textInput = string
                    }
                    #endif
                }
                Spacer()
                Button("清空") {
                    textInput = ""
                }
            }
            .font(.footnote)
            .padding(.horizontal)

            Button {
                parsePastedText()
            } label: {
                if parsing {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("解析书源")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parsing)
            .padding()
        }
    }

    private var urlSection: some View {
        VStack(spacing: 16) {
            Text("支持输入网络公开订阅链接，或阅读一键导入链接（legado://...）。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

            TextField("https://example.com/booksources.json", text: $urlInput)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS) || os(visionOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .padding(.horizontal)

            Button {
                Task { await fetchFromURL() }
            } label: {
                if parsing {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("拉取并解析")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parsing)
            .padding()

            Spacer()
        }
    }

    private var previewSection: some View {
        VStack(spacing: 0) {
            HStack {
                Button(selectedIDs.count == previewSources.count ? "取消全选" : "全选") {
                    if selectedIDs.count == previewSources.count {
                        selectedIDs.removeAll()
                    } else {
                        selectedIDs = Set(previewSources.map(\.id))
                    }
                }
                .font(.subheadline)
                Spacer()
                Text("已选 \(selectedIDs.count) / \(previewSources.count)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            List(previewSources) { source in
                Button {
                    if selectedIDs.contains(source.id) {
                        selectedIDs.remove(source.id)
                    } else {
                        selectedIDs.insert(source.id)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selectedIDs.contains(source.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selectedIDs.contains(source.id) ? .accentColor : .secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(source.name).font(.headline)
                                Spacer()
                                Text(source.kind.displayName)
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(source.kind == .legado ? Color.green.opacity(0.14) : Color.purple.opacity(0.14), in: Capsule())
                                    .foregroundStyle(source.kind == .legado ? Color.green : Color.purple)
                            }
                            Text(source.sourceURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func parsePastedText() {
        parsing = true
        defer { parsing = false }
        do {
            let parsed = try BookSourceParser.parse(text: textInput)
            previewSources = parsed
            selectedIDs = Set(parsed.map(\.id))
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func fetchFromURL() async {
        parsing = true
        defer { parsing = false }
        do {
            let parsed = try await BookSourceParser.fetchAndParse(from: urlInput)
            previewSources = parsed
            selectedIDs = Set(parsed.map(\.id))
        } catch {
            errorText = error.localizedDescription
        }
    }
}
