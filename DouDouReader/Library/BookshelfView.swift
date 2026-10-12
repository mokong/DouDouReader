import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum ShelfDestination: Hashable {
    case book(UUID)
    case search
}

enum HomeTab: Hashable {
    case shelf
    case discover
}

/// 主页两栏：书架接着读，发现页浏览当前书源。
struct HomeShell: View {
    @State private var tab = HomeTab.shelf
    @State private var shelfPath: [ShelfDestination] = []

    private var showsTabs: Bool {
        tab == .discover || shelfPath.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
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
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsTabs {
                homeTabs
            }
        }
        .background((tab == .discover ? Color.black : ShelfInk.paper).ignoresSafeArea())
        .preferredColorScheme(windowScheme)
        .onAppear(perform: openLaunchTab)
    }

    /// 阅读页自己决定明暗。发现页保持深色，书架保持暖纸色。
    private var windowScheme: ColorScheme? {
        if tab == .discover { return .dark }
        if shelfPath.contains(where: { if case .book = $0 { return true }; return false }) {
            return nil
        }
        return .light
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
                }
            }
            .geometryGroup()
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
        .task {
            if ProcessInfo.processInfo.arguments.contains("-openSearch") {
                try? await Task.sleep(nanoseconds: 300_000_000)
                openSearch()
            }
        }
        .onAppear {
            LogicChecks.exitIfRequested()
            try? BookLibrary.collapseOnlineDuplicates(context: modelContext)
            if ProcessInfo.processInfo.arguments.contains("-openSearch") {
                openSearch()
            }
            guard ProcessInfo.processInfo.arguments.contains("-openSample"), !didOpenSample else { return }
            didOpenSample = true
            openSample()
        }
        .onChange(of: path) { _, newValue in
            // 打开一本书时清掉它的更新角标：新目录已经随检查结果落库。
            if case .book(let id) = newValue.last, let book = books.first(where: { $0.id == id }) {
                if book.updateAvailable {
                    book.updateAvailable = false
                    try? modelContext.save()
                }
            }
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
                Task { await checkAllUpdates() }
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

    private func checkUpdate(book: BookRecord) async {
        updatingBookIDs.insert(book.id)
        defer { updatingBookIDs.remove(book.id) }

        let items = BookSourceLibrary.switchable(records: sourceRecords)
        guard let item = items.first(where: { $0.id == book.remoteSourceID }),
              let catalog = BookSourceLibrary.catalog(for: item) as? IncrementalBookCatalog else {
            book.lastCheckMessage = "书源失效，请换源"
            book.updateAvailable = false
            try? modelContext.save()
            notice = "《\(book.title)》书源失效，请换源"
            return
        }

        do {
            let toc = try await catalog.fetchTOC(bookID: book.remoteBookID)
            let local = RemoteChapterList.decode(book.remoteChapterList)
            let outcome = BookUpdateComparison.compare(local: local, remote: toc.chapters)
            book.remoteChapterList = RemoteChapterList.encode(toc.chapters)
            book.updateAvailable = outcome.hasUpdate
            book.newChapterCount = outcome.newChapterCount
            book.latestRemoteChapterTitle = outcome.latestTitle
            book.lastCheckMessage = outcome.hasUpdate ? "发现 \(outcome.newChapterCount) 章更新" : "已是最新"
            try? modelContext.save()
        } catch {
            book.lastCheckMessage = "书源失效，请换源"
            book.updateAvailable = false
            try? modelContext.save()
            notice = "《\(book.title)》检查失败：\(friendlyCheckError(error))"
        }
    }

    private func checkAllUpdates() async {
        checkingUpdates = true
        defer { checkingUpdates = false }
        let online = visibleBooks.filter { !$0.remoteBookID.isEmpty }
        guard !online.isEmpty else {
            notice = "书架上没有需要检查的在线书"
            return
        }
        var updated = 0
        var failed = 0
        for book in online {
            await checkUpdate(book: book)
            if book.updateAvailable {
                updated += 1
            } else if book.lastCheckMessage == "书源失效，请换源" {
                failed += 1
            }
        }
        notice = "检查完成：\(updated) 本有更新\(failed > 0 ? "，\(failed) 本书源失效" : "")"
    }

    private func friendlyCheckError(_ error: Error) -> String {
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
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(hue: book.coverHue, saturation: 0.45, brightness: 0.62))
            LinearGradient(
                colors: [.white.opacity(0.22), .clear, .black.opacity(0.18)],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                if book.isPinned && !compact {
                    Image(systemName: "pin.fill").font(.caption2)
                }
                Spacer(minLength: 0)
                Text(book.title)
                    .font(compact ? .system(size: 8, weight: .semibold) : .subheadline.weight(.semibold))
                    .lineLimit(compact ? 3 : 4)
            }
            .foregroundStyle(.white)
            .padding(compact ? 4 : 8)
        }
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
    }
}
