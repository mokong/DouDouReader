import SwiftData
import SwiftUI
import UniformTypeIdentifiers

extension RGBA {
    var color: Color {
        Color(red: r, green: g, blue: b, opacity: a)
    }
}

struct SettingsPanel: View {
    @Bindable var settings: ReaderSettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var importingFont = false
    @State private var fontMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("字体") {
                    Picker("字体", selection: $settings.fontName) {
                        ForEach(FontRegistry.available(current: settings.fontName)) { face in
                            Text(face.displayName).tag(face.postScriptName)
                        }
                    }
                    Button("导入字体") { importingFont = true }
                    labeledSlider("字号", value: $settings.fontSize, range: 14...36, step: 1, text: "\(Int(settings.fontSize.rounded()))")
                    labeledSlider("行距", value: $settings.lineSpacing, range: 0...36, step: 1, text: "\(Int(settings.lineSpacing.rounded()))")
                    labeledSlider("段距", value: $settings.paragraphSpacing, range: 0...48, step: 1, text: "\(Int(settings.paragraphSpacing.rounded()))")
                    Stepper("首行缩进 \(settings.indentChars)", value: $settings.indentChars, in: 0...4)
                    labeledSlider("字距", value: $settings.kern, range: -1...3, step: 0.5, text: String(format: "%.1f", settings.kern))
                    choiceRow("对齐") {
                        ChoiceButtons(
                            options: TextAlignmentChoice.allCases.map { ($0.title, $0) },
                            selection: settings.alignmentChoice
                        ) { settings.alignmentChoice = $0 }
                    }
                    labeledSlider("左右边距", value: $settings.horizontalMargin, range: 12...56, step: 1, text: "\(Int(settings.horizontalMargin.rounded()))")
                }
                Section("主题") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            Button("自动") { settings.themeID = "auto" }
                                .buttonStyle(.bordered)
                                .tint(settings.themeID == "auto" ? Color.accentColor : Color.secondary)
                            ForEach(ReadingThemes.choices) { theme in
                                Button {
                                    settings.themeID = theme.id
                                } label: {
                                    Circle()
                                        .fill(theme.background.color)
                                        .overlay {
                                            Circle().stroke(
                                                settings.themeID == theme.id ? Color.accentColor : Color.primary.opacity(0.15),
                                                lineWidth: 2
                                            )
                                        }
                                        .frame(width: 28, height: 28)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(theme.name)
                            }
                        }
                    }
                    labeledSlider("亮度", value: $settings.brightness, range: 0.45...1, step: 0.01, text: "\(Int(settings.brightness * 100))%")
                }
                Section("翻页") {
                    choiceRow("方式") {
                        ChoiceButtons(
                            options: PageTurnMode.allCases.map { ($0.title, $0) },
                            selection: settings.pageMode
                        ) { settings.pageMode = $0 }
                    }
                    choiceRow("简繁") {
                        ChoiceButtons(
                            options: ChineseScript.allCases.map { ($0.title, $0) },
                            selection: settings.script
                        ) { settings.script = $0 }
                    }
                    labeledSlider("自动间隔", value: $settings.autoInterval, range: 3...30, step: 1, text: "\(Int(settings.autoInterval.rounded())) 秒")
                    choiceRow("边缘返回") {
                        ChoiceButtons(
                            options: PopGestureMode.allCases.map { ($0.title, $0) },
                            selection: settings.popGesture
                        ) { settings.popGesture = $0 }
                    }
                    Toggle("屏幕常亮", isOn: $settings.keepScreenOn)
                }
                Section("页眉页脚") {
                    Toggle("时间", isOn: $settings.showTime)
                    Toggle("电量", isOn: $settings.showBattery)
                    Toggle("章节名", isOn: $settings.showChapterTitle)
                    Toggle("页码", isOn: $settings.showPageProgress)
                    Toggle("全书进度", isOn: $settings.showBookPercent)
                }
                Section("朗读") {
                    labeledSlider("语速", value: $settings.speechRate, range: 0.32...0.62, step: 0.01, text: String(format: "%.2f", settings.speechRate))
                    choiceRow("方式") {
                        ChoiceButtons(
                            options: SpeechReadMode.allCases.map { ($0.title, $0) },
                            selection: settings.speechMode
                        ) { settings.speechMode = $0 }
                    }
                    Picker("定时关闭", selection: $settings.sleepMinutes) {
                        Text("关").tag(0)
                        Text("20 分钟").tag(20)
                        Text("30 分钟").tag(30)
                        Text("60 分钟").tag(60)
                        Text("90 分钟").tag(90)
                    }
                }
                Section {
                    TextField("屏蔽词", text: $settings.blockWords, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text("屏蔽词")
                } footer: {
                    Text("用空格、逗号或换行隔开。包含这些词的段落不会显示。")
                }
            }
            .navigationTitle("设置")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                Button("完成") { dismiss() }
            }
        }
        .fileImporter(isPresented: $importingFont, allowedContentTypes: fontTypes, allowsMultipleSelection: false) { result in
            switch result {
            case .failure:
                fontMessage = "没有拿到字体"
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    let face = try FontRegistry.importFont(from: url)
                    settings.fontName = face.postScriptName
                    fontMessage = "已使用 \(face.displayName)"
                } catch {
                    fontMessage = error.localizedDescription
                }
            }
        }
        .alert("字体", isPresented: fontPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(fontMessage ?? "")
        }
    }

    private var fontPresented: Binding<Bool> {
        Binding(get: { fontMessage != nil }, set: { if !$0 { fontMessage = nil } })
    }

    private var fontTypes: [UTType] {
        var types: [UTType] = [.font]
        if let ttf = UTType("public.truetype-ttf-font") { types.append(ttf) }
        if let otf = UTType("public.opentype-font") { types.append(otf) }
        return types
    }

    private func labeledSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        text: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(text)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func choiceRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
            content()
        }
    }
}

