import SwiftData
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum ShelfDestination: Hashable {
    case book(UUID)
    case search
}

enum HomeTab: Hashable {
    case shelf
    case discover
}

/// 底部栏占位。书架滚动区和发现页留出同样高度，栏本身叠在上面，推入阅读页时不再把导航栈撑高或压矮。
private enum HomeChrome {
    static let tabBarHeight: CGFloat = 64
}

/// 主页两栏：书架接着读，发现页浏览当前书源。

struct HomeShell: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tab = HomeTab.shelf
    @State private var shelfPath: [ShelfDestination] = []
    /// 阅读页自己的明暗。推入过程中先保持书架的浅色，转场结束后再交给阅读页。
    @State private var readerOwnsScheme = false

    private var readerIsOpen: Bool {
        shelfPath.contains { if case .book = $0 { return true }; return false }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                BookshelfView(path: $shelfPath)
                    .opacity(tab == .shelf ? 1 : 0)
                    .allowsHitTesting(tab == .shelf)
                    .accessibilityHidden(tab != .shelf)
                if tab == .discover {
                    NavigationStack {
                        SourceBrowserView { id in
                            shelfPath = [.book(id)]
                            tab = .shelf
                        }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        homeTabs
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if tab == .shelf {
                homeTabs
                    .opacity(shelfPath.isEmpty ? 1 : 0)
                    .animation(nil, value: shelfPath.isEmpty)
                    .allowsHitTesting(shelfPath.isEmpty)
                    .accessibilityHidden(!shelfPath.isEmpty)
            }
        }
        .background((tab == .discover ? Color.black : ShelfInk.paper).ignoresSafeArea())
        .preferredColorScheme(windowScheme)
        .onAppear(perform: openLaunchTab)
        .onChange(of: shelfPath) { _, _ in
            syncReaderScheme()
        }
    }

    /// 阅读页自己决定明暗。发现页保持深色，书架保持暖纸色。
    /// 推入阅读页的那一下先不改窗口配色，否则转场中途整窗换色，动画会顿一下。
    private var windowScheme: ColorScheme? {
        if tab == .discover { return .dark }
        if readerOwnsScheme { return nil }
        return .light
    }

    private func syncReaderScheme() {
        guard readerIsOpen else {
            readerOwnsScheme = false
            return
        }
        #if os(iOS) || os(visionOS)
        let delay: Duration = reduceMotion ? .zero : .milliseconds(380)
        #else
        let delay: Duration = .zero
        #endif
        guard delay > .zero else {
            readerOwnsScheme = true
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            if readerIsOpen {
                readerOwnsScheme = true
            }
        }
    }

    private var homeTabs: some View {
        HStack(spacing: 0) {
            tabButton("书架", systemImage: "books.vertical", value: .shelf)
            tabButton("发现", systemImage: "safari", value: .discover)
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(tab == .discover ? Color.black : ShelfInk.paper)
    }

    private func tabButton(_ title: String, systemImage: String, value: HomeTab) -> some View {
        let selected = tab == value
        let idle = tab == .discover ? Color.white.opacity(0.55) : ShelfInk.secondary
        return Button {
            tab = value
        } label: {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: selected ? .semibold : .regular))
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? ShelfInk.accent : idle)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func openLaunchTab() {
        if ProcessInfo.processInfo.arguments.contains("-openSources") {
            tab = .discover
        }
    }
}

enum ShelfSort: String, CaseIterable, Identifiable {
    case recent
    case added
    case title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: "最近阅读"
        case .added: "加入时间"
        case .title: "书名"
        }
    }
}

