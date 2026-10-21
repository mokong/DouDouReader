import CoreGraphics
import Foundation
import Observation

struct ReaderPosition: Equatable {
    var chapterIndex: Int
    var pageIndex: Int
    /// 停在章节交界、等待这一章下载时使用。空表示正在读正文。
    var boundaryRemote: Int? = nil
}

struct SearchHit: Identifiable, Equatable {
    var offset: Int
    var chapterIndex: Int
    var chapterTitle: String
    var snippet: String

    var id: Int { offset }
}

@Observable
final class ReaderEngine {
    private(set) var source: String
    private(set) var chapters: [ChapterSlice]
    let speech = SpeechController()
    let settings: ReaderSettingsStore
    var hasUnloadedChapters = false
    /// 在线目录总章数。0 表示本地整本，章节是连续的。
    var remoteChapterCount = 0
    @ObservationIgnored var onNeedNextChapter: (() -> Void)?
    @ObservationIgnored var onNeedRemoteChapter: ((Int) -> Void)?
    /// 读到目录末尾时，向书源重新拉一次目录，看是否有新更新的章节。
    @ObservationIgnored var onNeedRefreshCatalog: (() -> Void)?
    @ObservationIgnored private var askedForNext = false
    @ObservationIgnored private var nextChapterFailed = false
    @ObservationIgnored private var failedAt: ReaderPosition?
    @ObservationIgnored private var askedForCatalogRefresh = false
    /// 正在向书源拉最新目录（读到末尾时）。
    var catalogRefreshing = false
    /// 拉目录失败（网络/书源问题），末尾页展示重试/换源。
    var catalogRefreshFailed = false

    private(set) var position = ReaderPosition(chapterIndex: 0, pageIndex: 0)
    @ObservationIgnored private(set) var anchorOffset: Int
    @ObservationIgnored private(set) var pageSize: CGSize = .zero
    private(set) var layoutRevision = 0
    private(set) var highlightRange: NSRange?
    private(set) var autoRunning = false
    @ObservationIgnored var animateNextTurn = false
    var showsChrome = false

    @ObservationIgnored var onProgress: ((Int, Int, String) -> Void)?
    @ObservationIgnored var onHighlight: ((NSRange?) -> Void)?

    @ObservationIgnored private var appliedLayout: LayoutSnapshot
    @ObservationIgnored private var cache: [CacheKey: ChapterLayout] = [:]
    @ObservationIgnored private var autoTask: Task<Void, Never>?
    @ObservationIgnored private var speakingPageRange: NSRange?
    @ObservationIgnored private var didPrintReady = false

    private struct CacheKey: Hashable {
        var chapter: Int
        var width: Int
        var height: Int
        var snapshot: LayoutSnapshot
    }

    init(text: String, fallbackTitle: String, startOffset: Int, settings: ReaderSettingsStore) {
        let normalized = TextDecoding.normalize(text)
        source = normalized
        chapters = ChapterSplitter.split(normalized, fallbackTitle: fallbackTitle)
        let total = (normalized as NSString).length
        anchorOffset = min(max(0, startOffset), total)
        self.settings = settings
        appliedLayout = settings.layoutSnapshot(interfaceDark: false)
        bindSpeech()
    }

