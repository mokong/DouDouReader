import SwiftData
import SwiftUI
import AVFAudio
#if os(iOS) || os(visionOS)
import UIKit
#endif

struct ReaderScreen: View {
    var book: BookRecord
    @Environment(ReaderSettingsStore.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.deviceColorScheme) private var deviceColorScheme
    @State private var engine: ReaderEngine?
    @State private var loadError: String?
    @State private var showCatalog = false
    @State private var remoteChapterTitles: [String] = []
    @State private var catalogStatus: String?
    @State private var catalogError: String?
    @State private var catalogGeneration = 0
    @State private var catalogFailedIndex: Int?
    @State private var readerGeneration = 0
    @State private var chapterFetchInFlight = false
    /// 打开书时解析一次的目录执行器，翻章复用；换源（remoteSourceID 变化）时自动重建。
    @State private var cachedCatalog: IncrementalBookCatalog?
    @State private var cachedCatalogSourceID: String?
    /// 已静默预取到的远端章节 index，避免重复预取。
    @State private var prefetchedUpTo: Int = -1
    @State private var showSourceSwitch = false
    @State private var switchChapterTitle = ""
    @State private var showCache = false
    @State private var cacheRunning = false
    @State private var cacheStatus = ""
    @State private var cacheFraction: Double = 0
    @State private var cacheGeneration = 0
    @State private var cacheTask: Task<Void, Never>?
    @State private var chapterScrub = 0.0
    @State private var scrubbingChapter = false
    @State private var chapterMoveError: String?
    @State private var chapterMoveGeneration = 0
    @State private var showSearch = false
    @State private var searchInitialQuery = ""
    @State private var showBookmarks = false
    @State private var showSettings = false
    @State private var padTop = ScreenSafeArea.windowInsets.top
    @State private var padBottom = ScreenSafeArea.windowInsets.bottom

    var body: some View {
        Group {
            if let engine {
                reader(engine)
            } else if let loadError {
                missing(loadError)
            } else {
                ProgressView("正在打开")
            }
        }
        .task { openBook() }
        .onDisappear {
            engine?.stopActivities()
            cacheGeneration += 1
            cacheTask?.cancel()
        }
    }

