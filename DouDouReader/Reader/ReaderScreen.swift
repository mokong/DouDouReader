import SwiftData
import SwiftUI
import AVFAudio
#if os(iOS) || os(visionOS)
import UIKit
#endif

private nonisolated struct BookOpenSnapshot: Sendable {
    var fileName: String
    var title: String
    var utf16Offset: Int
    var chapterIndex: Int
    var remoteChapterList: String
}

private nonisolated struct BookProgressPatch: Sendable {
    var utf16Offset: Int
    var totalUTF16: Int
    var contentHash: String
}

private nonisolated struct PreparedBook: Sendable {
    var text: String
    var chapters: [ChapterSlice]
    var remoteCount: Int
    var startOffset: Int
    var isRemote: Bool
    var remoteTitles: [String]
    var correctedChapterList: String?
    var progress: BookProgressPatch?
    var migratedChapterCount: Int?
}

/// 读文件、拆章、对齐缓存都在主线程之外做完，阅读页只负责挂上结果。
private nonisolated enum BookOpenPreparation {
    static func make(_ snapshot: BookOpenSnapshot) -> PreparedBook? {
        guard let text = try? BookStorage.read(fileName: snapshot.fileName) else { return nil }
        let persisted = RemoteChapterList.decode(snapshot.remoteChapterList)
        let remoteChapters = RemoteChapterList.normalizedAscending(persisted)
        guard !remoteChapters.isEmpty else {
            return PreparedBook(
                text: text,
                chapters: ChapterSplitter.split(text, fallbackTitle: snapshot.title),
                remoteCount: 0,
                startOffset: snapshot.utf16Offset,
                isRemote: false,
                remoteTitles: [],
                correctedChapterList: nil,
                progress: nil,
                migratedChapterCount: nil
            )
        }
        let corrected: String? = remoteChapters.map(\.url) == persisted.map(\.url)
            ? nil
            : RemoteChapterList.encode(remoteChapters)
        let hadPersistedIndex = StoredChapters.persistedIndexExists(fileName: snapshot.fileName)
        var items = StoredChapters.load(fileName: snapshot.fileName)
        var migratedCount: Int?
        if items.isEmpty {
            var migrated = StoredChapters.migrated(from: text, fallbackTitle: snapshot.title)
            migrated = migrated.filter { $0.index < remoteChapters.count }
            if !migrated.isEmpty {
                try? StoredChapters.save(fileName: snapshot.fileName, chapters: migrated)
                migratedCount = migrated.count
            }
            items = migrated
        }
        // 书源目录顺序归一后，按章节标题把已缓存章节重对到新目录下标。
        items = StoredChapters.remap(items, onto: remoteChapters)
        var start = snapshot.utf16Offset
        var progress: BookProgressPatch?
        if !hadPersistedIndex, !items.isEmpty {
            let index = items.contains(where: { $0.index == snapshot.chapterIndex }) ? snapshot.chapterIndex : items[0].index
            start = StoredChapters.offset(of: index, in: items)
            let assembled = StoredChapters.assemble(items)
            progress = BookProgressPatch(
                utf16Offset: start,
                totalUTF16: (assembled as NSString).length,
                contentHash: BookLibrary.hash(assembled)
            )
        }
        let built = StoredChapters.layout(items)
        let body: String
        let chapters: [ChapterSlice]
        if built.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body = snapshot.title
            chapters = ChapterSplitter.split(snapshot.title, fallbackTitle: snapshot.title)
        } else {
            body = built.text
            chapters = built.slices
        }
        return PreparedBook(
            text: body,
            chapters: chapters,
            remoteCount: remoteChapters.count,
            startOffset: start,
            isRemote: true,
            remoteTitles: remoteChapters.map(\.title),
            correctedChapterList: corrected,
            progress: progress,
            migratedChapterCount: migratedCount
        )
    }
}