struct BookshelfView: View {
    @Binding var path: [ShelfDestination]
    @Environment(ReaderSettingsStore.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Query private var books: [BookRecord]
    @Query private var sourceRecords: [SourceRecord]
    @AppStorage("shelf.sort") private var sortRaw = ShelfSort.recent.rawValue
    @AppStorage("shelf.layout") private var layoutRaw = "grid"
    @State private var importingText = false
    @State private var importingFont = false
    @State private var notice: String?
    @State private var pendingDelete: BookRecord?
    @State private var didOpenSample = false
    @State private var checkingUpdates = false
    @State private var updatingBookIDs: Set<UUID> = []
    @State private var showCacheManage = false
    @State private var didAutoCheck = false

    private var sort: ShelfSort { ShelfSort(rawValue: sortRaw) ?? .recent }
    private var showsGrid: Bool { layoutRaw != "list" }

    private var visibleBooks: [BookRecord] {
        books.sorted(by: sortBooks)
    }

    private var resumeBook: BookRecord? {
        books
            .filter { !$0.currentChapterTitle.isEmpty || $0.utf16Offset > 0 }
            .max { $0.lastReadAt < $1.lastReadAt }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                shelfBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let resumeBook {
                            continueCard(resumeBook)
                        }
                        if visibleBooks.isEmpty {
                            emptyState
                        } else if showsGrid {
                            grid
                        } else {
                            list
                        }
                    }
                    .padding(16)
                    .padding(.bottom, HomeChrome.tabBarHeight)
                }
                .refreshable {
                    // 提示要等这次刷新返回之后再弹。刷新过程中弹 alert 会取消任务，转圈就停不住。
                    let summary = await checkAllUpdates()
                    presentNoticeAfterRefresh(summary)
                }
            }
            .background(ShelfInk.paper.ignoresSafeArea())
            .navigationDestination(for: ShelfDestination.self) { destination in
                switch destination {
                case .book(let id):
                    if let book = books.first(where: { $0.id == id }) {
                        ReaderScreen(book: book)
                    } else {
                        missingBook
                    }
                case .search:
                    BookSearchView { id in
                        path = [.book(id)]
                    }
                }
            }
            #if os(iOS) || os(visionOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .tint(ShelfInk.accent)
        }
        .fileImporter(
            isPresented: $importingText,
            allowedContentTypes: textTypes,
            allowsMultipleSelection: true
        ) { result in
            importTexts(result)
        }
        .fileImporter(
            isPresented: $importingFont,
            allowedContentTypes: fontTypes,
            allowsMultipleSelection: false
        ) { result in
            importFont(result)
        }
        .alert("提示", isPresented: noticePresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
        .confirmationDialog(
            "从书架删除？",
            isPresented: deletePresented,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let book = pendingDelete {
                    try? BookLibrary.delete(book, context: modelContext)
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete.map { "《\($0.title)》会从书架和本地文件里删除。" } ?? "")
        }
        .sheet(isPresented: $showCacheManage) {
            CacheManageSheet()
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("-openSearch") {
                try? await Task.sleep(nanoseconds: 300_000_000)
                openSearch()
            }
        }
        .onAppear {
            LogicChecks.exitIfRequested()
            try? BookLibrary.collapseOnlineDuplicates(context: modelContext)
            // 每次冷启动自动静默检查一次书架更新，有新章节的书自动打上角标。
            if !didAutoCheck {
                didAutoCheck = true
                Task { await checkAllUpdates(silent: true) }
            }
            if ProcessInfo.processInfo.arguments.contains("-openSearch") {
                openSearch()
            }
            guard ProcessInfo.processInfo.arguments.contains("-openSample"), !didOpenSample else { return }
            didOpenSample = true
            openSample()
        }
        .onChange(of: path) { _, newValue in
            // 打开一本书时清掉它的更新角标。等推入动画结束再写库，避免转场中途刷新书架。
            guard case .book(let id) = newValue.last else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(380))
                guard case .book(let current) = path.last, current == id else { return }
                guard let book = books.first(where: { $0.id == id }), book.updateAvailable else { return }
                book.updateAvailable = false
                try? modelContext.save()
            }
        }
    }

    /// 下拉刷新的任务返回后，系统才会收起转圈。这里再等一小会儿，避开收起动画。
    private func presentNoticeAfterRefresh(_ message: String?) {
        guard let message else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            notice = message
        }
    }

    private var noticePresented: Binding<Bool> {
        Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var textTypes: [UTType] {
        var types: [UTType] = [.plainText, .utf8PlainText, .text]
        if let txt = UTType(filenameExtension: "txt") { types.append(txt) }
        if let epub = UTType("org.idpf.epub-container") { types.append(epub) }
        if let epub = UTType(filenameExtension: "epub") { types.append(epub) }
        return types
    }

    private var fontTypes: [UTType] {
        var types: [UTType] = []
        if let ttf = UTType("public.truetype-ttf-font") { types.append(ttf) }
        if let otf = UTType("public.opentype-font") { types.append(otf) }
        types.append(.font)
        return types
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 150), spacing: 16)], spacing: 18) {
            ForEach(visibleBooks, id: \.id) { book in
                NavigationLink(value: ShelfDestination.book(book.id)) {
                    BookCover(book: book)
                        .overlay(alignment: .topTrailing) {
                            updateBadge(book)
                                .padding(6)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(book.title)
                .contextMenu { bookMenu(book) }
            }
        }
    }

    private var list: some View {
        LazyVStack(spacing: 0) {
            ForEach(visibleBooks, id: \.id) { book in
                NavigationLink(value: ShelfDestination.book(book.id)) {
                    HStack(spacing: 12) {
                        BookCover(book: book, compact: true)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(book.title)
                                    .font(.headline)
                                    .foregroundStyle(ShelfInk.ink)
                                    .lineLimit(1)
                                updateBadge(book)
                                if book.isPinned {
                                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(ShelfInk.accent)
                                }
                            }
                            Text(book.author.isEmpty ? "未知作者" : book.author)
                                .font(.subheadline)
                                .foregroundStyle(ShelfInk.secondary)
                            Text(progressText(book))
                                .font(.caption)
                                .foregroundStyle(ShelfInk.secondary)
                            if !book.currentChapterTitle.isEmpty {
                                Text(book.currentChapterTitle)
                                    .font(.caption)
                                    .foregroundStyle(ShelfInk.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .contextMenu { bookMenu(book) }
                Rectangle()
                    .fill(ShelfInk.line)
                    .frame(height: 1)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.system(size: 42))
                .foregroundStyle(ShelfInk.accent)
            Text("书架还是空的")
                .font(.headline)
                .foregroundStyle(ShelfInk.ink)
            Text("点右上角加号导入 txt 或 EPUB，也可以先读示例。")
                .font(.subheadline)
                .foregroundStyle(ShelfInk.secondary)
                .multilineTextAlignment(.center)
            Button("放入示例《灯塔邮局》", action: openSample)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var missingBook: some View {
        ContentUnavailableView("找不到这本书", systemImage: "book.closed", description: Text("它可能刚被移出书架。"))
    }

    private var shelfBar: some View {
        HStack(spacing: 0) {
            shelfMenu
            Spacer(minLength: 0)
            Button(action: openSearch) {
                Image(systemName: "magnifyingglass")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("搜索书名或作者")
            Button {
                importingText = true
            } label: {
                Image(systemName: "plus")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("导入书籍")
        }
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(ShelfInk.ink)
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private var shelfMenu: some View {
        Menu {
            Button { importingFont = true } label: { Label("导入字体", systemImage: "textformat") }
            Divider()
            Picker("排序", selection: $sortRaw) {
                ForEach(ShelfSort.allCases) { item in
                    Text(item.title).tag(item.rawValue)
                }
            }
            Button {
                layoutRaw = showsGrid ? "list" : "grid"
            } label: {
                Label(showsGrid ? "列表" : "封面", systemImage: showsGrid ? "list.bullet" : "square.grid.2x2")
            }
            Divider()
            Button {
                showCacheManage = true
            } label: {
                Label("缓存管理", systemImage: "internaldrive")
            }
            Button {
                Task {
                    if let summary = await checkAllUpdates() {
                        notice = summary
                    }
                }
            } label: {
                Label(checkingUpdates ? "正在检查更新…" : "检查全部更新", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(checkingUpdates)
        } label: {
            ZStack {
                Image(systemName: "folder")
                    .font(.system(size: 20, weight: .semibold))
                if checkingUpdates {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 44, height: 44)
        }
        .accessibilityLabel("整理书架")
    }

    private func continueCard(_ book: BookRecord) -> some View {
        NavigationLink(value: ShelfDestination.book(book.id)) {
            HStack(spacing: 12) {
                BookCover(book: book, compact: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("继续阅读")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ShelfInk.accent)
                    Text(book.title)
                        .font(.headline)
                        .foregroundStyle(ShelfInk.ink)
                        .lineLimit(1)
                    Text(book.currentChapterTitle.isEmpty ? "从头开始" : book.currentChapterTitle)
                        .font(.subheadline)
                        .foregroundStyle(ShelfInk.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ShelfInk.secondary)
            }
            .padding(12)
            .background(ShelfInk.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(ShelfInk.line, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func bookMenu(_ book: BookRecord) -> some View {
        if !book.remoteBookID.isEmpty {
            Button {
                Task { await checkUpdate(book: book) }
            } label: {
                Label(updatingBookIDs.contains(book.id) ? "正在检查…" : "检查更新", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(updatingBookIDs.contains(book.id))
        }
        Button {
            book.isPinned.toggle()
            try? modelContext.save()
        } label: {
            Label(book.isPinned ? "取消置顶" : "置顶", systemImage: book.isPinned ? "pin.slash" : "pin")
        }
        Button("删除", role: .destructive) { pendingDelete = book }
    }

    /// 更新角标：在线书检查出有新章节时显示。
    @ViewBuilder
    private func updateBadge(_ book: BookRecord) -> some View {
        if book.updateAvailable {
            Text(book.newChapterCount > 0 ? "新 \(book.newChapterCount) 章" : "有更新")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.92), in: Capsule())
                .foregroundStyle(.white)
        }
    }

    /// 失败时返回要给用户看的那一句。批量检查自己决定什么时候弹，避免下拉刷新中途弹窗。
    @discardableResult
    private func checkUpdate(book: BookRecord, silent: Bool = false) async -> String? {
        updatingBookIDs.insert(book.id)
        defer { updatingBookIDs.remove(book.id) }

        let items = BookSourceLibrary.switchable(records: sourceRecords)
        guard let item = items.first(where: { $0.id == book.remoteSourceID }),
              let catalog = BookSourceLibrary.catalog(for: item) as? IncrementalBookCatalog else {
            book.lastCheckMessage = "书源失效，请换源"
            book.updateAvailable = false
            try? modelContext.save()
            let message = "《\(book.title)》书源失效，请换源"
            if !silent { notice = message }
            return message
        }

        do {
            let toc = try await catalog.fetchTOC(bookID: book.remoteBookID)
            let local = RemoteChapterList.decode(book.remoteChapterList)
            let outcome = BookUpdateComparison.compare(local: local, remote: toc.chapters)
            book.remoteChapterList = RemoteChapterList.encode(toc.chapters)
            if book.coverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !toc.coverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                book.coverURL = toc.coverURL
            }
            book.updateAvailable = outcome.hasUpdate
            book.newChapterCount = outcome.newChapterCount
            book.latestRemoteChapterTitle = outcome.latestTitle
            book.lastCheckMessage = outcome.hasUpdate ? "发现 \(outcome.newChapterCount) 章更新" : "已是最新"
            try? modelContext.save()
            return nil
        } catch {
            book.lastCheckMessage = "书源失效，请换源"
            book.updateAvailable = false
            try? modelContext.save()
            let message = "《\(book.title)》检查失败：\(Self.friendlyCheckError(error))"
            if !silent { notice = message }
            return message
        }
    }

    /// 批量检查：采用受控并发（最多 5 路并发），全量完成后批量落盘一次，避免逐本保存引起书架频繁重排。
    @discardableResult
    private func checkAllUpdates(silent: Bool = false) async -> String? {
        checkingUpdates = true
        defer {
            checkingUpdates = false
            updatingBookIDs.removeAll()
        }
        let online = visibleBooks.filter { !$0.remoteBookID.isEmpty }
        guard !online.isEmpty else {
            return silent ? nil : "书架上没有需要检查的在线书"
        }
        online.forEach { updatingBookIDs.insert($0.id) }

        let switchableSources = BookSourceLibrary.switchable(records: sourceRecords)
        struct BookUpdateTask: Sendable {
            var id: UUID
            var title: String
            var remoteSourceID: String
            var remoteBookID: String
        }
        struct BookUpdateResult: Sendable {
            var id: UUID
            var title: String
            var chapters: [RemoteChapterRef]?
            var coverURL: String = ""
            var errorMessage: String?
        }

        let tasks = online.map {
            BookUpdateTask(
                id: $0.id,
                title: $0.title,
                remoteSourceID: $0.remoteSourceID,
                remoteBookID: $0.remoteBookID
            )
        }

        let concurrency = min(5, tasks.count)
        var updated = 0
        var failures: [String] = []

        await withTaskGroup(of: BookUpdateResult.self) { group in
            var taskIndex = 0
            func enqueue() {
                guard taskIndex < tasks.count else { return }
                let item = tasks[taskIndex]
                taskIndex += 1
                group.addTask {
                    guard let source = switchableSources.first(where: { $0.id == item.remoteSourceID }),
                          let catalog = BookSourceLibrary.catalog(for: source) as? IncrementalBookCatalog else {
                        return BookUpdateResult(id: item.id, title: item.title, chapters: nil, errorMessage: "书源失效，请换源")
                    }
                    do {
                        let toc = try await catalog.fetchTOC(bookID: item.remoteBookID)
                        return BookUpdateResult(id: item.id, title: item.title, chapters: toc.chapters, coverURL: toc.coverURL, errorMessage: nil)
                    } catch {
                        return BookUpdateResult(id: item.id, title: item.title, chapters: nil, errorMessage: Self.friendlyCheckError(error))
                    }
                }
            }

            for _ in 0..<concurrency {
                enqueue()
            }

            while let res = await group.next() {
                updatingBookIDs.remove(res.id)
                if let book = online.first(where: { $0.id == res.id }) {
                    if let remoteChapters = res.chapters {
                        let local = RemoteChapterList.decode(book.remoteChapterList)
                        let outcome = BookUpdateComparison.compare(local: local, remote: remoteChapters)
                        book.remoteChapterList = RemoteChapterList.encode(remoteChapters)
                        if book.coverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           !res.coverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            book.coverURL = res.coverURL
                        }
                        book.updateAvailable = outcome.hasUpdate
                        book.newChapterCount = outcome.newChapterCount
                        book.latestRemoteChapterTitle = outcome.latestTitle
                        book.lastCheckMessage = outcome.hasUpdate ? "发现 \(outcome.newChapterCount) 章更新" : "已是最新"
                        if outcome.hasUpdate { updated += 1 }
                    } else {
                        let errorMsg = res.errorMessage ?? "书源失效，请换源"
                        book.lastCheckMessage = errorMsg
                        book.updateAvailable = false
                        failures.append("《\(res.title)》\(errorMsg)")
                    }
                }
                enqueue()
            }
        }

        // 仅在全量并发拉取完成后统一保存一次，消除反复重排
        try? modelContext.save()

        guard !silent else { return nil }
        if updated == 0, failures.count == 1 {
            return failures[0]
        }
        let failedNote = failures.isEmpty ? "" : "，\(failures.count) 本书源失效"
        return "检查完成：\(updated) 本有更新\(failedNote)"
    }

    private nonisolated static func friendlyCheckError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost:
                return "网络异常，请稍后重试"
            default:
                break
            }
        }
        if let sourceError = error as? SourceError {
            switch sourceError {
            case .emptyBook, .notFound:
                return "书源失效，请换源"
            default:
                return "书源失效，请换源"
            }
        }
        return "书源失效，请换源"
    }

    private func progressText(_ book: BookRecord) -> String {
        guard book.totalUTF16 > 0 else { return "0 字" }
        if book.utf16Offset <= 0 { return "\(book.totalUTF16) 字" }
        let percent = min(100, Int((Double(book.utf16Offset) / Double(book.totalUTF16) * 100).rounded()))
        return "\(percent)% · \(book.totalUTF16) 字"
    }

    private func sortBooks(_ lhs: BookRecord, _ rhs: BookRecord) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
        switch sort {
        case .recent:
            if lhs.lastReadAt != rhs.lastReadAt { return lhs.lastReadAt > rhs.lastReadAt }
        case .added:
            if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
        case .title:
            let order = lhs.title.localizedStandardCompare(rhs.title)
            if order != .orderedSame { return order == .orderedAscending }
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private func openSearch() {
        if !path.contains(.search) {
            path.append(.search)
        }
    }

    private func openSample() {
        do {
            let imported = try BookLibrary.importText(
                SampleNovel.text,
                suggestedTitle: SampleNovel.title,
                context: modelContext
            )
            let destination = ShelfDestination.book(imported.book.id)
            if !path.contains(destination) {
                path.append(destination)
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    private func importTexts(_ result: Result<[URL], Error>) {
        switch result {
        case .failure:
            notice = "没有拿到文件"
        case .success(let urls):
            var created = 0
            var existing = 0
            var failed: String?
            for url in urls {
                do {
                    let imported = try BookLibrary.importFile(url: url, context: modelContext)
                    if imported.isNew { created += 1 } else { existing += 1 }
                } catch {
                    failed = error.localizedDescription
                }
            }
            if let failed, created == 0, existing == 0 {
                notice = failed
            } else if let failed {
                notice = "导入了 \(created) 本。\(failed)"
            } else if created == 0, existing > 0 {
                notice = "这些书已经在书架上"
            }
        }
    }

    private func importFont(_ result: Result<[URL], Error>) {
        switch result {
        case .failure:
            notice = "没有拿到字体"
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let face = try FontRegistry.importFont(from: url)
                settings.fontName = face.postScriptName
                notice = "已加入字体 \(face.displayName)"
            } catch {
                notice = error.localizedDescription
            }
        }
    }
}

enum ShelfInk {
    static let paper = Color(red: 0.965, green: 0.945, blue: 0.906)
    static let card = Color(red: 0.995, green: 0.988, blue: 0.972)
    static let chip = Color(red: 0.910, green: 0.870, blue: 0.800)
    static let ink = Color(red: 0.173, green: 0.141, blue: 0.086)
    static let secondary = Color(red: 0.40, green: 0.33, blue: 0.25)
    static let accent = Color(red: 0.45, green: 0.28, blue: 0.16)
    static let line = Color(red: 0.173, green: 0.141, blue: 0.086).opacity(0.10)
}

struct BookCover: View {
    var book: BookRecord
    var compact = false

    var body: some View {
        let width: CGFloat = compact ? 46 : 108
        let height: CGFloat = compact ? 66 : 154
        ZStack(alignment: .topLeading) {
            BookCoverImageView(coverURL: book.coverURL, fileName: book.fileName) {
                fallbackCover
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .leading) {
                // 书脊立体折痕阴影
                LinearGradient(
                    colors: [.black.opacity(0.28), .white.opacity(0.10), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: compact ? 5 : 10)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.black.opacity(0.08), lineWidth: 0.5)
            }

            if book.isPinned && !compact {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(.black.opacity(0.38), in: Circle())
                    .padding(6)
            }
        }
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
    }

    private var fallbackCover: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(hue: book.coverHue, saturation: 0.45, brightness: 0.62))
            LinearGradient(
                colors: [.white.opacity(0.22), .clear, .black.opacity(0.18)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 4) {
                Spacer(minLength: 0)
                Text(book.title)
                    .font(compact ? .system(size: 8, weight: .semibold) : .subheadline.weight(.semibold))
                    .lineLimit(compact ? 3 : 4)
            }
            .foregroundStyle(.white)
            .padding(compact ? 4 : 8)
        }
    }
}

/// 跨書架、发现页、搜索页复用的封面加载器：
/// 1. 支持本地 EPUB/已落盘封面（`BookStorage.readCover`）
/// 2. 支持远程封面并自动附带 `Referer` 与浏览器 `User-Agent`，突破小说站图片防盗链
/// 3. 内存 `NSCache` + 书架本地磁盘双层缓存
enum BookCoverLoader {
    #if os(iOS) || os(visionOS)
    typealias PlatformImage = UIImage
    #elseif os(macOS)
    typealias PlatformImage = NSImage
    #endif

    nonisolated(unsafe) private static let memoryCache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.countLimit = 240
        return cache
    }()

    nonisolated static func cacheKey(coverURL: String, fileName: String) -> String {
        let trimmedURL = coverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedURL.isEmpty {
            return trimmedURL
        }
        if !fileName.isEmpty {
            return "local://\(fileName)"
        }
        return ""
    }

    static func cachedImage(coverURL: String, fileName: String) -> Image? {
        let key = cacheKey(coverURL: coverURL, fileName: fileName)
        guard !key.isEmpty, let platform = memoryCache.object(forKey: key as NSString) else {
            return nil
        }
        return swiftUIImage(from: platform)
    }

    static func loadImage(coverURL: String, fileName: String) async -> Image? {
        let key = cacheKey(coverURL: coverURL, fileName: fileName)
        guard !key.isEmpty else { return nil }
        if let cached = memoryCache.object(forKey: key as NSString) {
            return swiftUIImage(from: cached)
        }

        let trimmedURL = coverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let localFile: String = {
            if !fileName.isEmpty { return fileName }
            if trimmedURL.hasPrefix("local://") {
                return String(trimmedURL.dropFirst("local://".count))
            }
            return ""
        }()

        return await Task.detached(priority: .utility) { () -> Image? in
            if !localFile.isEmpty,
               let data = BookStorage.readCover(fileName: localFile),
               let platform = makePlatformImage(from: data) {
                memoryCache.setObject(platform, forKey: key as NSString)
                return swiftUIImage(from: platform)
            }

            guard !trimmedURL.isEmpty,
                  !trimmedURL.hasPrefix("local://"),
                  !RuleBasedBookCatalog.isPlaceholderCover(trimmedURL),
                  let url = URL(string: trimmedURL),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return nil
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            if let host = url.host {
                request.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
            }

            guard let (data, response) = try? await RuleBasedBookCatalog.configuredSession.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  data.count >= 64,
                  let platform = makePlatformImage(from: data) else {
                return nil
            }

            memoryCache.setObject(platform, forKey: key as NSString)
            if !localFile.isEmpty {
                BookStorage.writeCover(data, for: localFile)
            }
            return swiftUIImage(from: platform)
        }.value
    }

    nonisolated private static func makePlatformImage(from data: Data) -> PlatformImage? {
        #if os(iOS) || os(visionOS)
        return UIImage(data: data)
        #elseif os(macOS)
        return NSImage(data: data)
        #endif
    }

    nonisolated private static func swiftUIImage(from platform: PlatformImage) -> Image {
        #if os(iOS) || os(visionOS)
        return Image(uiImage: platform)
        #elseif os(macOS)
        return Image(nsImage: platform)
        #endif
    }
}

struct BookCoverImageView<Fallback: View>: View {
    var coverURL: String
    var fileName: String = ""
    @ViewBuilder var fallback: () -> Fallback

    @State private var loadedImage: Image?

    var body: some View {
        let activeImage = loadedImage ?? BookCoverLoader.cachedImage(coverURL: coverURL, fileName: fileName)
        GeometryReader { proxy in
            if let activeImage {
                activeImage
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            } else {
                fallback()
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .task(id: BookCoverLoader.cacheKey(coverURL: coverURL, fileName: fileName)) {
            if let cached = BookCoverLoader.cachedImage(coverURL: coverURL, fileName: fileName) {
                loadedImage = cached
                return
            }
            loadedImage = await BookCoverLoader.loadImage(coverURL: coverURL, fileName: fileName)
        }
    }
}

/// 全局缓存管理：列出有章节缓存的在线书，显示占用与章数，按书清理或全部清理。
struct CacheManageSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var books: [BookRecord]
    @State private var sizes: [UUID: Int64] = [:]
    @State private var totalSize: Int64 = 0
    @State private var cachedBookIDs: Set<UUID> = []

    private var cachedBooks: [BookRecord] {
        books.filter { cachedBookIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("总占用 \(ByteFormat.string(totalSize))") {
                    if cachedBooks.isEmpty {
                        Text("还没有章节缓存")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(cachedBooks) { book in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(book.title)
                                        .font(.headline)
                                    Text("\(ByteFormat.string(sizes[book.id] ?? 0)) · 已缓存 \(book.loadedChapterCount) 章")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("清理") { clear(book) }
                                    .tint(.red)
                            }
                        }
                    }
                }
                if !cachedBooks.isEmpty {
                    Section {
                        Button("清理全部章节缓存", role: .destructive) { clearAll() }
                    } footer: {
                        Text("只删除已下载的章节正文，书架记录与整本 txt 保留。")
                    }
                }
            }
            .navigationTitle("缓存管理")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                Button("完成") { dismiss() }
            }
            .onAppear(perform: reload)
        }
    }

    private func reload() {
        let snapshot = books
            .filter { !$0.remoteBookID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { ($0.id, $0.fileName) }
        Task.detached(priority: .utility) {
            var map: [UUID: Int64] = [:]
            var total: Int64 = 0
            var cached = Set<UUID>()
            for (id, fileName) in snapshot {
                if StoredChapters.hasCache(fileName: fileName) {
                    cached.insert(id)
                    let size = StoredChapters.cacheSize(fileName: fileName)
                    map[id] = size
                    total += size
                }
            }
            await MainActor.run {
                sizes = map
                totalSize = total
                cachedBookIDs = cached
            }
        }
    }

    private func clear(_ book: BookRecord) {
        StoredChapters.delete(fileName: book.fileName)
        book.loadedChapterCount = 0
        try? modelContext.save()
        reload()
    }

    private func clearAll() {
        for book in cachedBooks {
            StoredChapters.delete(fileName: book.fileName)
            book.loadedChapterCount = 0
        }
        try? modelContext.save()
        reload()
    }
}