    /// 在线书按已下载的章节建正文。remoteIndex 可以不连续。
    init(
        stored items: [StoredChapter],
        remoteCount: Int,
        fallbackTitle: String,
        startOffset: Int,
        settings: ReaderSettingsStore
    ) {
        let built = StoredChapters.layout(items)
        let text: String
        if built.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = fallbackTitle
            chapters = ChapterSplitter.split(fallbackTitle, fallbackTitle: fallbackTitle)
        } else {
            text = built.text
            chapters = built.slices
        }
        source = text
        remoteChapterCount = remoteCount
        let total = (text as NSString).length
        anchorOffset = min(max(0, startOffset), total)
        self.settings = settings
        appliedLayout = settings.layoutSnapshot(interfaceDark: false)
        bindSpeech()
    }

    /// 正文和章节已经在后台组好。打开书时用这个，避免推入动画期间在主线程拼接全文。
    init(
        preparedText text: String,
        chapters: [ChapterSlice],
        remoteCount: Int,
        startOffset: Int,
        settings: ReaderSettingsStore
    ) {
        source = text
        self.chapters = chapters.isEmpty
            ? ChapterSplitter.split(text, fallbackTitle: text)
            : chapters
        remoteChapterCount = remoteCount
        let total = (text as NSString).length
        anchorOffset = min(max(0, startOffset), total)
        self.settings = settings
        appliedLayout = settings.layoutSnapshot(interfaceDark: false)
        bindSpeech()
    }

    private func bindSpeech() {
        speech.onAdvance = { [weak self] step in
            self?.handleSpeechAdvance(step)
        }
        speech.onRange = { [weak self] range in
            self?.handleSpeechRange(range)
        }
    }

    var totalUTF16: Int { (source as NSString).length }

    var isEnd: Bool { position.chapterIndex >= chapters.count && position.boundaryRemote == nil }

    func isTerminal(_ position: ReaderPosition) -> Bool {
        position.boundaryRemote != nil || position.chapterIndex >= chapters.count
    }

    func terminalTitle(for position: ReaderPosition) -> String {
        if position.boundaryRemote != nil {
            if nextChapterFailed { return boundaryIsPrevious(position) ? "上一章加载失败" : "下一章加载失败" }
            return boundaryIsPrevious(position) ? "正在加载上一章" : "正在加载下一章"
        }
        return endTitle
    }

    func terminalDetail(for position: ReaderPosition) -> String {
        if position.boundaryRemote != nil {
            return nextChapterFailed ? "" : "请稍等"
        }
        return endDetail
    }

    var isChapterLoadFailed: Bool {
        nextChapterFailed && position.boundaryRemote != nil
    }

    /// 章节交界加载失败后，再要这一章。
    func retryCurrentChapter() {
        guard isChapterLoadFailed else { return }
        retryBoundary()
    }

    func jumpToRemote(_ remoteIndex: Int) {
        guard let index = chapters.firstIndex(where: { $0.remoteIndex == remoteIndex }) else { return }
        jump(to: index)
    }

    var isAutoReading: Bool { autoRunning }

    var currentChapter: ChapterSlice? {
        guard chapters.indices.contains(position.chapterIndex) else { return nil }
        return chapters[position.chapterIndex]
    }

    var currentTitle: String {
        if isEnd { return endTitle }
        return currentChapter?.title ?? ""
    }

    var endTitle: String {
        if nextChapterFailed { return "下一章加载失败" }
        if catalogRefreshing { return "正在检查更新…" }
        if catalogRefreshFailed { return "检查更新失败" }
        if hasUnloadedChapters { return "正在加载下一章" }
        return remoteChapterCount > 0 ? "已经读到最新章节" : "全书完"
    }

    var endDetail: String {
        if nextChapterFailed { return "返回后再次翻页" }
        if catalogRefreshing { return "正在从书源拉取最新目录" }
        if catalogRefreshFailed { return "网络或书源异常，点下方按钮重试或换源" }
        if hasUnloadedChapters { return "请稍等" }
        return remoteChapterCount > 0 ? "点「重试」再检查一次更新，或换源" : "返回目录或书架"
    }

    /// 是否在末尾页展示「重试 / 换源」操作：下载失败、目录刷新失败、或已读到最新。
    var showEndActions: Bool {
        if nextChapterFailed { return true }
        guard position.boundaryRemote == nil, position.chapterIndex >= chapters.count else { return false }
        // 正在拉目录时不抢操作，拉完（成功/失败/无更新）再给按钮。
        return !catalogRefreshing
    }

    /// 末尾页「重试」：重新向书源拉一次目录。
    func retryCatalogRefresh() {
        guard showEndActions, !nextChapterFailed, !catalogRefreshing else { return }
        catalogRefreshFailed = false
        catalogRefreshing = true
        askedForCatalogRefresh = true
        layoutRevision += 1
        onNeedRefreshCatalog?()
    }

    var pageLabel: String {
        if position.boundaryRemote != nil { return "—" }
        if isEnd { return "完" }
        let count = layout(for: position.chapterIndex)?.pageCount ?? 1
        return "\(position.pageIndex + 1) / \(count)"
    }

    var percentLabel: String {
        let total = totalUTF16
        guard total > 0 else { return "0%" }
        let percent = min(100, max(0, Int((Double(currentUTF16()) / Double(total) * 100).rounded())))
        return "\(percent)%"
    }

    func layout(for chapterIndex: Int) -> ChapterLayout? {
        guard chapters.indices.contains(chapterIndex) else { return nil }
        guard pageSize.width > 40, pageSize.height > 40 else { return nil }
        let key = CacheKey(
            chapter: chapterIndex,
            width: Int(pageSize.width.rounded()),
            height: Int(pageSize.height.rounded()),
            snapshot: appliedLayout
        )
        if let cached = cache[key] { return cached }
        let chapter = chapters[chapterIndex]
        let body = ChapterSplitter.substring(source, start: chapter.bodyStart, end: chapter.bodyEnd)
        let script = ChineseScript(rawValue: appliedLayout.script) ?? .original
        let theme = ReadingThemes.resolve(id: appliedLayout.themeID, interfaceDark: appliedLayout.interfaceDark)
        let laid = ChapterLayouter.layout(
            title: ChineseConverter.convert(chapter.title, to: script),
            body: ChineseConverter.convert(body, to: script),
            sourceBodyUTF16: (body as NSString).length,
            snapshot: appliedLayout,
            theme: theme,
            pageSize: pageSize
        )
        cache[key] = laid
        trimCache(around: chapterIndex)
        schedulePrelayoutNextChapter(current: chapterIndex)
        return laid
    }

    /// 在主线程空闲时微任务预排下一章，使得翻到章末跨章滑动时直接命中缓存，零掉帧
    private func schedulePrelayoutNextChapter(current chapterIndex: Int) {
        let next = chapterIndex + 1
        guard chapters.indices.contains(next) else { return }
        let nextKey = CacheKey(
            chapter: next,
            width: Int(pageSize.width.rounded()),
            height: Int(pageSize.height.rounded()),
            snapshot: appliedLayout
        )
        guard cache[nextKey] == nil else { return }
        Task { @MainActor [weak self] in
            guard let self, self.chapters.indices.contains(next) else { return }
            _ = self.layout(for: next)
        }
    }

    func setPageSize(_ size: CGSize) {
        guard size.width > 40, size.height > 40 else { return }
        let rounded = CGSize(width: size.width.rounded(), height: size.height.rounded())
        if abs(rounded.width - pageSize.width) < 0.5, abs(rounded.height - pageSize.height) < 0.5 {
            return
        }
        pageSize = rounded
        relayoutKeepingOffset()
    }

    func applySettings(_ settings: ReaderSettingsStore, interfaceDark: Bool) {
        let snapshot = settings.layoutSnapshot(interfaceDark: interfaceDark)
        guard snapshot != appliedLayout else { return }
        appliedLayout = snapshot
        relayoutKeepingOffset()
    }

    func go(delta: Int) {
        guard pageSize.width > 40, pageSize.height > 40, delta != 0 else { return }
        let target: ReaderPosition
        if delta > 0 {
            if let next = neighbor(after: position) {
                target = next
            } else if position.boundaryRemote != nil {
                if nextChapterFailed { retryBoundary() }
                return
            } else if position.chapterIndex < chapters.count {
                target = ReaderPosition(chapterIndex: chapters.count, pageIndex: 0)
            } else {
                return
            }
        } else {
            guard let previous = neighbor(before: position) else {
                if position.boundaryRemote != nil, nextChapterFailed { retryBoundary() }
                return
            }
            target = previous
        }
        move(to: target, animated: true)
        if isTerminal(target) {
            haltSpeech()
            stopAuto()
            return
        }
        if speech.isActive && settings.speechMode == .page {
            speakCurrentPage()
        }
    }

    /// A gesture already displayed this page. Record it without starting another animation.
    func adopt(position newPosition: ReaderPosition) {
        animateNextTurn = false
        guard newPosition != position else { return }
        position = newPosition
        commit()
        if isTerminal(position) {
            haltSpeech()
            stopAuto()
            return
        }
        if speech.isActive && settings.speechMode == .page {
            speakCurrentPage()
        }
    }

    func seek(to offset: Int) {
        stopAuto()
        let clamped = min(max(0, offset), totalUTF16)
        animateNextTurn = false
        position = positionFor(offset: clamped)
        commit()
        guard speech.isActive else { return }
        if isEnd {
            haltSpeech()
            return
        }
        if settings.speechMode == .page {
            speakCurrentPage()
        } else {
            speakCurrentChapter()
        }
    }

    func jump(to chapterIndex: Int) {
        guard chapters.indices.contains(chapterIndex) else { return }
        seek(to: chapters[chapterIndex].lineStart)
    }

    func handleTap(xFraction: CGFloat) {
        if autoRunning {
            stopAuto()
            showsChrome = true
            return
        }
        if xFraction < 0.30 {
            go(delta: -1)
        } else if xFraction > 0.70 {
            go(delta: 1)
        } else {
            showsChrome.toggle()
        }
    }

    /// 点按区域判定（纯函数）：正常模式左右各 30% 翻页、中间唤出工具栏；
    /// 极简模式收窄为左右各 12% 边缘翻页，其余全部区域唤出/收起，避免与翻页冲突。
    enum TapAction {
        case prevPage, nextPage, toggleChrome
    }

    nonisolated static func tapAction(xFraction: CGFloat, simpleMode: Bool) -> TapAction {
        if simpleMode {
            if xFraction < 0.12 { return .prevPage }
            if xFraction > 0.88 { return .nextPage }
            return .toggleChrome
        }
        if xFraction < 0.30 { return .prevPage }
        if xFraction > 0.70 { return .nextPage }
        return .toggleChrome
    }

    /// 工具栏听书入口的点击行为（纯函数）：未朗读=点一次直接开始；朗读中=展开控制菜单。
    enum SpeechEntryAction { case startDirect, openControls }

    nonisolated static func speechEntryAction(isActive: Bool) -> SpeechEntryAction {
        isActive ? .openControls : .startDirect
    }

    /// 朗读控制菜单里的语速档位（与设置页 0.32–0.80 范围一致）。
    nonisolated enum SpeechRateMenu {
        static let options: [Double] = [0.32, 0.4, 0.48, 0.6, 0.8]
        static func label(_ rate: Double) -> String { String(format: "%.2fx", rate) }
    }

    func toggleSpeech() {
        if speech.isActive {
            haltSpeech()
            return
        }
        stopAuto()
        guard !isTerminal(position) else { return }
        if settings.speechMode == .page {
            speakCurrentPage()
        } else {
            speakCurrentChapter()
        }
    }

    /// 朗读中「上一段 / 下一段」跳跃：按当前朗读粒度（页=上一页/下一页，章=上一章/下一章）
    /// 移动位置并用新设置重新朗读。页模式复用 go(delta:)（已含朗读联动）；章模式向前复用
    /// onAdvance 的推进路径（含在线章边界），向后只回本地已下载章节。
    func skipSpeech(delta: Int) {
        guard speech.isActive else { return }
        if settings.speechMode == .page {
            go(delta: delta)
            return
        }
        if delta > 0 {
            handleSpeechAdvance(.chapter)
            return
        }
        let target = max(0, position.chapterIndex - 1)
        guard target != position.chapterIndex else { return }
        position = ReaderPosition(chapterIndex: target, pageIndex: 0)
        commit()
        speakCurrentChapter()
    }

    /// 朗读中热调语速：写入设置，正在朗读则以新语速重读当前段；未朗读只保存。
    func applySpeechRate(_ rate: Double) {
        settings.speechRate = rate
        guard speech.isActive else { return }
        restartCurrentSpeechSegment()
    }

    /// 朗读中热换音色：写入设置，正在朗读则以新音色重读当前段；未朗读只保存。
    func applySpeechVoice(_ voiceID: String) {
        settings.speechVoiceID = voiceID
        guard speech.isActive else { return }
        restartCurrentSpeechSegment()
    }

    private func restartCurrentSpeechSegment() {
        if settings.speechMode == .page {
            speakCurrentPage()
        } else {
            speakCurrentChapter()
        }
    }

    func startAuto() {
        haltSpeech()
        autoTask?.cancel()
        showsChrome = false
        autoRunning = true
        autoTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.autoRunning {
                let nanoseconds = UInt64(max(1, self.settings.autoInterval) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled, self.autoRunning else { return }
                if self.isTerminal(self.position) {
                    self.stopAuto()
                    return
                }
                self.go(delta: 1)
                if self.isTerminal(self.position) {
                    self.stopAuto()
                    return
                }
            }
        }
    }

    func stopAuto() {
        autoTask?.cancel()
        autoTask = nil
        if autoRunning {
            autoRunning = false
        }
    }

    func stopActivities() {
        stopAuto()
        haltSpeech()
    }

    func appendLoadedChapter(title: String, body: String) -> Bool {
        let cleaned = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        let oldCount = chapters.count
        let viewingEnd = position.chapterIndex >= oldCount
        let separator = source.isEmpty || source.hasSuffix("\n") ? "" : "\n"
        let titleStart = (source as NSString).length + (separator as NSString).length
        source += "\(separator)\(title)\n\(cleaned)\n"
        let bodyStart = titleStart + (title as NSString).length + 1
        let bodyEnd = (source as NSString).length
        if chapters.indices.contains(oldCount - 1) {
            chapters[oldCount - 1].bodyEnd = titleStart
        }
        chapters.append(
            ChapterSlice(
                index: oldCount,
                title: title,
                lineStart: titleStart,
                bodyStart: min(bodyStart, bodyEnd),
                bodyEnd: bodyEnd
            )
        )
        // 保持前台正在阅读的既有章节排版缓存，仅当停在末尾加载页时才需要递增 layoutRevision 翻入新章
        askedForNext = false
        nextChapterFailed = false
        failedAt = nil
        catalogRefreshing = false
        catalogRefreshFailed = false
        askedForCatalogRefresh = false
        if viewingEnd {
            layoutRevision += 1
            animateNextTurn = true
            position = ReaderPosition(chapterIndex: oldCount, pageIndex: 0)
        }
        commit()
        return true
    }

    /// 只插入这一章，不补它前面或后面的空档。人正等在这一章的交界上时，才翻进去。
    func insertRemoteChapter(remoteIndex target: Int, title: String, body: String) -> Bool {
        let cleaned = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        if chapters.contains(where: { $0.remoteIndex == target }) { return true }
        let piece = StoredChapters.block(title: title, body: cleaned)
        let pieceLength = (piece as NSString).length
        guard source.utf8.count + piece.utf8.count <= BookStorage.byteLimit else { return false }
        let insertAt = chapters.firstIndex { $0.remoteIndex > target } ?? chapters.count
        let oldCount = chapters.count
        let oldPosition = position
        let waiting = oldPosition.boundaryRemote == target
        let originRemote = remoteIndex(at: oldPosition.chapterIndex)
        let insertOffset: Int
        if chapters.isEmpty || insertAt == 0 {
            source = piece + source
            insertOffset = 0
        } else if insertAt == chapters.count {
            let gap = source.hasSuffix("\n") || source.isEmpty ? "" : "\n"
            insertOffset = (source as NSString).length + (gap as NSString).length
            source += gap + piece
        } else {
            insertOffset = chapters[insertAt].lineStart
            let ns = source as NSString
            source = ns.substring(to: insertOffset) + piece + ns.substring(from: insertOffset)
        }
        if insertAt > 0, chapters.indices.contains(insertAt - 1) {
            chapters[insertAt - 1].bodyEnd = insertOffset
        }
        if insertAt < chapters.count {
            for index in insertAt..<chapters.count {
                chapters[index].lineStart += pieceLength
                chapters[index].bodyStart += pieceLength
                chapters[index].bodyEnd += pieceLength
            }
        }
        let titleLength = (title as NSString).length
        let end = insertOffset + pieceLength
        chapters.insert(
            ChapterSlice(
                index: insertAt,
                title: title,
                lineStart: insertOffset,
                bodyStart: min(insertOffset + titleLength + 1, end),
                bodyEnd: end,
                remoteIndex: target
            ),
            at: insertAt
        )
        for index in chapters.indices {
            chapters[index].index = index
        }
        // 智能保留既有章节排版缓存，避免章末后台静默预取清空当前页排版导致掉帧闪烁
        if insertAt < oldCount {
            var updatedCache: [CacheKey: ChapterLayout] = [:]
            for (key, layout) in cache {
                if key.chapter < insertAt {
                    updatedCache[key] = layout
                } else {
                    var newKey = key
                    newKey.chapter += 1
                    updatedCache[newKey] = layout
                }
            }
            cache = updatedCache
        }
        askedForNext = false
        nextChapterFailed = false
        failedAt = nil
        catalogRefreshing = false
        catalogRefreshFailed = false
        askedForCatalogRefresh = false
        if waiting {
            layoutRevision += 1
            animateNextTurn = true
            let forward = originRemote.map { target > $0 } ?? true
            if forward {
                position = ReaderPosition(chapterIndex: insertAt, pageIndex: 0)
            } else {
                let pages = layout(for: insertAt)?.pageCount ?? 1
                position = ReaderPosition(chapterIndex: insertAt, pageIndex: max(pages - 1, 0))
            }
        } else if oldPosition.chapterIndex >= oldCount {
            layoutRevision += 1
            position = ReaderPosition(chapterIndex: chapters.count, pageIndex: 0)
        } else if insertAt <= oldPosition.chapterIndex {
            position = ReaderPosition(chapterIndex: oldPosition.chapterIndex + 1, pageIndex: oldPosition.pageIndex)
        }
        commit()
        return true
    }

    func noteNextChapterFailed() {
        askedForNext = false
        nextChapterFailed = true
        failedAt = position
        if isEnd || position.boundaryRemote != nil {
            layoutRevision += 1
        }
    }

    func pageExcerpt() -> String {
        if isEnd { return endTitle }
        guard let laid = layout(for: position.chapterIndex) else { return "" }
        let raw = laid.plainText(page: position.pageIndex)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = raw as NSString
        guard ns.length > 42 else { return raw }
        return ns.substring(to: 42)
    }

    func search(_ query: String, limit: Int = 80) -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let ns = source as NSString
        var hits: [SearchHit] = []
        var location = 0
        while hits.count < limit && location < ns.length {
            let found = ns.range(
                of: needle,
                options: .caseInsensitive,
                range: NSRange(location: location, length: ns.length - location)
            )
            if found.location == NSNotFound { break }
            let chapter = chapterIndex(at: found.location)
            let start = max(0, found.location - 14)
            let end = min(ns.length, NSMaxRange(found) + 22)
            let snippet = ns.substring(with: NSRange(location: start, length: end - start))
                .replacingOccurrences(of: "\n", with: " ")
            let title = chapters.indices.contains(chapter) ? chapters[chapter].title : ""
            hits.append(
                SearchHit(
                    offset: found.location,
                    chapterIndex: chapter,
                    chapterTitle: title,
                    snippet: snippet
                )
            )
            let next = NSMaxRange(found)
            location = next > location ? next : location + 1
        }
        return hits
    }

    func chapterIndex(at offset: Int) -> Int {
        var result = 0
        for chapter in chapters {
            if chapter.lineStart <= offset {
                result = chapter.index
            } else {
                break
            }
        }
        return result
    }

    func positionFor(offset: Int) -> ReaderPosition {
        guard !chapters.isEmpty else {
            return ReaderPosition(chapterIndex: 0, pageIndex: 0)
        }
        guard pageSize.width > 40, pageSize.height > 40 else {
            return ReaderPosition(chapterIndex: 0, pageIndex: 0)
        }
        if offset >= totalUTF16 {
            let last = chapters.count - 1
            let pages = layout(for: last)?.pageCount ?? 1
            return ReaderPosition(chapterIndex: last, pageIndex: max(pages - 1, 0))
        }
        let index = chapterIndex(at: offset)
        guard chapters.indices.contains(index) else {
            return ReaderPosition(chapterIndex: 0, pageIndex: 0)
        }
        let chapter = chapters[index]
        guard let laid = layout(for: index) else {
            return ReaderPosition(chapterIndex: index, pageIndex: 0)
        }
        let composed = composedLocation(for: offset, chapter: chapter, layout: laid)
        var page = 0
        for (candidate, range) in laid.characterRanges.enumerated() {
            if range.location <= composed {
                page = candidate
            } else {
                break
            }
        }
        return ReaderPosition(chapterIndex: index, pageIndex: page)
    }

    func currentUTF16() -> Int {
        if let remote = position.boundaryRemote,
           chapters.indices.contains(position.chapterIndex) {
            let chapter = chapters[position.chapterIndex]
            return remote > chapter.remoteIndex ? chapter.bodyEnd : chapter.lineStart
        }
        if isEnd { return totalUTF16 }
        guard let chapter = currentChapter else { return anchorOffset }
        if position.pageIndex <= 0 { return chapter.lineStart }
        guard let laid = layout(for: chapter.index),
              laid.characterRanges.indices.contains(position.pageIndex) else {
            return chapter.lineStart
        }
        return sourceOffset(
            composed: laid.characterRanges[position.pageIndex].location,
            chapter: chapter,
            layout: laid
        )
    }

    func composedLocation(for sourceOffset: Int, chapter: ChapterSlice, layout: ChapterLayout) -> Int {
        if sourceOffset <= chapter.lineStart { return 0 }
        if sourceOffset <= chapter.bodyStart { return layout.titlePrefix }
        let into = sourceOffset - chapter.bodyStart
        let sourceBody = layout.sourceBodyUTF16
        let composedBody = layout.composedBodyUTF16
        if sourceBody <= 0 || composedBody <= 0 { return layout.titlePrefix }
        if sourceBody == composedBody {
            return layout.titlePrefix + min(into, composedBody)
        }
        let mapped = Int((Double(into) / Double(sourceBody) * Double(composedBody)).rounded())
        return layout.titlePrefix + min(max(mapped, 0), composedBody)
    }

    func neighbor(after position: ReaderPosition) -> ReaderPosition? {
        if position.boundaryRemote != nil || position.chapterIndex >= chapters.count { return nil }
        let pages = layout(for: position.chapterIndex)?.pageCount ?? 1
        if position.pageIndex + 1 < pages {
            return ReaderPosition(chapterIndex: position.chapterIndex, pageIndex: position.pageIndex + 1)
        }
        if remoteChapterCount > 0, let remote = remoteIndex(at: position.chapterIndex) {
            let nextRemote = remote + 1
            guard nextRemote < remoteChapterCount else { return nil }
            if let loaded = engineIndex(ofRemote: nextRemote) {
                return ReaderPosition(chapterIndex: loaded, pageIndex: 0)
            }
            return ReaderPosition(
                chapterIndex: position.chapterIndex,
                pageIndex: position.pageIndex + 1,
                boundaryRemote: nextRemote
            )
        }
        let next = position.chapterIndex + 1
        guard next < chapters.count else { return nil }
        return ReaderPosition(chapterIndex: next, pageIndex: 0)
    }

    func neighbor(before position: ReaderPosition) -> ReaderPosition? {
        if let remote = position.boundaryRemote,
           chapters.indices.contains(position.chapterIndex) {
            let origin = chapters[position.chapterIndex]
            if remote > origin.remoteIndex {
                let pages = layout(for: position.chapterIndex)?.pageCount ?? 1
                return ReaderPosition(chapterIndex: position.chapterIndex, pageIndex: max(pages - 1, 0))
            }
            return ReaderPosition(chapterIndex: position.chapterIndex, pageIndex: 0)
        }
        if position.chapterIndex >= chapters.count {
            guard !chapters.isEmpty else { return nil }
            let last = chapters.count - 1
            let pages = layout(for: last)?.pageCount ?? 1
            return ReaderPosition(chapterIndex: last, pageIndex: max(pages - 1, 0))
        }
        if position.pageIndex > 0 {
            return ReaderPosition(chapterIndex: position.chapterIndex, pageIndex: position.pageIndex - 1)
        }
        if remoteChapterCount > 0, let remote = remoteIndex(at: position.chapterIndex) {
            let previousRemote = remote - 1
            guard previousRemote >= 0 else { return nil }
            if let loaded = engineIndex(ofRemote: previousRemote) {
                let pages = layout(for: loaded)?.pageCount ?? 1
                return ReaderPosition(chapterIndex: loaded, pageIndex: max(pages - 1, 0))
            }
            return ReaderPosition(chapterIndex: position.chapterIndex, pageIndex: -1, boundaryRemote: previousRemote)
        }
        let previous = position.chapterIndex - 1
        guard previous >= 0 else { return nil }
        let pages = layout(for: previous)?.pageCount ?? 1
        return ReaderPosition(chapterIndex: previous, pageIndex: max(pages - 1, 0))
    }

    private func sourceOffset(composed: Int, chapter: ChapterSlice, layout: ChapterLayout) -> Int {
        if composed <= 0 { return chapter.lineStart }
        if composed <= layout.titlePrefix { return chapter.bodyStart }
        let into = composed - layout.titlePrefix
        let sourceBody = layout.sourceBodyUTF16
        let composedBody = layout.composedBodyUTF16
        if sourceBody <= 0 || composedBody <= 0 { return chapter.bodyStart }
        if sourceBody == composedBody {
            return min(chapter.bodyStart + into, chapter.bodyEnd)
        }
        let mapped = Int((Double(into) / Double(max(composedBody, 1)) * Double(sourceBody)).rounded())
        return min(max(chapter.bodyStart + mapped, chapter.bodyStart), chapter.bodyEnd)
    }

    private func move(to target: ReaderPosition, animated: Bool) {
        animateNextTurn = animated
        position = target
        commit()
    }

    private func commit() {
        anchorOffset = currentUTF16()
        let index = min(max(position.chapterIndex, 0), max(chapters.count - 1, 0))
        let title: String
        if position.boundaryRemote != nil, chapters.indices.contains(position.chapterIndex) {
            title = chapters[position.chapterIndex].title
        } else if isEnd {
            title = chapters.last?.title ?? ""
        } else {
            title = currentChapter?.title ?? ""
        }
        if nextChapterFailed, failedAt != position {
            nextChapterFailed = false
            failedAt = nil
        }
        onProgress?(index, anchorOffset, title)
        requestNextIfNeeded()
    }

    private var isOnLastLoadedPage: Bool {
        guard !chapters.isEmpty, position.chapterIndex == chapters.count - 1 else { return false }
        let pages = layout(for: position.chapterIndex)?.pageCount ?? 1
        return position.pageIndex >= pages - 1
    }

    private func requestNextIfNeeded() {
        if remoteChapterCount > 0 {
            if let remote = position.boundaryRemote {
                guard !askedForNext, !nextChapterFailed else { return }
                askedForNext = true
                onNeedRemoteChapter?(remote)
                return
            }
            // 没有待下载的交界章，且已经停在末尾页：向书源重新拉目录，看作者是否更新了新章节。
            guard position.chapterIndex >= chapters.count,
                  !askedForCatalogRefresh,
                  !nextChapterFailed,
                  !catalogRefreshing else { return }
            askedForCatalogRefresh = true
            catalogRefreshing = true
            layoutRevision += 1
            onNeedRefreshCatalog?()
            return
        }
        guard hasUnloadedChapters, !askedForNext, !nextChapterFailed else { return }
        guard pageSize.width > 40, pageSize.height > 40 else { return }
        guard isOnLastLoadedPage else { return }
        askedForNext = true
        onNeedNextChapter?()
    }

    private func retryBoundary() {
        nextChapterFailed = false
        askedForNext = false
        failedAt = nil
        layoutRevision += 1
        commit()
    }

    private func boundaryIsPrevious(_ position: ReaderPosition) -> Bool {
        guard let remote = position.boundaryRemote,
              let origin = remoteIndex(at: position.chapterIndex) else { return false }
        return remote < origin
    }

    private func remoteIndex(at engineIndex: Int) -> Int? {
        guard chapters.indices.contains(engineIndex) else { return nil }
        return chapters[engineIndex].remoteIndex
    }

    private func engineIndex(ofRemote remoteIndex: Int) -> Int? {
        chapters.firstIndex { $0.remoteIndex == remoteIndex }
    }

    private func relayoutKeepingOffset() {
        cache.removeAll()
        guard pageSize.width > 40, pageSize.height > 40 else { return }
        animateNextTurn = false
        position = positionFor(offset: anchorOffset)
        layoutRevision += 1
        commit()
        noteReady()
    }

    private func trimCache(around chapter: Int) {
        guard cache.count > 6 else { return }
        cache = cache.filter { abs($0.key.chapter - chapter) <= 1 }
    }

    private func speakCurrentPage() {
        guard !isEnd, let laid = layout(for: position.chapterIndex) else { return }
        let text = laid.plainText(page: position.pageIndex)
        if laid.characterRanges.indices.contains(position.pageIndex) {
            speakingPageRange = laid.characterRanges[position.pageIndex]
        } else {
            speakingPageRange = nil
        }
        speech.start(
            parts: [text],
            mode: .page,
            rate: Float(settings.speechRate),
            voiceID: settings.speechVoiceID,
            sleepMinutes: settings.sleepMinutes,
            highlight: true
        )
    }

    private func speakCurrentChapter() {
        guard let chapter = currentChapter else { return }
        speakingPageRange = nil
        if highlightRange != nil {
            highlightRange = nil
            onHighlight?(nil)
        }
        let script = ChineseScript(rawValue: appliedLayout.script) ?? .original
        let raw = ChapterSplitter.substring(source, start: chapter.bodyStart, end: chapter.bodyEnd)
        let body = ChapterTextBuilder.plainParagraphs(
            ChineseConverter.convert(raw, to: script),
            blockWords: appliedLayout.blockWords
        )
        let title = ChineseConverter.convert(chapter.title, to: script)
        let spoken = body.isEmpty ? title : title + "。\n" + body
        speech.start(
            parts: [spoken],
            mode: .chapter,
            rate: Float(settings.speechRate),
            voiceID: settings.speechVoiceID,
            sleepMinutes: settings.sleepMinutes,
            highlight: false
        )
    }

    private func handleSpeechAdvance(_ step: SpeechController.Advance) {
        switch step {
        case .none:
            break
        case .page:
            go(delta: 1)
        case .chapter:
            if remoteChapterCount > 0, let remote = remoteIndex(at: position.chapterIndex) {
                let nextRemote = remote + 1
                guard nextRemote < remoteChapterCount else {
                    haltSpeech()
                    return
                }
                if let engineIndex = engineIndex(ofRemote: nextRemote) {
                    animateNextTurn = true
                    position = ReaderPosition(chapterIndex: engineIndex, pageIndex: 0)
                    commit()
                    speakCurrentChapter()
                } else {
                    animateNextTurn = true
                    position = ReaderPosition(
                        chapterIndex: position.chapterIndex,
                        pageIndex: position.pageIndex,
                        boundaryRemote: nextRemote
                    )
                    commit()
                    haltSpeech()
                }
                return
            }
            let nextIndex = position.chapterIndex + 1
            guard nextIndex < chapters.count else {
                haltSpeech()
                return
            }
            animateNextTurn = true
            position = ReaderPosition(chapterIndex: nextIndex, pageIndex: 0)
            commit()
            speakCurrentChapter()
        }
    }

    private func handleSpeechRange(_ range: NSRange) {
        let next: NSRange?
        if let base = speakingPageRange, range.length > 0, speech.isActive {
            next = NSRange(location: base.location + range.location, length: range.length)
        } else {
            next = nil
        }
        guard highlightRange != next else { return }
        highlightRange = next
        onHighlight?(next)
    }

    private func haltSpeech() {
        speakingPageRange = nil
        speech.stop()
        if highlightRange != nil {
            highlightRange = nil
            onHighlight?(nil)
        }
    }

    private func noteReady() {
        guard !didPrintReady else { return }
        guard ProcessInfo.processInfo.arguments.contains("-openSample") else { return }
        didPrintReady = true
        print("READER_READY")
    }
}