struct ReaderScreen: View {
    var book: BookRecord
    @Query(sort: \SourceRecord.addedAt) private var sourceRecords: [SourceRecord]
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
    @State private var scrubOriginalIndex: Int?
    @State private var chapterMoveError: String?
    @State private var chapterMoveGeneration = 0
    @State private var showSearch = false
    @State private var searchInitialQuery = ""
    @State private var showBookmarks = false
    @State private var showSettings = false
    @State private var padTop = ScreenSafeArea.windowInsets.top
    @State private var padBottom = ScreenSafeArea.windowInsets.bottom
    /// 推入动画期间只铺底色。正文和翻页控件等转场走完再挂上，避免中途卡一下。
    @State private var showOpeningSpinner = false
    @State private var brightnessGestureActive = false
    @State private var startBrightness: Double = 1.0
    @State private var brightnessHUDTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var currentSourceName: String? {
        guard !book.remoteSourceID.isEmpty else { return nil }
        let sources = BookSourceLibrary.switchable(records: sourceRecords)
        return sources.first(where: { $0.id == book.remoteSourceID })?.name
    }

    var body: some View {
        let theme = settings.theme(interfaceDark: deviceColorScheme == .dark)
        ZStack {
            theme.background.color
            if let engine {
                reader(engine)
            } else if let loadError {
                missing(loadError)
            } else if showOpeningSpinner {
                ProgressView("正在打开")
                    .tint(theme.text.color)
                    .foregroundStyle(theme.text.color)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background.color.ignoresSafeArea())
        .ignoresSafeArea()
        #if os(iOS) || os(visionOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .task { await openBookForAppearance() }
        .onDisappear {
            engine?.stopActivities()
            cacheGeneration += 1
            cacheTask?.cancel()
            brightnessHUDTask?.cancel()
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
                } else if scrubbingChapter {
                    scrubHUD(engine, theme: theme)
                } else if brightnessGestureActive {
                    brightnessHUD
                }
            }
            .overlay(alignment: .leading) {
                #if os(iOS) || os(visionOS)
                brightnessEdgeGesture(screenHeight: proxy.size.height)
                #endif
            }
            .overlay(alignment: .top) {
                if engine.showsChrome {
                    topBar(engine, theme: theme)
                        .padding(.top, safeTop)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                if engine.showsChrome {
                    bottomPanel(engine, theme: theme)
                        .padding(.bottom, safeBottom)
                        .background(theme.background.color)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: engine.showsChrome)
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
        .onChange(of: engine.showsChrome) { _, shown in
            if !shown {
                scrubOriginalIndex = nil
            }
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
            #if os(iOS) || os(visionOS)
            .presentationDragIndicator(.visible)
            #endif
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
            #if os(iOS) || os(visionOS)
            .presentationDragIndicator(.visible)
            #endif
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarkSheet(book: book, engine: engine) { offset in
                engine.seek(to: offset)
                showBookmarks = false
                engine.showsChrome = false
            }
            #if os(iOS) || os(visionOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            #endif
        }
        .sheet(isPresented: $showSettings) {
            SettingsPanel(settings: settings)
                #if os(iOS) || os(visionOS)
                .presentationDetents([.fraction(0.55), .large])
                .presentationDragIndicator(.visible)
                #endif
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
            #if os(iOS) || os(visionOS)
            .presentationDetents([.fraction(0.48), .large])
            .presentationDragIndicator(.visible)
            #endif
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
            #if os(iOS) || os(visionOS)
            .presentationDetents([.fraction(0.68), .large])
            .presentationDragIndicator(.visible)
            #endif
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
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !engine.currentTitle.isEmpty {
                        Text(engine.currentTitle)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    if let sourceName = currentSourceName {
                        Button {
                            presentSourceSwitch(preferring: engine.currentTitle)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 8, weight: .bold))
                                Text(sourceName)
                                    .font(.system(size: 10, weight: .medium))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("当前书源：\(sourceName)，点击换源")
                    }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Button {
                    searchInitialQuery = ""
                    showSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("搜索")

                Button {
                    showBookmarks = true
                } label: {
                    Image(systemName: "bookmark")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("书签")

                listenMenu(engine)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.background.color)
        .foregroundStyle(theme.text.color)
    }

    private func bottomPanel(_ engine: ReaderEngine, theme: ReadingTheme) -> some View {
        VStack(spacing: 10) {
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
            HStack(spacing: 8) {
                Text(chapterTitle(at: index, engine: engine))
                    .font(.caption)
                    .lineLimit(1)
                if let original = scrubOriginalIndex, original != index {
                    Button {
                        moveToChapter(original, engine: engine)
                        scrubOriginalIndex = nil
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.uturn.backward")
                            Text("返回原章")
                        }
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
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
                    if editing {
                        if scrubOriginalIndex == nil {
                            scrubOriginalIndex = scrubIndex(engine)
                        }
                    } else {
                        let target = Int(chapterScrub.rounded())
                        if target == scrubOriginalIndex {
                            scrubOriginalIndex = nil
                        }
                        moveToChapter(target, engine: engine)
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

    /// 拖拽章节进度条时居中显示的悬浮气泡预览（清晰显示目标章节序号与名称）
    @ViewBuilder
    private func scrubHUD(_ engine: ReaderEngine, theme: ReadingTheme) -> some View {
        let count = scrubCount(engine)
        let index = Int(chapterScrub.rounded())
        let title = chapterTitle(at: index, engine: engine)
        VStack(spacing: 6) {
            Text(title.isEmpty ? "第 \(index + 1) 章" : title)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text("\(index + 1) / \(max(count, 1)) 章")
                .font(.caption)
                .foregroundStyle(theme.secondary.color)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(maxWidth: 280)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .foregroundStyle(theme.text.color)
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        .transition(.scale(scale: 0.92).combined(with: .opacity))
        .allowsHitTesting(false)
    }

    /// 屏幕左边缘垂直滑动微调亮度手势（香色闺阁/微信读书同款交互）
    private func brightnessEdgeGesture(screenHeight: CGFloat) -> some View {
        Color.clear
            .frame(width: 38)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        if !brightnessGestureActive {
                            brightnessGestureActive = true
                            startBrightness = settings.brightness
                        }
                        brightnessHUDTask?.cancel()
                        let delta = -Double(value.translation.height / max(screenHeight * 0.55, 1))
                        settings.brightness = min(max(0.15, startBrightness + delta), 1.0)
                    }
                    .onEnded { _ in
                        brightnessHUDTask?.cancel()
                        brightnessHUDTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            withAnimation(.easeOut(duration: 0.25)) {
                                brightnessGestureActive = false
                            }
                        }
                    }
            )
    }

    /// 亮度调节时的悬浮提示徽标
    @ViewBuilder
    private var brightnessHUD: some View {
        HStack(spacing: 10) {
            Image(systemName: settings.brightness < 0.4 ? "sun.min.fill" : "sun.max.fill")
                .font(.system(size: 20))
            Text("\(Int((settings.brightness * 100).rounded()))%")
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func barItemContent(title: String, systemImage: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .regular))
                .frame(width: 24, height: 20)
            Text(title)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .contentShape(Rectangle())
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
            barItemContent(title: "更多", systemImage: "ellipsis")
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
        scrubOriginalIndex = nil
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
            barItemContent(title: title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(title)
    }

    private func missing(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
            Button("返回", action: { dismiss() })
        }
    }

    /// 导航推入大约 0.35 秒。这段时间只留底色，读文件放在后台，转场结束后再挂阅读器。
    private var pushHold: Duration {
        #if os(iOS) || os(visionOS)
        reduceMotion ? .zero : .milliseconds(380)
        #else
        .zero
        #endif
    }

    private func openBookForAppearance() async {
        guard engine == nil else { return }
        let snapshot = BookOpenSnapshot(
            fileName: book.fileName,
            title: book.title,
            utf16Offset: book.utf16Offset,
            chapterIndex: book.chapterIndex,
            remoteChapterList: book.remoteChapterList
        )
        let loader = Task.detached(priority: .userInitiated) {
            BookOpenPreparation.make(snapshot)
        }
        let hold = pushHold
        if hold > .zero {
            do {
                try await Task.sleep(for: hold)
            } catch {
                loader.cancel()
                return
            }
        }
        guard !Task.isCancelled, engine == nil else {
            loader.cancel()
            return
        }
        let spinner = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, self.engine == nil, self.loadError == nil else { return }
            self.showOpeningSpinner = true
        }
        let prepared = await loader.value
        spinner.cancel()
        guard !Task.isCancelled, engine == nil else { return }
        showOpeningSpinner = false
        guard let prepared else {
            loadError = "这本书的文件打不开"
            return
        }
        install(prepared)
    }

    private func openBook() {
        guard engine == nil else { return }
        let snapshot = BookOpenSnapshot(
            fileName: book.fileName,
            title: book.title,
            utf16Offset: book.utf16Offset,
            chapterIndex: book.chapterIndex,
            remoteChapterList: book.remoteChapterList
        )
        guard let prepared = BookOpenPreparation.make(snapshot) else {
            loadError = "这本书的文件打不开"
            return
        }
        install(prepared)
    }

    private func install(_ prepared: PreparedBook) {
        if let corrected = prepared.correctedChapterList {
            book.remoteChapterList = corrected
        }
        if let count = prepared.migratedChapterCount {
            book.loadedChapterCount = count
        }
        if let progress = prepared.progress {
            book.utf16Offset = progress.utf16Offset
            book.totalUTF16 = progress.totalUTF16
            book.contentHash = progress.contentHash
        }
        if prepared.correctedChapterList != nil || prepared.migratedChapterCount != nil || prepared.progress != nil {
            try? modelContext.save()
        }
        remoteChapterTitles = prepared.remoteTitles
        let created = ReaderEngine(
            preparedText: prepared.text,
            chapters: prepared.chapters,
            remoteCount: prepared.remoteCount,
            startOffset: prepared.startOffset,
            settings: settings
        )
        created.onProgress = { chapter, offset, title in
            book.chapterIndex = chapter
            book.utf16Offset = offset
            book.currentChapterTitle = title
            book.lastReadAt = Date()
            try? modelContext.save()
        }
        if prepared.isRemote {
            created.onNeedRemoteChapter = { [weak created] index in
                guard let created else { return }
                Task { @MainActor in
                    await self.loadRemoteChapter(index, into: created, jumpAfter: false)
                }
            }
            created.onNeedRefreshCatalog = { [weak created] in
                guard let created else { return }
                Task { @MainActor in
                    await self.refreshCatalogAndContinue(into: created)
                }
            }
        } else {
            created.hasUnloadedChapters = false
            created.onNeedNextChapter = { [weak created] in
                guard let created else { return }
                Task { @MainActor in
                    await self.loadNextChapter(into: created)
                }
            }
        }
        created.applySettings(settings, interfaceDark: deviceColorScheme == .dark)
        engine = created
        updateIdleTimer()
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
            var waited = 0
            while chapterFetchInFlight {
                if Task.isCancelled { return false }
                if readerGeneration != ticket {
                    if reportFailure { engine.noteNextChapterFailed() }
                    return false
                }
                if let generation, generation != catalogGeneration { return false }
                try? await Task.sleep(nanoseconds: 50_000_000)
                waited += 50_000_000
                // 闸门超过 3 秒未释放（可能上一次异常退出没清），强制继续，避免重试死等。
                if waited > 3_000_000_000 {
                    chapterFetchInFlight = false
                    break
                }
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
                if engine.isChapterLoadFailed, let remote = engine.position.boundaryRemote {
                    retryFailedChapter(remote, into: engine)
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

    /// 章节交界加载失败后的重试：先清掉串行闸门和预取标记，再重置引擎状态并重新下载。
    private func retryFailedChapter(_ remote: Int, into engine: ReaderEngine) {
        chapterFetchInFlight = false
        prefetchedUpTo = -1
        engine.retryCurrentChapter()
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

    /// 换源后使用 ChapterMatching 模糊匹配（支持中英数字、括号过滤、核心相似度），保持原来阅读位置
    private func land(on title: String, engine: ReaderEngine) async -> Bool {
        let chapters = RemoteChapterList.decode(book.remoteChapterList)
        guard !chapters.isEmpty else { return true }
        guard let index = ChapterMatching.bestMatch(wantedTitle: title, in: chapters.map(\.title)) else {
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
