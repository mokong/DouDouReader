import SwiftData
import SwiftUI

struct SourceBrowserView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SourceRecord.addedAt) private var sources: [SourceRecord]
    var onOpen: (UUID) -> Void

    @State private var selectedID = SampleBookCatalog.stableID
    @State private var query = ""
    @State private var results: [CatalogBook] = []
    @State private var searching = false
    @State private var addingID: String?
    @State private var status = ""
    @State private var errorText: String?
    @State private var managing = false
    @State private var didPreview = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sourcePicker
                resultList
            }
            .navigationTitle("书源")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(iOS) || os(visionOS)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索书名或作者")
            #else
            .searchable(text: $query, prompt: "搜索书名或作者")
            #endif
            .onSubmit(of: .search) { Task { await search() } }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("管理") { managing = true }
                }
            }
            .navigationDestination(isPresented: $managing) {
                SourceManagerView()
            }
            .alert("书源", isPresented: errorPresented) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-openSources"), !didPreview else { return }
            didPreview = true
            query = "灯塔"
            await search()
        }
    }

    private var catalogs: [BookCatalog] {
        BookCatalogs.enabled(records: sources)
    }

    private var sourcePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(catalogs, id: \.id) { catalog in
                    Button(catalog.name) { selectedID = catalog.id }
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            selectedID == catalog.id ? Color.accentColor.opacity(0.18) : Color.black.opacity(0.05),
                            in: Capsule()
                        )
                        .foregroundStyle(selectedID == catalog.id ? Color.accentColor : Color.primary)
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var resultList: some View {
        if searching {
            ProgressView(status.isEmpty ? "正在查找" : status)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            ContentUnavailableView(
                query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "从书源找书" : "没有找到",
                systemImage: "text.book.closed",
                description: Text(emptyDescription)
            )
        } else {
            List(results) { book in
                Button {
                    Task { await add(book) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(book.title).font(.headline).foregroundStyle(.primary)
                        Text(book.author.isEmpty ? "未知作者" : book.author)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if !book.summary.isEmpty {
                            Text(book.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if addingID == book.id {
                            Text(status.isEmpty ? "正在加入书架" : status)
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .disabled(addingID != nil)
            }
        }
    }

    private var emptyDescription: String {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "选择一个书源，搜索后点进结果就会下载到书架。"
        }
        return "换个词，或检查这本书源是否开着。"
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })
    }

    private func search() async {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            results = []
            return
        }
        let catalog = catalogs.first { $0.id == selectedID } ?? SampleBookCatalog()
        searching = true
        status = ""
        defer { searching = false }
        do {
            results = try await catalog.search(query: needle)
            errorText = nil
        } catch {
            results = []
            errorText = error.localizedDescription
        }
    }

    private func add(_ book: CatalogBook) async {
        let catalog = catalogs.first { $0.id == selectedID } ?? SampleBookCatalog()
        addingID = book.id
        status = "正在下载"
        defer {
            addingID = nil
            status = ""
        }
        do {
            let fetched = try await catalog.fetchText(bookID: book.id) { done, total in
                Task { @MainActor in
                    status = "正在下载 \(done)/\(total)"
                }
            }
            let imported = try BookLibrary.importText(fetched.text, suggestedTitle: fetched.title, context: modelContext)
            onOpen(imported.book.id)
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct SourceManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SourceRecord.addedAt) private var sources: [SourceRecord]
    @State private var name = ""
    @State private var address = ""
    @State private var errorText: String?

    var body: some View {
        Form {
            Section("内置") {
                HStack {
                    Text("豆豆书库")
                    Spacer()
                    Text("示例").foregroundStyle(.secondary)
                }
            }
            Section("我的书源") {
                if sources.isEmpty {
                    Text("还没有添加").foregroundStyle(.secondary)
                }
                ForEach(sources) { source in
                    Toggle(isOn: Binding(
                        get: { source.enabled },
                        set: { source.enabled = $0; try? modelContext.save() }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name)
                            Text(source.baseURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .onDelete(perform: delete)
            }
            Section {
                TextField("名称", text: $name)
                TextField("https://example.com/catalog", text: $address)
                    #if os(iOS) || os(visionOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                Button("添加书源") { add() }
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("添加")
            } footer: {
                Text("接口为 JSON：GET /search?q= ，GET /books/{id} ，GET /books/{id}/chapters/{chapterId} 。公网用 https，本机可以用 http。")
            }
        }
        .navigationTitle("管理书源")
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("书源", isPresented: errorPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
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
        modelContext.insert(SourceRecord(name: title, baseURL: normalized))
        try? modelContext.save()
        name = ""
        address = ""
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(sources[index])
        }
        try? modelContext.save()
    }
}