    @ViewBuilder
    private func reader(_ engine: ReaderEngine) -> some View {
        let theme = settings.theme(interfaceDark: deviceColorScheme == .dark)
        GeometryReader { proxy in
            let safeTop = max(proxy.safeAreaInsets.top, padTop)
            let safeBottom = max(proxy.safeAreaInsets.bottom, padBottom)
            let placement = PageMetrics.placement(
                bounds: proxy.size,
                safeTop: safeTop,
                safeBottom: safeBottom,
                marginX: CGFloat(settings.horizontalMargin),
                marginTop: CGFloat(settings.topMargin),
                marginBottom: CGFloat(settings.bottomMargin),
                showsHeader: settings.showsHeader,
                showsFooter: settings.showsFooter
            )
            ZStack {
                theme.background.color
                pageBody(engine, theme: theme, safeTop: safeTop, safeBottom: safeBottom)
                pageWidgets(engine, theme: theme, placement: placement, safeTop: safeTop, safeBottom: safeBottom)
                    .allowsHitTesting(false)
                Color.black.opacity(1 - settings.brightness)
                    .allowsHitTesting(false)
            }
            .overlay {
                if engine.isChapterLoadFailed || engine.showEndActions {
                    chapterFailureActions(engine, theme: theme)
                        .offset(y: 44)
                }
            }
            .overlay(alignment: .top) {
                if engine.showsChrome {
                    topBar(engine, theme: theme)
                        .padding(.top, safeTop)
                }
            }
            .overlay(alignment: .bottom) {
                if engine.showsChrome {
                    bottomPanel(engine, theme: theme)
                        .padding(.bottom, safeBottom)
                        .background(theme.background.color)
                }
            }
            #if os(iOS) || os(visionOS)
            .background {
                SafeAreaProbe { top, bottom in
                    if abs(top - padTop) > 0.5 { padTop = top }
                    if abs(bottom - padBottom) > 0.5 { padBottom = bottom }
                }
            }
            #endif
        }
        .ignoresSafeArea()
        .background(theme.background.color.ignoresSafeArea())
        #if os(iOS) || os(visionOS)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear { sync(engine) }
        .onChange(of: settings.revision) { _, _ in sync(engine) }
        .onChange(of: deviceColorScheme) { _, _ in sync(engine) }
        .onChange(of: settings.keepScreenOn) { _, _ in updateIdleTimer() }
        // 预取触发放在 reader 主视图上：bottomPanel 仅在工具栏可见时存在，
        // 放在那里会导致默认隐藏工具栏时章末不预取。prefetchedUpTo 保证同一章不重复。
        .onChange(of: engine.position) { _, _ in
            prefetchNextChapterIfNeeded(engine: engine)
        }
        .sheet(isPresented: $showCatalog) {
            CatalogSheet(
                engine: engine,
                remoteTitles: remoteChapterTitles,
                loadedIndices: Set(engine.chapters.map(\.remoteIndex)),
                status: catalogStatus,
                errorMessage: catalogError,
                onJump: { index in
                    selectCatalogChapter(index, engine: engine)
                },
                onRetry: {
                    guard let index = catalogFailedIndex else { return }
                    selectCatalogChapter(index, engine: engine)
                },
                onSwitchSource: {
                    let title = catalogFailedIndex.flatMap { remoteChapterTitles.indices.contains($0) ? remoteChapterTitles[$0] : nil } ?? ""
                    showCatalog = false
                    presentSourceSwitch(preferring: title)
                }
            )
        }
        .onChange(of: showCatalog) { _, shown in
            if shown {
                catalogError = nil
                catalogStatus = nil
                catalogFailedIndex = nil
            } else {
                catalogGeneration += 1
            }
        }
        .sheet(isPresented: $showSearch) {
            SearchSheet(engine: engine, initialQuery: searchInitialQuery) { offset in
                engine.seek(to: offset)
                showSearch = false
                engine.showsChrome = false
            }
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarkSheet(book: book, engine: engine) { offset in
                engine.seek(to: offset)
                showBookmarks = false
                engine.showsChrome = false
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsPanel(settings: settings)
        }
        .sheet(isPresented: $showCache) {
            CacheSheet(
                downloaded: engine.chapters.count,
                total: max(engine.remoteChapterCount, engine.chapters.count),
                running: cacheRunning,
                fraction: cacheFraction,
                status: cacheStatus,
                canCache: engine.remoteChapterCount > 0,
                onStart: { startCache(engine) },
                onStop: { stopCache() }
            )
        }
        .sheet(isPresented: $showSourceSwitch) {
            SourceSwitchSheet(
                bookTitle: book.title,
                author: book.author,
                currentSourceID: book.remoteSourceID,
                currentBookID: book.remoteBookID,
                onSelect: { source, hit in
                    await switchSource(to: source, hit: hit)
                }
            )
        }
        #if os(iOS)
        .onAppear { updateIdleTimer() }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
    }

    @ViewBuilder
    private func pageBody(_ engine: ReaderEngine, theme: ReadingTheme, safeTop: CGFloat, safeBottom: CGFloat) -> some View {
        let _ = engine.layoutRevision
        #if os(iOS) || os(visionOS)
        ReaderContainer(engine: engine, settings: settings, theme: theme, safeTop: safeTop, safeBottom: safeBottom)
        #else
        MacPageView(
            engine: engine,
            settings: settings,
            theme: theme,
            safeTop: safeTop,
            safeBottom: safeBottom,
            onSearchSelectedText: { query in
                searchInitialQuery = query
                showSearch = true
            }
        )
        #endif
    }

    private func pageWidgets(
        _ engine: ReaderEngine,
        theme: ReadingTheme,
        placement: (textRect: CGRect, pageSize: CGSize),
        safeTop: CGFloat,
        safeBottom: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            // 极简模式：连页眉页脚这些常驻文字一起隐藏，只留正文。
            if settings.showsHeader && !settings.simpleMode {
                HStack(spacing: 8) {
                    if settings.showTime {
                        TimelineView(.periodic(from: .now, by: 30)) { timeline in
                            Text(ReaderClock.text(timeline.date))
                        }
                    }
                    Spacer(minLength: 8)
                    if settings.showChapterTitle {
                        Text(engine.currentTitle)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if settings.showBattery {
                        Text(batteryText())
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(theme.secondary.color)
                .padding(.horizontal, placement.textRect.minX)
                .padding(.top, safeTop + 8)
            }
            Spacer()
            if settings.showsFooter && !settings.simpleMode {
                HStack {
                    if settings.showPageProgress {
                        Text(engine.pageLabel)
                    }
                    Spacer()
                    if settings.showBookPercent {
                        Text(engine.percentLabel)
                    }
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(theme.secondary.color)
                .padding(.horizontal, placement.textRect.minX)
                .padding(.bottom, safeBottom + 6)
            }
        }
    }

    private func topBar(_ engine: ReaderEngine, theme: ReadingTheme) -> some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("返回")
            VStack(alignment: .leading, spacing: 1) {
                Text(book.title)
                    .font(.headline)
                    .lineLimit(1)
                if !engine.currentTitle.isEmpty {
                    Text(engine.currentTitle)
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            listenMenu(engine)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.background.color)
        .foregroundStyle(theme.text.color)
    }

    private func bottomPanel(_ engine: ReaderEngine, theme: ReadingTheme) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sun.min")
                    .font(.caption)
                    .foregroundStyle(theme.secondary.color)
                Slider(value: brightnessBinding, in: 0.45...1)
                    .tint(theme.text.color)
                Image(systemName: "sun.max")
                    .font(.caption)
                    .foregroundStyle(theme.secondary.color)
            }
            chapterScrubber(engine, theme: theme)
            HStack(spacing: 0) {
                barButton("目录", systemImage: "list.bullet") { showCatalog = true }
                barButton("夜间", systemImage: settings.themeID == "night" ? "moon.fill" : "moon") {
                    toggleNight()
                }
                barButton("设置", systemImage: "slider.horizontal.3") { showSettings = true }
                barButton("缓存", systemImage: "arrow.down.circle") { showCache = true }
                moreMenu(engine)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.secondary.color.opacity(0.25))
                .frame(height: 0.5)
        }
        .foregroundStyle(theme.text.color)
        .onAppear {
            if !scrubbingChapter {
                chapterScrub = Double(scrubIndex(engine))
            }
        }
        .onChange(of: engine.position) { _, _ in
            guard !scrubbingChapter else { return }
            chapterScrub = Double(scrubIndex(engine))
        }
    }

    private func chapterScrubber(_ engine: ReaderEngine, theme: ReadingTheme) -> some View {
        let count = scrubCount(engine)
        let index = scrubbingChapter ? Int(chapterScrub.rounded()) : scrubIndex(engine)
        return VStack(spacing: 4) {
            Text(chapterTitle(at: index, engine: engine))
                .font(.caption)
                .lineLimit(1)
            HStack(spacing: 8) {
                Button("上一章") { stepChapter(-1, engine: engine) }
                    .disabled(index <= 0)
                Slider(
                    value: Binding(
                        get: { scrubbingChapter ? chapterScrub : Double(scrubIndex(engine)) },
                        set: { chapterScrub = $0 }
                    ),
                    in: 0...Double(max(count - 1, 1)),
                    step: 1
                ) { editing in
                    scrubbingChapter = editing
                    if !editing {
                        moveToChapter(Int(chapterScrub.rounded()), engine: engine)
                    }
                }
                .tint(theme.text.color)
                .disabled(count < 2)
                Button("下一章") { stepChapter(1, engine: engine) }
                    .disabled(index >= count - 1)
            }
            .font(.subheadline)
            .buttonStyle(.plain)
            if let chapterMoveError {
                Text(chapterMoveError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private func moreMenu(_ engine: ReaderEngine) -> some View {
        Menu {
            Button("搜索") {
                searchInitialQuery = ""
                showSearch = true
            }
            Button("书签") { showBookmarks = true }
            Button(settings.simpleMode ? "退出极简模式" : "极简模式") {
                settings.simpleMode.toggle()
                engine.showsChrome = false
            }
            if canSwitchSource {
                Button("换源") {
                    presentSourceSwitch(preferring: engine.currentChapter?.title ?? book.currentChapterTitle)
                }
            }
            Button(engine.isAutoReading ? "停止自动翻页" : "自动翻页") {
                if engine.isAutoReading {
                    engine.stopAuto()
                } else {
                    engine.startAuto()
                }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "ellipsis")
                Text("更多")
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("更多")
    }

    private func listenMenu(_ engine: ReaderEngine) -> some View {
        Group {
            switch ReaderEngine.speechEntryAction(isActive: engine.speech.isActive) {
            case .startDirect:
                // 未朗读：点一次图标直接从当前界面开始，不再展开菜单。
                Button {
                    engine.toggleSpeech()
                } label: {
                    Image(systemName: listenSymbol(engine))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            case .openControls:
                // 朗读中：播放/暂停、停止、上一段/下一段、语速、音色，五项一步可达。
                Menu {
                    if engine.speech.isPaused {
                        Button("继续朗读") { engine.speech.togglePause() }
                    } else {
                        Button("暂停朗读") { engine.speech.togglePause() }
                    }
                    Button("停止朗读", role: .destructive) {
                        engine.toggleSpeech()
                    }
                    Divider()
                    Button("上一段") { engine.skipSpeech(delta: -1) }
                    Button("下一段") { engine.skipSpeech(delta: 1) }
                    Divider()
                    Menu("语速") {
                        ForEach(ReaderEngine.SpeechRateMenu.options, id: \.self) { rate in
                            Button {
                                engine.applySpeechRate(rate)
                            } label: {
                                let marked = abs(engine.settings.speechRate - rate) < 0.005
                                Label(ReaderEngine.SpeechRateMenu.label(rate), systemImage: marked ? "checkmark" : "")
                            }
                        }
                    }
                    Menu("音色") {
                        ForEach(SpeechController.chineseVoices(), id: \.identifier) { voice in
                            Button {
                                engine.applySpeechVoice(voice.identifier)
                            } label: {
                                Label(voice.name, systemImage: engine.settings.speechVoiceID == voice.identifier ? "checkmark" : "")
                            }
                        }
                    }
                } label: {
                    Image(systemName: listenSymbol(engine))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityLabel(listenTitle(engine))
    }

    private func listenTitle(_ engine: ReaderEngine) -> String {
        if engine.speech.isActive { return engine.speech.isPaused ? "已暂停" : "朗读中" }
        if engine.isAutoReading { return "翻页中" }
        return "听书"
    }

    private func listenSymbol(_ engine: ReaderEngine) -> String {
        if engine.speech.isActive { return engine.speech.isPaused ? "speaker.slash" : "headphones" }
        if engine.isAutoReading { return "timer" }
        return "headphones"
    }

    private var brightnessBinding: Binding<Double> {
        Binding(
            get: { settings.brightness },
            set: { settings.brightness = $0 }
        )
    }

    private func toggleNight() {
        if settings.themeID == "night" {
            settings.themeID = settings.dayThemeID == "night" ? "paper" : settings.dayThemeID
        } else {
            settings.dayThemeID = settings.themeID
            settings.themeID = "night"
        }
    }

    private func scrubCount(_ engine: ReaderEngine) -> Int {
        engine.remoteChapterCount > 0 ? engine.remoteChapterCount : engine.chapters.count
    }

    private func scrubIndex(_ engine: ReaderEngine) -> Int {
        if engine.remoteChapterCount > 0 {
            return engine.currentChapter?.remoteIndex ?? 0
        }
        if engine.isEnd { return max(engine.chapters.count - 1, 0) }
        return engine.position.chapterIndex
    }

    private func chapterTitle(at index: Int, engine: ReaderEngine) -> String {
        if remoteChapterTitles.indices.contains(index) {
            let title = remoteChapterTitles[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        if engine.remoteChapterCount == 0, engine.chapters.indices.contains(index) {
            return engine.chapters[index].title
        }
        if let slice = engine.chapters.first(where: { $0.remoteIndex == index }) {
            return slice.title
        }
        return "第 \(index + 1) 章"
    }

    private func stepChapter(_ delta: Int, engine: ReaderEngine) {
        let count = scrubCount(engine)
        guard count > 0 else { return }
        let next = min(max(scrubIndex(engine) + delta, 0), count - 1)
        chapterScrub = Double(next)
        moveToChapter(next, engine: engine)
    }

    /// 滑块和上一章/下一章停在选中的章节，菜单保持打开。
    private func moveToChapter(_ index: Int, engine: ReaderEngine) {
        let count = scrubCount(engine)
        guard count > 0 else { return }
        let target = min(max(index, 0), count - 1)
        chapterMoveGeneration += 1
        let ticket = chapterMoveGeneration
        chapterMoveError = nil
        if engine.remoteChapterCount == 0 {
            engine.jump(to: target)
            return
        }
        if engine.chapters.contains(where: { $0.remoteIndex == target }) {
            engine.jumpToRemote(target)
            return
        }
        Task {
            let ok = await loadRemoteChapter(target, into: engine, jumpAfter: true)
            guard ticket == chapterMoveGeneration else { return }
            chapterMoveError = ok ? nil : "这一章没有加载出来"
        }
    }

    private func startCache(_ engine: ReaderEngine) {
        guard engine.remoteChapterCount > 0, !cacheRunning else { return }
        cacheGeneration += 1
        let generation = cacheGeneration
        cacheRunning = true
        let total = engine.remoteChapterCount
        let cached = Set(engine.chapters.map(\.remoteIndex))
        let pending = BookCachePlan.pendingIndices(total: total, downloaded: cached)
        let walker = CacheIndexWalker(pending)
        let cachedCount = total - pending.count
        cacheFraction = total > 0 ? Double(cachedCount) / Double(total) : 0
        cacheStatus = "已缓存 \(cachedCount) / \(total) 章"
        cacheTask = Task { @MainActor in
            var done = cachedCount
            await withTaskGroup(of: Int?.self) { group in
                for _ in 0..<4 {
                    group.addTask { [walker] in
                        while !Task.isCancelled {
                            guard let index = await walker.next() else { return nil }
                            let ok = await self.loadRemoteChapter(
                                index,
                                into: engine,
                                jumpAfter: false,
                                generation: nil,
                                reportFailure: false,
                                allowConcurrent: true
                            )
                            if Task.isCancelled { return nil }
                            return ok ? index : -1
                        }
                        return nil
                    }
                }
                for await result in group {
                    guard !Task.isCancelled, generation == self.cacheGeneration else { break }
                    guard let result else { continue }
                    if result < 0 {
                        group.cancelAll()
                        self.cacheRunning = false
                        self.cacheStatus = "有章节下载失败，已停止"
                        return
                    }
                    done += 1
                    self.cacheFraction = total > 0 ? Double(done) / Double(total) : 0
                    self.cacheStatus = "已缓存 \(done) / \(total) 章"
                }
            }
            guard generation == self.cacheGeneration else { return }
            self.cacheRunning = false
            self.cacheStatus = self.cacheFraction >= 1 ? "全本缓存完成" : "缓存已停止"
        }
    }

    private func stopCache() {
        let wasRunning = cacheRunning
        cacheGeneration += 1
        cacheTask?.cancel()
        cacheTask = nil
        cacheRunning = false
        if wasRunning {
            cacheStatus = "缓存中断"
        }
    }

    private func barButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func missing(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
            Button("返回", action: { dismiss() })
        }
    }

    private func openBook() {
        guard engine == nil else { return }
        do {
            let text = try BookStorage.read(fileName: book.fileName)
            let created = ReaderEngine(
                text: text,
                fallbackTitle: book.title,
                startOffset: book.utf16Offset,
                settings: settings
            )
            created.onProgress = { chapter, offset, title in
                book.chapterIndex = chapter
                book.utf16Offset = offset
                book.currentChapterTitle = title
                book.lastReadAt = Date()
                try? modelContext.save()
            }
            let persisted = RemoteChapterList.decode(book.remoteChapterList)
            // 旧书本地目录可能是倒序存的，打开时统一翻正序，并回写纠正。
            let remoteChapters = RemoteChapterList.normalizedAscending(persisted)
            if remoteChapters.count == persisted.count,
               remoteChapters.map(\.url) != persisted.map(\.url) {
                book.remoteChapterList = RemoteChapterList.encode(remoteChapters)
            }
            remoteChapterTitles = remoteChapters.map(\.title)
            if !remoteChapters.isEmpty {
                let hadPersistedIndex = StoredChapters.persistedIndexExists(fileName: book.fileName)
                // 书源目录顺序归一后，按章节标题把已缓存章节重对到新目录下标，避免旧倒序数据下标错位。
                var items = storedChapters(from: text, remoteCount: remoteChapters.count)
                items = StoredChapters.remap(items, onto: remoteChapters)
                var start = book.utf16Offset
                if !hadPersistedIndex, !items.isEmpty {
                    // 首次从旧格式/整本 txt 装配：把进度锚到章节级别，并补齐字数与哈希。
                    let index = items.contains(where: { $0.index == book.chapterIndex }) ? book.chapterIndex : items[0].index
                    start = StoredChapters.offset(of: index, in: items)
                    book.utf16Offset = start
                    let assembled = StoredChapters.assemble(items)
                    book.totalUTF16 = (assembled as NSString).length
                    book.contentHash = BookLibrary.hash(assembled)
                    try? modelContext.save()
                }
                let rebuilt = ReaderEngine(
                    stored: items,
                    remoteCount: remoteChapters.count,
                    fallbackTitle: book.title,
                    startOffset: start,
                    settings: settings
                )
                rebuilt.onProgress = created.onProgress
                rebuilt.onNeedRemoteChapter = { [weak rebuilt] index in
                    guard let rebuilt else { return }
                    Task { @MainActor in
                        await self.loadRemoteChapter(index, into: rebuilt, jumpAfter: false)
                    }
                }
                rebuilt.onNeedRefreshCatalog = { [weak rebuilt] in
                    guard let rebuilt else { return }
                    Task { @MainActor in
                        await self.refreshCatalogAndContinue(into: rebuilt)
                    }
                }
                rebuilt.applySettings(settings, interfaceDark: deviceColorScheme == .dark)
                engine = rebuilt
                updateIdleTimer()
                return
            }
            created.hasUnloadedChapters = false
            created.onNeedNextChapter = { [weak created] in
                guard let created else { return }
                Task { @MainActor in
                    await self.loadNextChapter(into: created)
                }
            }
            created.applySettings(settings, interfaceDark: deviceColorScheme == .dark)
            engine = created
            updateIdleTimer()
        } catch {
            loadError = "这本书的文件打不开"
        }
    }

    private func storedChapters(from text: String, remoteCount: Int) -> [StoredChapter] {
        let saved = StoredChapters.load(fileName: book.fileName)
        if !saved.isEmpty { return saved }
        var migrated = StoredChapters.migrated(from: text, fallbackTitle: book.title)
        if remoteCount > 0 {
            migrated = migrated.filter { $0.index < remoteCount }
        }
        if !migrated.isEmpty {
            try? StoredChapters.save(fileName: book.fileName, chapters: migrated)
            book.loadedChapterCount = migrated.count
        }
        return migrated
    }

    private func selectCatalogChapter(_ index: Int, engine: ReaderEngine) {
        catalogGeneration += 1
        let generation = catalogGeneration
        let remote = RemoteChapterList.decode(book.remoteChapterList)
        if remote.isEmpty {
            engine.jump(to: index)
            showCatalog = false
            engine.showsChrome = false
            catalogStatus = nil
            return
        }
        if engine.chapters.contains(where: { $0.remoteIndex == index }) {
            engine.jumpToRemote(index)
            showCatalog = false
            engine.showsChrome = false
            catalogStatus = nil
            return
        }
        catalogError = nil
        catalogFailedIndex = index
        Task {
            let ok = await loadRemoteChapter(index, into: engine, jumpAfter: true, generation: generation)
            guard generation == catalogGeneration, !Task.isCancelled else { return }
            catalogStatus = nil
            if ok {
                catalogFailedIndex = nil
                showCatalog = false
                engine.showsChrome = false
            } else if catalogError == nil {
                catalogError = "这一章加载失败"
            }
        }
    }

    private func loadNextChapter(into engine: ReaderEngine) async {
        _ = await loadRemoteChapter(book.loadedChapterCount, into: engine, jumpAfter: false, generation: nil)
    }

    /// 读到目录末尾时，向书源重新拉一次目录：发现新章节就继续往下读，没有或失败则在末尾页提示重试/换源。
    private func refreshCatalogAndContinue(into engine: ReaderEngine) async {
        guard engine.remoteChapterCount > 0, !book.remoteBookID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            engine.catalogRefreshing = false
            return
        }
        let oldList = RemoteChapterList.decode(book.remoteChapterList)
        do {
            let records = (try? modelContext.fetch(FetchDescriptor<SourceRecord>())) ?? []
            guard let item = BookSourceLibrary.switchable(records: records).first(where: { $0.id == book.remoteSourceID }),
                  let catalog = BookSourceLibrary.catalog(for: item) as? IncrementalBookCatalog else {
                throw SourceError.unreachable
            }
            let toc = try await catalog.fetchTOC(bookID: book.remoteBookID)
            if Task.isCancelled { return }
            let outcome = BookUpdateComparison.compare(local: oldList, remote: toc.chapters)
            // 落库最新目录，刷新阅读器已知总章数。
            book.remoteChapterList = RemoteChapterList.encode(toc.chapters)
            remoteChapterTitles = toc.chapters.map(\.title)
            engine.remoteChapterCount = toc.chapters.count
            try? modelContext.save()
            engine.catalogRefreshing = false
            engine.catalogRefreshFailed = false
            // 有新章节：从旧目录的下一章开始继续下载并跳进去读。
            if outcome.newChapterCount > 0 {
                let nextRemote = oldList.count
                if toc.chapters.indices.contains(nextRemote) {
                    _ = await loadRemoteChapter(nextRemote, into: engine, jumpAfter: true, generation: nil)
                }
            }
        } catch {
            engine.catalogRefreshing = false
            engine.catalogRefreshFailed = true
        }
    }

    /// 距本章末尾约 2 页（或本章仅 1 页）时，后台静默预取下一章，失败不打扰阅读。
    private func prefetchNextChapterIfNeeded(engine: ReaderEngine) {
        guard !book.remoteBookID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let chapterIndex = engine.position.chapterIndex
        guard let layout = engine.layout(for: chapterIndex) else { return }
        let totalPages = layout.characterRanges.count
        let page = engine.position.pageIndex
        let nearEnd = totalPages <= 1 || page >= totalPages - 2
        guard nearEnd else { return }
        let nextIndex = chapterIndex + 1
        guard nextIndex > prefetchedUpTo else { return }
        guard !engine.chapters.contains(where: { $0.remoteIndex == nextIndex }) else { return }
        let remoteList = RemoteChapterList.decode(book.remoteChapterList)
        guard remoteList.indices.contains(nextIndex) else { return }
        prefetchedUpTo = nextIndex
        Task {
            _ = await loadRemoteChapter(nextIndex, into: engine, jumpAfter: false, generation: nil, reportFailure: false)
        }
    }

    /// 只下载目录里的这一章。目录跳转和章节交界共用，避免同时抓同一章。
    /// reportFailure 为 false 时只给缓存用：失败不把当前页标成加载失败，也不写目录错误。
    /// allowConcurrent 为 true 时（全本缓存多 worker）跳过全书串行闸门，网络层并发落盘仍走逐章 upsert。
    private func loadRemoteChapter(
        _ index: Int,
        into engine: ReaderEngine,
        jumpAfter: Bool,
        generation: Int? = nil,
        reportFailure: Bool = true,
        allowConcurrent: Bool = false
    ) async -> Bool {
        let ticket = readerGeneration
        if engine.chapters.contains(where: { $0.remoteIndex == index }) {
            if jumpAfter { engine.jumpToRemote(index) }
            return true
        }
        if !allowConcurrent {
            while chapterFetchInFlight {
                if Task.isCancelled { return false }
                if readerGeneration != ticket {
                    if reportFailure { engine.noteNextChapterFailed() }
                    return false
                }
                if let generation, generation != catalogGeneration { return false }
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
        }
        if engine.chapters.contains(where: { $0.remoteIndex == index }) {
            if jumpAfter { engine.jumpToRemote(index) }
            return true
        }
        if !allowConcurrent {
            chapterFetchInFlight = true
        }
        defer {
            if !allowConcurrent { chapterFetchInFlight = false }
        }
        if readerGeneration != ticket {
            if reportFailure { engine.noteNextChapterFailed() }
            return false
        }
        if Task.isCancelled { return false }
        if let generation, generation != catalogGeneration { return false }
        let chapters = RemoteChapterList.decode(book.remoteChapterList)
        guard chapters.indices.contains(index) else {
            guard reportFailure else { return false }
            if generation != nil { catalogError = "后面没有更多章节" }
            engine.noteNextChapterFailed()
            return false
        }
        if generation != nil {
            let rawTitle = chapters[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = rawTitle.isEmpty ? "第 \(index + 1) 章" : rawTitle
            catalogStatus = "正在加载\(name)"
        }
        do {
            let catalog: IncrementalBookCatalog
            if let cached = cachedCatalog, cachedCatalogSourceID == book.remoteSourceID {
                catalog = cached
            } else {
                let records = (try? modelContext.fetch(FetchDescriptor<SourceRecord>())) ?? []
                guard let item = BookSourceLibrary.switchable(records: records).first(where: { $0.id == book.remoteSourceID }),
                      let resolved = BookSourceLibrary.catalog(for: item) as? IncrementalBookCatalog else {
                    throw SourceError.unreachable
                }
                catalog = resolved
                cachedCatalog = resolved
                cachedCatalogSourceID = book.remoteSourceID
            }
            let body = try await catalog.fetchChapterText(url: chapters[index].url)
            if Task.isCancelled { return false }
            guard readerGeneration == ticket else {
                if reportFailure { engine.noteNextChapterFailed() }
                return false
            }
            let title = chapters[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedTitle = title.isEmpty ? "第\(index + 1)章" : title
            guard engine.insertRemoteChapter(remoteIndex: index, title: normalizedTitle, body: body) else {
                throw SourceError.emptyBook
            }
            // 只落这一章的正文文件并追加一行索引，不再整写整本正文与整份 sidecar。
            try StoredChapters.upsert(fileName: book.fileName, index: index, title: normalizedTitle, body: body)
            book.loadedChapterCount = engine.chapters.count
            book.totalUTF16 = engine.totalUTF16
            book.contentHash = BookLibrary.hash(engine.source)
            try? modelContext.save()
            if jumpAfter, generation == nil || generation == catalogGeneration {
                engine.jumpToRemote(index)
            }
            return true
        } catch {
            guard reportFailure else { return false }
            engine.noteNextChapterFailed()
            if generation != nil {
                let message = (error as? LocalizedError)?.errorDescription ?? ""
                catalogError = message.isEmpty ? "这一章加载失败" : message
            }
            return false
        }
    }

    private var canSwitchSource: Bool {
        !book.remoteBookID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func presentSourceSwitch(preferring title: String) {
        switchChapterTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        showSourceSwitch = true
    }

    private func chapterFailureActions(_ engine: ReaderEngine, theme: ReadingTheme) -> some View {
        HStack(spacing: 16) {
            Button("重试") {
                if engine.isChapterLoadFailed {
                    engine.retryCurrentChapter()
                } else {
                    engine.retryCatalogRefresh()
                }
            }
            if canSwitchSource {
                Button("自动换源") {
                    Task { await autoSwitchSource(engine: engine) }
                }
                Button("换源") {
                    presentSourceSwitch(preferring: failedChapterTitle(engine))
                }
            }
        }
        .buttonStyle(.bordered)
        .tint(theme.text.color)
    }

    /// 自动换源：跨其它可用书源搜索当前书名，取首个命中直接切换。
    private func autoSwitchSource(engine: ReaderEngine) async {
        switchChapterTitle = failedChapterTitle(engine)
        let records = (try? modelContext.fetch(FetchDescriptor<SourceRecord>())) ?? []
        let sources = BookSourceLibrary.switchable(records: records)
            .filter { $0.id != book.remoteSourceID }
        guard !sources.isEmpty else {
            chapterMoveError = "没有其它可用书源"
            return
        }
        var batches: [SourceSearchBatch] = []
        let stream = BookSearch.updates(query: book.title, sources: sources)
        for await batch in stream { batches.append(batch) }
        let hits = BookSearch.switchHits(
            title: book.title,
            author: book.author,
            excludingSourceID: book.remoteSourceID,
            excludingBookID: book.remoteBookID,
            batches: batches
        )
        guard let hit = hits.first,
              let source = sources.first(where: { $0.id == hit.sourceID }) else {
            chapterMoveError = "自动换源：其它书源没有这本书"
            return
        }
        if let error = await switchSource(to: source, hit: hit.book) {
            chapterMoveError = error
        }
    }

    private func failedChapterTitle(_ engine: ReaderEngine) -> String {
        if let remote = engine.position.boundaryRemote {
            let chapters = RemoteChapterList.decode(book.remoteChapterList)
            if chapters.indices.contains(remote) {
                let title = chapters[remote].title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { return title }
            }
        }
        let current = engine.currentChapter?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return current.isEmpty ? book.currentChapterTitle : current
    }

    private func switchSource(to source: SwitchableSource, hit: CatalogBook) async -> String? {
        guard let catalog = BookSourceLibrary.catalog(for: source) as? IncrementalBookCatalog else {
            return "这个书源不能按章阅读"
        }
        let wanted = switchChapterTitle
        do {
            let opening = try await catalog.fetchOpening(bookID: hit.id)
            readerGeneration += 1
            if !wanted.isEmpty {
                book.currentChapterTitle = wanted
            }
            let listedAuthor = hit.author.trimmingCharacters(in: .whitespacesAndNewlines)
            let author = book.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? listedAuthor : book.author
            _ = try BookLibrary.importOnline(
                text: opening.text,
                suggestedTitle: book.title,
                author: author,
                remoteBookID: hit.id,
                remoteSourceID: source.id,
                chapters: opening.chapters,
                openingBody: opening.openingBody,
                context: modelContext
            )
            reloadReader()
            guard let engine else {
                showSourceSwitch = false
                return nil
            }
            if await land(on: wanted, engine: engine) {
                showSourceSwitch = false
                showCatalog = false
                engine.showsChrome = false
                return nil
            }
            return "已经换到这个书源，但这一章没有加载出来"
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            return message.isEmpty ? "换源失败" : message
        }
    }

    private func reloadReader() {
        stopCache()
        engine?.stopActivities()
        engine = nil
        cachedCatalog = nil
        cachedCatalogSourceID = nil
        prefetchedUpTo = -1
        openBook()
    }

    /// 换源后尽量停在原来要读的那一章。目录里没有同名章节时，留在已经对上的进度。
    private func land(on title: String, engine: ReaderEngine) async -> Bool {
        let wanted = BookIdentity.normalize(title)
        guard !wanted.isEmpty else { return true }
        let chapters = RemoteChapterList.decode(book.remoteChapterList)
        guard let index = chapters.firstIndex(where: { BookIdentity.normalize($0.title) == wanted }) else {
            return true
        }
        if engine.chapters.contains(where: { $0.remoteIndex == index }) {
            engine.jumpToRemote(index)
            return true
        }
        return await loadRemoteChapter(index, into: engine, jumpAfter: true)
    }

    private func sync(_ engine: ReaderEngine) {
        engine.applySettings(settings, interfaceDark: deviceColorScheme == .dark)
        updateIdleTimer()
    }

    private func updateIdleTimer() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        #endif
    }

    private func batteryText() -> String {
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return "—" }
        return "\(Int((level * 100).rounded()))%"
        #else
        return "—"
        #endif
    }
}

/// 全本缓存多 worker 共享的下标队列：4 路并发从这里领取待下载章节。
private actor CacheIndexWalker {
    private var pending: [Int]
    init(_ items: [Int]) { pending = items }
    func next() -> Int? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }
}

enum ReaderClock {
    static func text(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

#if os(iOS) || os(visionOS)
private struct SafeAreaProbe: UIViewRepresentable {
    var onChange: (_ top: CGFloat, _ bottom: CGFloat) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.onChange = onChange
    }

    final class ProbeView: UIView {
        var onChange: ((_ top: CGFloat, _ bottom: CGFloat) -> Void)?
        private var lastTop = CGFloat(-1)
        private var lastBottom = CGFloat(-1)

        override func didMoveToWindow() {
            super.didMoveToWindow()
            publish()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            publish()
        }

        private func publish() {
            guard let window, bounds.height > 1 else { return }
            let topY = convert(CGPoint.zero, to: window).y
            let bottomY = convert(CGPoint(x: 0, y: bounds.height), to: window).y
            let extraTop = max(0, window.safeAreaInsets.top - topY)
            let extraBottom = max(0, bottomY - (window.bounds.height - window.safeAreaInsets.bottom))
            guard abs(extraTop - lastTop) > 0.5 || abs(extraBottom - lastBottom) > 0.5 else { return }
            lastTop = extraTop
            lastBottom = extraBottom
            let callback = onChange
            Task { @MainActor in
                callback?(extraTop, extraBottom)
            }
        }
    }
}
#endif

#if os(macOS)
import AppKit

/// 阅读页正文：可拖拽选中文本（NSTextView），单击（无拖拽）走点按区域，
/// 右键菜单带「搜索选中词」。
final class SelectablePageTextView: NSTextView {
    var onSimpleTap: ((CGPoint) -> Void)?
    var onSearchText: ((String) -> Void)?
    private var downPoint: CGPoint?

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        defer { downPoint = nil }
        guard let start = downPoint else { return }
        let end = convert(event.locationInWindow, from: nil)
        let moved = abs(start.x - end.x) + abs(start.y - end.y)
        // 没有拖拽且没有形成选区：视为单击，交给阅读页点按区域（翻页/唤出）。
        if moved < 4, selectedRange().length == 0 {
            onSimpleTap?(end)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard selectedRange().length > 0 else { return menu }
        let raw = (string as NSString).substring(with: selectedRange())
        let selected = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else { return menu }
        let title = selected.count > 12 ? String(selected.prefix(12)) + "…" : selected
        let item = NSMenuItem(title: "搜索「\(title)」", action: #selector(fireSearch(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = selected
        menu.insertItem(item, at: 0)
        if menu.item(at: 1) != nil {
            menu.insertItem(NSMenuItem.separator(), at: 1)
        }
        return menu
    }

    @objc private func fireSearch(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        onSearchText?(text)
    }
}

struct SelectablePageView: NSViewRepresentable {
    var attributed: NSAttributedString
    var onTapXFraction: (CGFloat) -> Void
    var onSearchText: (String) -> Void

    func makeNSView(context: Context) -> SelectablePageTextView {
        let textView = SelectablePageTextView()
        textView.isSelectable = true
        textView.isEditable = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.onSearchText = onSearchText
        return textView
    }

    func updateNSView(_ nsView: SelectablePageTextView, context: Context) {
        if !(nsView.attributedString().isEqual(to: attributed)) {
            nsView.textStorage?.setAttributedString(attributed)
        }
        nsView.onSimpleTap = { point in
            onTapXFraction(point.x / max(nsView.bounds.width, 1))
        }
        nsView.onSearchText = onSearchText
    }
}

struct MacPageView: View {
    var engine: ReaderEngine
    var settings: ReaderSettingsStore
    var theme: ReadingTheme
    var safeTop: CGFloat
    var safeBottom: CGFloat
    var onSearchSelectedText: (String) -> Void

    var body: some View {
        GeometryReader { proxy in
            let placement = PageMetrics.placement(
                bounds: proxy.size,
                safeTop: safeTop,
                safeBottom: safeBottom,
                marginX: CGFloat(settings.horizontalMargin),
                marginTop: CGFloat(settings.topMargin),
                marginBottom: CGFloat(settings.bottomMargin),
                showsHeader: settings.showsHeader,
                showsFooter: settings.showsFooter
            )
            ZStack {
                Color.clear
                page(engine)
                    .frame(width: placement.pageSize.width, height: placement.pageSize.height, alignment: .topLeading)
                    .position(x: placement.textRect.midX, y: placement.textRect.midY)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                applyTap(xFraction: location.x / max(proxy.size.width, 1))
            }
            .onAppear { engine.setPageSize(placement.pageSize) }
            .onChange(of: placement.pageSize) { _, newSize in
                engine.setPageSize(newSize)
            }
        }
        .focusable()
        .onKeyPress(.leftArrow) {
            engine.go(delta: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            engine.go(delta: 1)
            return .handled
        }
    }

    /// 正常模式：左 30% 上一页 / 右 30% 下一页 / 中间唤出工具栏（沿用 handleTap）。
    /// 极简模式：左右各 12% 边缘翻页，其余全部区域点按唤出/收起，避免与翻页冲突。
    private func applyTap(xFraction: CGFloat) {
        if engine.autoRunning {
            engine.stopAuto()
            engine.showsChrome = true
            return
        }
        guard settings.simpleMode else {
            engine.handleTap(xFraction: xFraction)
            return
        }
        switch ReaderEngine.tapAction(xFraction: xFraction, simpleMode: true) {
        case .prevPage: engine.go(delta: -1)
        case .nextPage: engine.go(delta: 1)
        case .toggleChrome: engine.showsChrome.toggle()
        }
    }

    @ViewBuilder
    private func page(_ engine: ReaderEngine) -> some View {
        if engine.isTerminal(engine.position) {
            VStack(spacing: 8) {
                Text(engine.terminalTitle(for: engine.position))
                    .font(.title2.bold())
                let detail = engine.terminalDetail(for: engine.position)
                if !detail.isEmpty {
                    Text(detail)
                        .foregroundStyle(theme.secondary.color)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(theme.text.color)
        } else if let layout = engine.layout(for: engine.position.chapterIndex),
                  layout.characterRanges.indices.contains(engine.position.pageIndex) {
            SelectablePageView(
                attributed: NSAttributedString(attributedPage(layout, page: engine.position.pageIndex)),
                onTapXFraction: { xf in
                    applyTap(xFraction: xf)
                },
                onSearchText: onSearchSelectedText
            )
        } else {
            Color.clear
        }
    }

    private func attributedPage(_ layout: ChapterLayout, page: Int) -> AttributedString {
        let pageRange = layout.characterRanges[page]
        let mutable = NSMutableAttributedString(attributedString: layout.storage.attributedSubstring(from: pageRange))
        if let highlight = engine.highlightRange {
            let local = NSIntersectionRange(highlight, pageRange)
            if local.length > 0 {
                mutable.addAttribute(
                    .backgroundColor,
                    value: NSColor.systemYellow.withAlphaComponent(0.45),
                    range: NSRange(location: local.location - pageRange.location, length: local.length)
                )
            }
        }
        return AttributedString(mutable)
    }
}
#endif