struct ChoiceButtons<Value: Hashable>: View {
    var options: [(String, Value)]
    var selection: Value
    var select: (Value) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.0) { option in
                Button(option.0) { select(option.1) }
                    .buttonStyle(.bordered)
                    .tint(selection == option.1 ? Color.accentColor : Color.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// 目录行。在线书用保存下来的全部章节名；本地书没有远端目录，就用已经拆出来的章节。
nonisolated enum ReaderCatalog {
    struct Row: Equatable, Sendable, Identifiable {
        var index: Int
        var title: String
        var isLoaded: Bool
        var id: Int { index }
    }

    static func rows(engineTitles: [String], remoteTitles: [String], loadedIndices: Set<Int>) -> [Row] {
        if remoteTitles.isEmpty {
            return engineTitles.enumerated().map { index, title in
                Row(index: index, title: title, isLoaded: true)
            }
        }
        return remoteTitles.enumerated().map { index, raw in
            let remote = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let title: String
            if !remote.isEmpty {
                title = remote
            } else if engineTitles.indices.contains(index), !engineTitles[index].isEmpty {
                title = engineTitles[index]
            } else {
                title = "第\(index + 1)章"
            }
            return Row(index: index, title: title, isLoaded: loadedIndices.contains(index))
        }
    }
}

struct CatalogSheet: View {
    var engine: ReaderEngine
    var remoteTitles: [String]
    var loadedIndices: Set<Int>
    var status: String?
    var errorMessage: String?
    var onJump: (Int) -> Void
    var onRetry: () -> Void = {}
    var onSwitchSource: () -> Void = {}

    private var rows: [ReaderCatalog.Row] {
        ReaderCatalog.rows(
            engineTitles: engine.chapters.map(\.title),
            remoteTitles: remoteTitles,
            loadedIndices: loadedIndices
        )
    }

    private var currentMarker: Int? {
        guard !engine.isTerminal(engine.position),
              engine.chapters.indices.contains(engine.position.chapterIndex) else { return nil }
        let chapter = engine.chapters[engine.position.chapterIndex]
        return remoteTitles.isEmpty ? chapter.index : chapter.remoteIndex
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if !remoteTitles.isEmpty {
                        Section {
                            catalogRows
                        } header: {
                            Text("共 \(rows.count) 章，已下载 \(loadedIndices.count) 章")
                        }
                    } else {
                        catalogRows
                    }
                }
                .onAppear {
                    let current = currentMarker ?? 0
                    DispatchQueue.main.async {
                        proxy.scrollTo(current, anchor: .center)
                    }
                }
            }
            .navigationTitle("目录")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge: .bottom) {
                catalogNotice
            }
        }
    }

    private var catalogRows: some View {
        ForEach(rows) { row in
            Button {
                onJump(row.index)
            } label: {
                HStack {
                    Text(row.title)
                        .foregroundStyle(.primary)
                    Spacer()
                    if currentMarker == row.index {
                        Text("当前")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    } else if !row.isLoaded {
                        Text("未下载")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .id(row.index)
            .disabled(status != nil)
        }
    }

    @ViewBuilder
    private var catalogNotice: some View {
        if let status {
            HStack(spacing: 8) {
                ProgressView()
                Text(status)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.bar)
        } else if let errorMessage {
            VStack(spacing: 8) {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                HStack(spacing: 12) {
                    Button("重试", action: onRetry)
                    Button("换源", action: onSwitchSource)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}

struct SearchSheet: View {
    var engine: ReaderEngine
    var onPick: (Int) -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(engine.search(query)) { hit in
                Button {
                    onPick(hit.offset)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hit.chapterTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(hit.snippet)
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .overlay {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("输入想找的句子")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("搜索")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $query, prompt: "在本书中查找")
        }
    }
}

struct BookmarkSheet: View {
    var book: BookRecord
    var engine: ReaderEngine
    var onPick: (Int) -> Void
    @Environment(\.modelContext) private var modelContext

    private var marks: [BookmarkRecord] {
        book.bookmarks.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        NavigationStack {
            List {
                if marks.isEmpty {
                    Text("还没有书签")
                        .foregroundStyle(.secondary)
                }
                ForEach(marks, id: \.id) { mark in
                    Button {
                        onPick(mark.utf16Offset)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mark.chapterTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(mark.excerpt.isEmpty ? "空白页" : mark.excerpt)
                                .lineLimit(2)
                                .foregroundStyle(.primary)
                        }
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) {
                            modelContext.delete(mark)
                            try? modelContext.save()
                        }
                    }
                }
            }
            .navigationTitle("书签")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                Button("添加这一页", action: addCurrent)
            }
        }
    }

    private func addCurrent() {
        let offset = engine.currentUTF16()
        let chapterIndex = min(max(engine.position.chapterIndex, 0), max(engine.chapters.count - 1, 0))
        if book.bookmarks.contains(where: { $0.chapterIndex == chapterIndex && $0.utf16Offset == offset }) {
            return
        }
        let mark = BookmarkRecord(
            chapterIndex: chapterIndex,
            chapterTitle: engine.currentTitle,
            utf16Offset: offset,
            excerpt: engine.pageExcerpt()
        )
        mark.book = book
        if !book.bookmarks.contains(where: { $0.id == mark.id }) {
            book.bookmarks.append(mark)
        }
        try? modelContext.save()
    }
}

struct CacheSheet: View {
    var downloaded: Int
    var total: Int
    var running: Bool
    var status: String
    var canCache: Bool
    var onStart: () -> Void
    var onStop: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if canCache {
                    Text("已下载 \(downloaded) / \(total) 章")
                    if !status.isEmpty {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    if running {
                        Button("停止", action: onStop)
                    } else {
                        Button("从本章缓存到结尾", action: onStart)
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    Text("这本书已经在本地，不用缓存")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            .navigationTitle("缓存")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                Button("完成") { dismiss() }
            }
        }
    }
}
