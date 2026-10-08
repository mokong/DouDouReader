import SwiftData
import SwiftUI
import UniformTypeIdentifiers

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
    @Environment(ReaderSettingsStore.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Query private var books: [BookRecord]
    @AppStorage("shelf.sort") private var sortRaw = ShelfSort.recent.rawValue
    @AppStorage("shelf.group") private var groupFilter = "全部"
    @AppStorage("shelf.layout") private var layoutRaw = "grid"
    @State private var path: [UUID] = []
    @State private var query = ""
    @State private var importingText = false
    @State private var importingFont = false
    @State private var addingGroup = false
    @State private var newGroupName = ""
    @State private var groupTick = 0
    @State private var notice: String?
    @State private var pendingDelete: BookRecord?
    @State private var didOpenSample = false
    @State private var findingBooks = false

    private var sort: ShelfSort { ShelfSort(rawValue: sortRaw) ?? .recent }
    private var showsGrid: Bool { layoutRaw != "list" }

    private var groups: [String] {
        _ = groupTick
        return ShelfGroups.all(bookGroups: books.map(\.groupName))
    }

    private var visibleBooks: [BookRecord] {
        books.filter { book in
            let groupMatches = groupFilter == "全部" || book.groupName == groupFilter
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let textMatches = needle.isEmpty
                || book.title.localizedStandardContains(needle)
                || book.author.localizedStandardContains(needle)
            return groupMatches && textMatches
        }
        .sorted(by: sortBooks)
    }

    private var resumeBook: BookRecord? {
        books
            .filter { !$0.currentChapterTitle.isEmpty || $0.utf16Offset > 0 }
            .max { $0.lastReadAt < $1.lastReadAt }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                groupBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let resumeBook, groupFilter == "全部", query.isEmpty {
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
            .background(ShelfInk.paper.ignoresSafeArea())
            .navigationTitle("豆豆阅读")
            .navigationDestination(for: UUID.self) { id in
                if let book = books.first(where: { $0.id == id }) {
                    ReaderScreen(book: book)
                } else {
                    missingBook
                }
            }
            .searchable(text: $query, prompt: "搜索书名或作者")
            .toolbar { toolbar }
            #if os(iOS) || os(visionOS)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbarColorScheme(.light, for: .bottomBar)
            #endif
            .preferredColorScheme(.light)
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
        .alert("新建分组", isPresented: $addingGroup) {
            TextField("名称", text: $newGroupName)
            Button("添加") {
                ShelfGroups.add(newGroupName)
                newGroupName = ""
                groupTick += 1
            }
            Button("取消", role: .cancel) { newGroupName = "" }
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
        .sheet(isPresented: $findingBooks) {
            SourceBrowserView { id in
                findingBooks = false
                if !path.contains(id) {
                    path.append(id)
                }
            }
            #if os(iOS) || os(visionOS)
            .presentationDetents([.large])
            #endif
        }
        .onAppear {
            LogicChecks.exitIfRequested()
            if ProcessInfo.processInfo.arguments.contains("-openSources") {
                findingBooks = true
            }
            guard ProcessInfo.processInfo.arguments.contains("-openSample"), !didOpenSample else { return }
            didOpenSample = true
            openSample()
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
        return types
    }

    private var fontTypes: [UTType] {
        var types: [UTType] = []
        if let ttf = UTType("public.truetype-ttf-font") { types.append(ttf) }
        if let otf = UTType("public.opentype-font") { types.append(otf) }
        types.append(.font)
        return types
    }

    private var groupBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                groupChip("全部", selected: groupFilter == "全部") { groupFilter = "全部" }
                ForEach(groups, id: \.self) { name in
                    groupChip(name, selected: groupFilter == name) { groupFilter = name }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 150), spacing: 16)], spacing: 18) {
            ForEach(visibleBooks, id: \.id) { book in
                NavigationLink(value: book.id) {
                    VStack(alignment: .leading, spacing: 6) {
                        BookCover(book: book)
                        Text(book.author.isEmpty ? "未知作者" : book.author)
                            .font(.caption)
                            .foregroundStyle(ShelfInk.secondary)
                            .lineLimit(1)
                        Text(progressText(book))
                            .font(.caption2)
                            .foregroundStyle(ShelfInk.secondary)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu { bookMenu(book) }
            }
        }
    }

    private var list: some View {
        LazyVStack(spacing: 0) {
            ForEach(visibleBooks, id: \.id) { book in
                NavigationLink(value: book.id) {
                    HStack(spacing: 12) {
                        BookCover(book: book, compact: true)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(book.title)
                                    .font(.headline)
                                    .foregroundStyle(ShelfInk.ink)
                                    .lineLimit(1)
                                if book.isPinned {
                                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(ShelfInk.accent)
                                }
                            }
                            Text(book.author.isEmpty ? "未知作者" : book.author)
                                .font(.subheadline)
                                .foregroundStyle(ShelfInk.secondary)
                            Text("\(book.groupName) · \(progressText(book))")
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
            Text(books.isEmpty ? "书架还是空的" : "这个分组里没有书")
                .font(.headline)
                .foregroundStyle(ShelfInk.ink)
            Text("导入 txt，或先读一本示例。")
                .font(.subheadline)
                .foregroundStyle(ShelfInk.secondary)
            Button("放入示例《灯塔邮局》", action: openSample)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var missingBook: some View {
        ContentUnavailableView("找不到这本书", systemImage: "book.closed", description: Text("它可能刚被移出书架。"))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { importingText = true } label: { Label("导入文本", systemImage: "doc.text") }
                Button { importingFont = true } label: { Label("导入字体", systemImage: "textformat") }
                Button(action: openSample) { Label("示例小说", systemImage: "book") }
                Button { findingBooks = true } label: { Label("书源", systemImage: "dot.radiowaves.left.and.right") }
                Button { addingGroup = true } label: { Label("新建分组", systemImage: "folder.badge.plus") }
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
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ShelfInk.ink)
            }
            .accessibilityLabel("添加")
        }
    }

    private func continueCard(_ book: BookRecord) -> some View {
        NavigationLink(value: book.id) {
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

    private func groupChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(selected ? ShelfInk.accent : ShelfInk.chip, in: Capsule())
            .foregroundStyle(selected ? Color.white : ShelfInk.ink)
            .buttonStyle(.plain)
    }

    @ViewBuilder
    private func bookMenu(_ book: BookRecord) -> some View {
        Button {
            book.isPinned.toggle()
            try? modelContext.save()
        } label: {
            Label(book.isPinned ? "取消置顶" : "置顶", systemImage: book.isPinned ? "pin.slash" : "pin")
        }
        Menu("移动到分组") {
            ForEach(groups, id: \.self) { name in
                Button(name) {
                    book.groupName = name
                    try? modelContext.save()
                }
            }
        }
        Button("删除", role: .destructive) { pendingDelete = book }
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

    private func openSample() {
        do {
            let imported = try BookLibrary.importText(
                SampleNovel.text,
                suggestedTitle: SampleNovel.title,
                context: modelContext
            )
            if !path.contains(imported.book.id) {
                path.append(imported.book.id)
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

private enum ShelfInk {
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
