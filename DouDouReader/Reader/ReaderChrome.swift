import AVFoundation
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
    @State private var activeTab: Tab = .typography
    @State private var showFineSpacing = false
    @State private var importingFont = false
    @State private var fontMessage: String?
    @State private var speechVoices = SpeechController.chineseVoices()

    enum Tab: String, CaseIterable, Identifiable {
        case typography = "排版"
        case pageAndChrome = "翻页与界面"
        case speechAndPurify = "听书与净化"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.4)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    switch activeTab {
                    case .typography:
                        typographySection
                    case .pageAndChrome:
                        pageAndChromeSection
                    case .speechAndPurify:
                        speechAndPurifySection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .background(.regularMaterial)
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

    private var headerBar: some View {
        HStack(spacing: 12) {
            Picker("设置分类", selection: $activeTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Button("完成") { dismiss() }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Tab 1: 排版与主题（香色闺阁紧凑实时预览风格）
    private var typographySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 1. 亮度调节条
            HStack(spacing: 10) {
                Image(systemName: "sun.min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $settings.brightness, in: 0.15...1.0, step: 0.01)
                Image(systemName: "sun.max.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(Int((settings.brightness * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }

            // 2. 香色经典护眼色卡横排
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    themeAutomaticChip
                    ForEach(ReadingThemes.choices) { theme in
                        themeSwatchChip(theme)
                    }
                }
                .padding(.vertical, 2)
            }

            // 3. 字号微调 + 简繁快切
            HStack(spacing: 10) {
                Button {
                    if settings.fontSize > 14 { settings.fontSize -= 1 }
                } label: {
                    Text("A-")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 38, height: 32)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(settings.fontSize <= 14)

                HStack(spacing: 6) {
                    Slider(value: $settings.fontSize, in: 14...36, step: 1)
                    Text("\(Int(settings.fontSize.rounded()))")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                }

                Button {
                    if settings.fontSize < 36 { settings.fontSize += 1 }
                } label: {
                    Text("A+")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 38, height: 32)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(settings.fontSize >= 36)

                Divider().frame(height: 20)

                HStack(spacing: 4) {
                    ForEach(ChineseScript.allCases) { script in
                        let selected = settings.script == script
                        Button(script.title) {
                            settings.script = script
                        }
                        .font(.caption.weight(selected ? .semibold : .regular))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
                        .buttonStyle(.plain)
                    }
                }
            }

            // 4. 字体横向胶囊 + 导入字体
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(FontRegistry.available(current: settings.fontName)) { face in
                            let selected = settings.fontName == face.postScriptName
                            Button {
                                settings.fontName = face.postScriptName
                            } label: {
                                Text(face.displayName)
                                    .font(.caption.weight(selected ? .semibold : .regular))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06),
                                        in: Capsule()
                                    )
                                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Button {
                    importingFont = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus.circle")
                        Text("导入")
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            // 5. 间距预设档位 + 展开微调 + 恢复默认
            HStack(spacing: 8) {
                Text("间距")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(SpacingPreset.allCases) { preset in
                    let active = settings.activeSpacingPreset == preset
                    Button(preset.title) {
                        settings.apply(preset: preset)
                    }
                    .font(.caption.weight(active ? .semibold : .regular))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        active ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06),
                        in: Capsule()
                    )
                    .foregroundStyle(active ? Color.accentColor : Color.primary)
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 4)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showFineSpacing.toggle()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("更多排版")
                        Image(systemName: showFineSpacing ? "chevron.up" : "chevron.down")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)

                Button("重置") {
                    settings.resetTypography()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }

            if showFineSpacing {
                VStack(spacing: 10) {
                    compactSlider("行距", value: $settings.lineSpacing, range: 0...36, step: 1, text: "\(Int(settings.lineSpacing.rounded()))")
                    compactSlider("段距", value: $settings.paragraphSpacing, range: 0...48, step: 1, text: "\(Int(settings.paragraphSpacing.rounded()))")
                    compactSlider("左右边距", value: $settings.horizontalMargin, range: 12...56, step: 1, text: "\(Int(settings.horizontalMargin.rounded()))")
                    compactSlider(
                        "上下边距",
                        value: Binding(
                            get: { settings.topMargin },
                            set: {
                                settings.topMargin = $0
                                settings.bottomMargin = $0
                            }
                        ),
                        range: 0...36,
                        step: 1,
                        text: "\(Int(settings.topMargin.rounded()))"
                    )
                    compactSlider("字距", value: $settings.kern, range: -1...3, step: 0.5, text: String(format: "%.1f", settings.kern))
                    HStack {
                        Text("首行缩进")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Stepper("\(settings.indentChars) 格", value: $settings.indentChars, in: 0...4)
                            .font(.caption.monospacedDigit())
                    }
                    HStack {
                        Text("对齐方式")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        ChoiceButtons(
                            options: TextAlignmentChoice.allCases.map { ($0.title, $0) },
                            selection: settings.alignmentChoice
                        ) { settings.alignmentChoice = $0 }
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var themeAutomaticChip: some View {
        let selected = settings.themeID == "auto"
        return Button {
            settings.themeID = "auto"
        } label: {
            Text("自动")
                .font(.caption.weight(selected ? .semibold : .regular))
                .frame(width: 44, height: 32)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 2 : 1)
                }
        }
        .buttonStyle(.plain)
    }

    private func themeSwatchChip(_ theme: ReadingTheme) -> some View {
        let selected = settings.themeID == theme.id
        return Button {
            settings.themeID = theme.id
        } label: {
            Text(theme.name)
                .font(.caption.weight(selected ? .semibold : .regular))
                .foregroundStyle(theme.text.color)
                .frame(width: 46, height: 32)
                .background(theme.background.color, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 2 : 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.name)
    }

    // MARK: - Tab 2: 翻页与界面
    private var pageAndChromeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("翻页动画")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ChoiceButtons(
                    options: PageTurnMode.allCases.map { ($0.title, $0) },
                    selection: settings.pageMode
                ) { settings.pageMode = $0 }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("页眉与页脚挂件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    toggleChip("时间", isOn: $settings.showTime)
                    toggleChip("电量", isOn: $settings.showBattery)
                    toggleChip("章节名", isOn: $settings.showChapterTitle)
                    toggleChip("页码", isOn: $settings.showPageProgress)
                    toggleChip("进度%", isOn: $settings.showBookPercent)
                }
            }

            compactSlider(
                "自动翻页间隔",
                value: $settings.autoInterval,
                range: 3...30,
                step: 1,
                text: "\(Int(settings.autoInterval.rounded())) 秒"
            )

            HStack {
                Text("左边缘返回手势")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                ChoiceButtons(
                    options: PopGestureMode.allCases.map { ($0.title, $0) },
                    selection: settings.popGesture
                ) { settings.popGesture = $0 }
            }

            Toggle("阅读时屏幕常亮", isOn: $settings.keepScreenOn)
                .font(.subheadline)
        }
    }

    private func toggleChip(_ title: String, isOn: Binding<Bool>) -> some View {
        let active = isOn.wrappedValue
        return Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(title)
                .font(.caption.weight(active ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    active ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab 3: 听书与净化
    private var speechAndPurifySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            compactSlider(
                "朗读语速",
                value: $settings.speechRate,
                range: 0.32...0.8,
                step: 0.01,
                text: String(format: "%.2fx", settings.speechRate)
            )

            HStack {
                Text("中文发音人")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("音色", selection: $settings.speechVoiceID) {
                    Text("系统默认").tag("")
                    ForEach(speechVoices, id: \.identifier) { voice in
                        Text("\(voice.name)（\(voice.language)）").tag(voice.identifier)
                    }
                }
                .labelsHidden()
            }

            HStack {
                Text("朗读粒度")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                ChoiceButtons(
                    options: SpeechReadMode.allCases.map { ($0.title, $0) },
                    selection: settings.speechMode
                ) { settings.speechMode = $0 }
            }

            HStack {
                Text("定时关闭")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("定时关闭", selection: $settings.sleepMinutes) {
                    Text("关").tag(0)
                    Text("20 分钟").tag(20)
                    Text("30 分钟").tag(30)
                    Text("60 分钟").tag(60)
                    Text("90 分钟").tag(90)
                }
                .labelsHidden()
            }

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 6) {
                Text("正文净化与替换规则")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("输入屏蔽词，或使用 原词=>替换词 精准替换", text: $settings.blockWords, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                    .font(.caption)
                Text("用换行、逗号或分号分隔。短句广告整行剔除；长文段内水印自动抹除不删段；支持 原词=>替换词 与 re:正则=>替换。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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

    private func compactSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        text: String
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(text)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
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
    @Environment(\.dismiss) private var dismiss

    @State private var isAscending = true
    @State private var searchText = ""
    @State private var allRows: [ReaderCatalog.Row] = []

    private func reloadAllRows() {
        allRows = ReaderCatalog.rows(
            engineTitles: engine.chapters.map(\.title),
            remoteTitles: remoteTitles,
            loadedIndices: loadedIndices
        )
    }

    private var displayedRows: [ReaderCatalog.Row] {
        let base = isAscending ? allRows : Array(allRows.reversed())
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return base }
        return base.filter { $0.title.lowercased().contains(query) }
    }

    private var currentMarker: Int? {
        if !engine.isTerminal(engine.position),
           engine.chapters.indices.contains(engine.position.chapterIndex) {
            let chapter = engine.chapters[engine.position.chapterIndex]
            return remoteTitles.isEmpty ? chapter.index : chapter.remoteIndex
        }
        // 停在末尾页（刚读完最新章）：定位到已下载的最后一章，而不是列表开头。
        if let last = engine.chapters.last {
            return remoteTitles.isEmpty ? last.index : last.remoteIndex
        }
        return nil
    }

    var body: some View {
        let displayed = displayedRows
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        if displayed.isEmpty {
                            Text("未找到匹配章节")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 24)
                        } else {
                            catalogRows(displayed)
                        }
                    } header: {
                        catalogHeader(displayedCount: displayed.count)
                    }
                }
                .searchable(text: $searchText, prompt: "搜索章节名")
                .onAppear {
                    reloadAllRows()
                    let current = currentMarker ?? 0
                    DispatchQueue.main.async {
                        proxy.scrollTo(current, anchor: .center)
                    }
                }
                .onChange(of: loadedIndices) { _, _ in reloadAllRows() }
                .onChange(of: engine.chapters.count) { _, _ in reloadAllRows() }
                .toolbar {
                    #if os(iOS) || os(visionOS)
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 14) {
                            if let currentMarker {
                                Button {
                                    withAnimation {
                                        proxy.scrollTo(currentMarker, anchor: .center)
                                    }
                                } label: {
                                    Image(systemName: "scope")
                                }
                                .accessibilityLabel("定位当前章节")
                            }
                            Button {
                                withAnimation {
                                    isAscending.toggle()
                                }
                            } label: {
                                Image(systemName: isAscending ? "arrow.down" : "arrow.up")
                            }
                            .accessibilityLabel(isAscending ? "倒序排列" : "正序排列")
                        }
                    }
                    #else
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        HStack(spacing: 8) {
                            if let currentMarker {
                                Button("定位当前") {
                                    proxy.scrollTo(currentMarker, anchor: .center)
                                }
                            }
                            Button(isAscending ? "倒序" : "正序") {
                                isAscending.toggle()
                            }
                        }
                    }
                    #endif
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

    private func catalogHeader(displayedCount: Int) -> some View {
        HStack {
            if !searchText.isEmpty {
                Text("匹配 \(displayedCount) 章（共 \(allRows.count) 章）")
            } else if !remoteTitles.isEmpty {
                Text("共 \(allRows.count) 章 · 已缓存 \(loadedIndices.count) 章 · \(isAscending ? "正序" : "倒序")")
            } else {
                Text("共 \(allRows.count) 章 · \(isAscending ? "正序" : "倒序")")
            }
            Spacer()
        }
        .font(.caption)
    }

    private func catalogRows(_ rows: [ReaderCatalog.Row]) -> some View {
        ForEach(rows) { row in
            Button {
                onJump(row.index)
            } label: {
                HStack {
                    Text(row.title)
                        .foregroundStyle(currentMarker == row.index ? Color.accentColor : .primary)
                        .fontWeight(currentMarker == row.index ? .semibold : .regular)
                    Spacer()
                    if currentMarker == row.index {
                        Text("当前")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
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
    var initialQuery: String = ""
    @State private var query: String
    @State private var results: [SearchHit] = []
    @State private var searchTask: Task<Void, Never>?

    init(engine: ReaderEngine, initialQuery: String = "", onPick: @escaping (Int) -> Void) {
        self.engine = engine
        self.initialQuery = initialQuery
        self.onPick = onPick
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        NavigationStack {
            List(results) { hit in
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
                } else if results.isEmpty {
                    Text("未找到匹配内容")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("搜索")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $query, prompt: "在本书中查找")
            .onAppear {
                performSearch(query, debounce: false)
            }
            .onChange(of: query) { _, newQuery in
                performSearch(newQuery, debounce: true)
            }
            .onDisappear {
                searchTask?.cancel()
            }
        }
    }

    private func performSearch(_ text: String, debounce: Bool) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        let sourceSnapshot = engine.source
        let chaptersSnapshot = engine.chapters
        searchTask = Task {
            if debounce {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard !Task.isCancelled else { return }
            let hits = await Task.detached(priority: .userInitiated) {
                ReaderEngine.search(source: sourceSnapshot, chapters: chaptersSnapshot, query: trimmed)
            }.value
            guard !Task.isCancelled else { return }
            results = hits
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
    var fraction: Double
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
                    if total > 0 {
                        ProgressView(value: min(max(fraction, 0), 1))
                    }
                    if !status.isEmpty {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    if running {
                        Button("停止", role: .destructive, action: onStop)
                    } else {
                        Button("一键缓存全本", action: onStart)
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
