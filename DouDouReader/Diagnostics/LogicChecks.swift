import CoreGraphics
import Darwin
import Foundation
#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum LogicChecks {
    private static var testing = false

    static func exitIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-selfTest"), !testing else { return }
        testing = true
        let errors = run()
        if errors.isEmpty {
            print("LOGIC_OK")
            exit(0)
        }
        for error in errors {
            print("LOGIC_FAIL \(error)")
        }
        exit(1)
    }

    static func run() -> [String] {
        var errors: [String] = []
        checkSplitter(&errors)
        checkPaginator(&errors)
        checkEngine(&errors)
        checkLazyChapter(&errors)
        checkReaderCatalog(&errors)
        checkBookIdentity(&errors)
        checkSparseChapter(&errors)
        checkEncoding(&errors)
        checkAuthor(&errors)
        checkBlockWords(&errors)
        checkSample(&errors)
        checkConversion(&errors)
        checkSources(&errors)
        checkTransportPolicy(&errors)
        checkBookSourceParsing(&errors)
        checkEpub(&errors)
        checkBookSearch(&errors)
        checkSourceSwitchHits(&errors)
        if BookLibrary.hash("豆豆").count != 64 {
            errors.append("内容哈希长度不对")
        }
        return errors
    }

    private static func checkSplitter(_ errors: inout [String]) {
        let sample = "这是开头\n\n第一章 雨\n正文甲\n第二章 风\n正文乙\n"
        let slices = ChapterSplitter.split(sample, fallbackTitle: "书")
        if slices.map(\.title) != ["开头", "第一章 雨", "第二章 风"] {
            errors.append("切章标题不符 \(slices.map(\.title))")
        }
        if slices.count > 1 {
            let body = ChapterSplitter.substring(sample, start: slices[1].bodyStart, end: slices[1].bodyEnd)
            if body.contains("第一章") || !body.contains("正文甲") {
                errors.append("章节正文不应包含标题行")
            }
        }
        if ChapterSplitter.isHeading("第一章，下雨了") {
            errors.append("带标点的行不应当成标题")
        }
        if !ChapterSplitter.isHeading("Chapter 2") || !ChapterSplitter.isHeading("尾声") {
            errors.append("英文标题或尾声没有被识别")
        }
        let longLine = "第一章 " + String(repeating: "很长", count: 30)
        if ChapterSplitter.isHeading(longLine) {
            errors.append("超长标题应当被拒绝")
        }
        if ChapterSplitter.split("", fallbackTitle: "").first?.title != "正文" {
            errors.append("空书应得到正文一章")
        }
    }

    private static func checkPaginator(_ errors: inout [String]) {
        let paragraph = String(repeating: "山高水长。", count: 400)
        let text = NSAttributedString(
            string: paragraph,
            attributes: [.font: PlatformFont.make(name: "", size: 18)]
        )
        let ranges = TextPaginator.ranges(for: text, pageSize: CGSize(width: 200, height: 280))
        let length = (paragraph as NSString).length
        var cursor = 0
        for range in ranges {
            if range.location != cursor || range.length <= 0 {
                errors.append("分页范围没有首尾相接，停在 \(cursor)")
                return
            }
            cursor = NSMaxRange(range)
        }
        if cursor != length {
            errors.append("分页没有覆盖全文 \(cursor)/\(length)")
        }
        if ranges.count < 2 {
            errors.append("长文本应当分成多页")
        }
    }

    private static func checkEngine(_ errors: inout [String]) {
        let paragraph = String(repeating: "字", count: 800)
        let text = "第一章 甲\n\(paragraph)\n第二章 乙\n\(paragraph)\n"
        let settings = ReaderSettingsStore(loadSaved: false)
        let engine = ReaderEngine(text: text, fallbackTitle: "测", startOffset: 0, settings: settings)
        engine.setPageSize(CGSize(width: 180, height: 240))
        if engine.position != ReaderPosition(chapterIndex: 0, pageIndex: 0) {
            errors.append("打开书应停在第一页")
        }
        if engine.chapters.count < 2 {
            errors.append("测试文本应当有两章")
            return
        }
        if engine.currentUTF16() != engine.chapters[0].lineStart {
            errors.append("第 0 页的进度应落在章首")
        }
        guard let first = engine.layout(for: 0) else {
            errors.append("第一章没有排版")
            return
        }
        var covered = 0
        for range in first.characterRanges {
            if range.location != covered || range.length <= 0 {
                errors.append("章节分页没有覆盖排版结果")
                return
            }
            covered = NSMaxRange(range)
        }
        if covered != first.storage.length {
            errors.append("章节分页长度不符")
        }
        if first.pageCount < 2 {
            errors.append("第一章应当超过一页")
            return
        }
        let origin = engine.position
        engine.go(delta: 1)
        if engine.position == origin {
            errors.append("下一页没有翻动")
        }
        engine.go(delta: -1)
        if engine.position != origin {
            errors.append("上一页没有回到原页")
        }
        engine.seek(to: engine.chapters[0].lineStart)
        for page in 0..<first.pageCount {
            if engine.position != ReaderPosition(chapterIndex: 0, pageIndex: page) {
                errors.append("翻到第 \(page) 页时位置是 \(engine.position)")
                break
            }
            let offset = engine.currentUTF16()
            if engine.positionFor(offset: offset) != engine.position {
                errors.append("进度 \(offset) 不能回到当前页")
                break
            }
            if page + 1 < first.pageCount {
                engine.go(delta: 1)
            }
        }
        var guardCount = 0
        while engine.position.chapterIndex == 0 && !engine.isEnd && guardCount < 200 {
            engine.go(delta: 1)
            guardCount += 1
        }
        if engine.position.chapterIndex != 1 {
            errors.append("没有进入第二章")
        } else if engine.currentUTF16() < engine.chapters[1].lineStart {
            errors.append("第二章的进度仍落在第一章")
        }
        var steps = 0
        while !engine.isEnd && steps < 400 {
            engine.go(delta: 1)
            steps += 1
        }
        if !engine.isEnd {
            errors.append("没有走到全书完")
        }
        engine.go(delta: -1)
        if engine.isEnd {
            errors.append("从全书完返回失败")
        }
        let total = (TextDecoding.normalize(text) as NSString).length
        let reopened = ReaderEngine(text: text, fallbackTitle: "测", startOffset: total, settings: settings)
        reopened.setPageSize(CGSize(width: 180, height: 240))
        if reopened.isEnd || reopened.position.chapterIndex != reopened.chapters.count - 1 {
            errors.append("读完后重新打开应落在最后一页")
        }
    }

    /// 读到已加载章节的最后一页才要下一章。人还在本章时，新章节接在后面，不把进度拽走。
    private static func checkLazyChapter(_ errors: inout [String]) {
        let settings = ReaderSettingsStore(loadSaved: false)
        let paragraph = String(repeating: "字", count: 800)
        let engine = ReaderEngine(text: "第一章 甲\n\(paragraph)\n", fallbackTitle: "测", startOffset: 0, settings: settings)
        engine.hasUnloadedChapters = true
        var asks = 0
        engine.onNeedNextChapter = { asks += 1 }
        engine.setPageSize(CGSize(width: 180, height: 240))
        guard let layout = engine.layout(for: 0), layout.pageCount >= 2 else {
            errors.append("懒加载测试第一章应当超过一页")
            return
        }
        if asks != 0 {
            errors.append("还没到章末就去要下一章")
        }
        if engine.endTitle != "正在加载下一章" {
            errors.append("还有后续章节时文末提示不对")
        }
        while engine.position.pageIndex < layout.pageCount - 1, !engine.isEnd {
            engine.go(delta: 1)
        }
        if asks != 1 {
            errors.append("章末没有请求下一章 \(asks)")
            return
        }
        let stayed = engine.position
        guard engine.appendLoadedChapter(title: "第二章 乙", body: paragraph) else {
            errors.append("追加下一章失败")
            return
        }
        if engine.position != stayed {
            errors.append("还在本章时追加不该把读者带走")
        }
        if engine.chapters.count != 2 || engine.chapters[1].title != "第二章 乙" {
            errors.append("追加后的章节不对")
        }
        if asks != 1 {
            errors.append("追加后不该立刻再要一章")
        }
        engine.hasUnloadedChapters = false
        var guardCount = 0
        while !engine.isEnd, guardCount < 400 {
            engine.go(delta: 1)
            guardCount += 1
        }
        if !engine.isEnd || engine.endTitle != "全书完" {
            errors.append("没有后续章节时应走到全书完")
        }
        if asks != 1 {
            errors.append("没有后续章节时不该再请求")
        }

        let tail = ReaderEngine(text: "第一章 甲\n很短。\n", fallbackTitle: "测", startOffset: 0, settings: settings)
        tail.hasUnloadedChapters = true
        tail.setPageSize(CGSize(width: 180, height: 240))
        guard tail.layout(for: 0)?.pageCount == 1 else {
            errors.append("短章应当只有一页")
            return
        }
        tail.go(delta: 1)
        if !tail.isEnd || tail.endTitle != "正在加载下一章" {
            errors.append("短章翻过最后一页应停在加载页")
            return
        }
        guard tail.appendLoadedChapter(title: "第二章 乙", body: "新的一章。") else {
            errors.append("加载页追加失败")
            return
        }
        if tail.position != ReaderPosition(chapterIndex: 1, pageIndex: 0) || tail.isEnd {
            errors.append("停在加载页时追加应进入新章")
        }
    }

    /// 在线书的目录用保存下来的全部章节名。只下载了第一章时，后面的章节也要列出来。
    private static func checkReaderCatalog(_ errors: inout [String]) {
        let online = ReaderCatalog.rows(
            engineTitles: ["第一章 甲"],
            remoteTitles: ["第一章 甲", "第二章 乙", "第三章 丙"],
            loadedIndices: [0]
        )
        if online.map(\.title) != ["第一章 甲", "第二章 乙", "第三章 丙"]
            || online.map(\.isLoaded) != [true, false, false] {
            errors.append("在线目录应当列出还没下载的章节")
        }
        let local = ReaderCatalog.rows(engineTitles: ["序章", "第一章"], remoteTitles: [], loadedIndices: [])
        if local.map(\.title) != ["序章", "第一章"] || local.contains(where: { !$0.isLoaded }) {
            errors.append("本地目录应当只用已经拆出的章节")
        }
        let blank = ReaderCatalog.rows(engineTitles: ["书名"], remoteTitles: ["  ", ""], loadedIndices: [0])
        if blank.map(\.title) != ["书名", "第2章"] || blank.map(\.isLoaded) != [true, false] {
            errors.append("空白的远端章节名应当回退 \(blank.map(\.title))")
        }
        let gap = ReaderCatalog.rows(
            engineTitles: ["第一章 甲", "第六章 己"],
            remoteTitles: ["第一章 甲", "第二章 乙", "第三章 丙", "第四章 丁", "第五章 戊", "第六章 己"],
            loadedIndices: [0, 5]
        )
        if gap.map(\.isLoaded) != [true, false, false, false, false, true] {
            errors.append("目录不该把中间空档标成已下载")
        }
    }

    private static func checkBookIdentity(_ errors: inout [String]) {
        if !BookIdentity.same(title: "《三体》", author: "刘慈欣", otherTitle: "三体", otherAuthor: "刘慈欣") {
            errors.append("同一本书应当认作一本")
        }
        if BookIdentity.same(title: "三体", author: "刘慈欣", otherTitle: "三体", otherAuthor: "王晋康") {
            errors.append("作者不同不应当并成一本")
        }
        if !BookIdentity.same(title: "三体", author: "", otherTitle: "三体", otherAuthor: "刘慈欣") {
            errors.append("一边没有作者时按书名并成一本")
        }
    }

    /// 跳到后面的章节只下载那一章。滑到交界处才要相邻的一章。
    private static func checkSparseChapter(_ errors: inout [String]) {
        let settings = ReaderSettingsStore(loadSaved: false)
        let engine = ReaderEngine(
            stored: [StoredChapter(index: 0, title: "第一章 甲", body: "很短。")],
            remoteCount: 4,
            fallbackTitle: "测",
            startOffset: 0,
            settings: settings
        )
        engine.setPageSize(CGSize(width: 180, height: 240))
        guard engine.layout(for: 0)?.pageCount == 1 else {
            errors.append("稀疏章应当只有一页")
            return
        }
        var asked: [Int] = []
        engine.onNeedRemoteChapter = { asked.append($0) }
        if !asked.isEmpty {
            errors.append("还没到交界不该要章节")
            return
        }
        engine.go(delta: 1)
        if asked != [1] || engine.position.boundaryRemote != 1 {
            errors.append("章末应当只请求下一章 \(asked) \(String(describing: engine.position.boundaryRemote))")
            return
        }
        guard engine.insertRemoteChapter(remoteIndex: 3, title: "第四章 丁", body: "很远。") else {
            errors.append("插入远处章节失败")
            return
        }
        if engine.position.boundaryRemote != 1 || engine.chapters.map(\.remoteIndex) != [0, 3] {
            errors.append("插入不相邻的章节不该离开交界 \(engine.chapters.map(\.remoteIndex))")
            return
        }
        guard engine.insertRemoteChapter(remoteIndex: 1, title: "第二章 乙", body: "相邻。") else {
            errors.append("插入相邻章节失败")
            return
        }
        if engine.position.chapterIndex != 1 || engine.position.boundaryRemote != nil
            || engine.chapters.map(\.remoteIndex) != [0, 1, 3] {
            errors.append("补上相邻章节后应进入该章 \(engine.chapters.map(\.remoteIndex))")
            return
        }
        let first = ChapterSplitter.substring(engine.source, start: engine.chapters[0].bodyStart, end: engine.chapters[0].bodyEnd)
        let second = ChapterSplitter.substring(engine.source, start: engine.chapters[1].bodyStart, end: engine.chapters[1].bodyEnd)
        if !first.contains("很短") || !second.contains("相邻") {
            errors.append("插入后正文串了")
        }
        engine.jump(to: 0)
        asked.removeAll()
        engine.go(delta: 1)
        if engine.position.chapterIndex != 1 || engine.position.boundaryRemote != nil || !asked.isEmpty {
            errors.append("下一章已经在本地时应直接翻过去")
        }
        engine.jumpToRemote(3)
        asked.removeAll()
        engine.go(delta: -1)
        if asked != [2] || engine.position.boundaryRemote != 2 {
            errors.append("章首应当只请求上一章 \(asked) \(String(describing: engine.position.boundaryRemote))")
        }
        engine.noteNextChapterFailed()
        if !engine.isChapterLoadFailed {
            errors.append("章节加载失败后应当能重试")
            return
        }
        asked.removeAll()
        engine.retryCurrentChapter()
        if asked != [2] || engine.isChapterLoadFailed || engine.position.boundaryRemote != 2 {
            errors.append("重试应当再请求这一章 \(asked)")
        }
    }

    private static func checkSourceSwitchHits(_ errors: inout [String]) {
        let batches = [
            SourceSearchBatch(sourceID: "current", sourceName: "当前", phase: .books([
                CatalogBook(id: "same", title: "三体", author: "刘慈欣", summary: "")
            ])),
            SourceSearchBatch(sourceID: "other", sourceName: "乙源", phase: .books([
                CatalogBook(id: "ok", title: "《三体》", author: "刘慈欣", summary: "最新"),
                CatalogBook(id: "no", title: "三体", author: "别人", summary: ""),
                CatalogBook(id: "same", title: "三体", author: "刘慈欣", summary: "同一地址")
            ])),
            SourceSearchBatch(sourceID: "down", sourceName: "丙源", phase: .failed("超时"))
        ]
        let hits = BookSearch.switchHits(
            title: "三体",
            author: "刘慈欣",
            excludingSourceID: "current",
            excludingBookID: "same",
            batches: batches
        )
        if hits.map(\.sourceID) != ["other"] || hits.map(\.book.id) != ["ok"] {
            errors.append("换源应当只留下其他书源里的同一本书")
        }
    }

    private static func checkEncoding(_ errors: inout [String]) {
        if TextDecoding.normalize("\u{FEFF}a\r\nb\rc") != "a\nb\nc" {
            errors.append("换行和 BOM 没有整理干净")
        }
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data("豆".utf8)
        if TextDecoding.decode(bom) != "豆" {
            errors.append("UTF-8 BOM 解码失败")
        }
        let original = "豆豆阅读，简体。"
        guard let data = original.data(using: TextDecoding.gb18030) else {
            errors.append("GB18030 编码失败")
            return
        }
        if TextDecoding.decode(data) != original {
            errors.append("GB18030 解码结果不符")
        }
    }

    private static func checkAuthor(_ errors: inout [String]) {
        let text = "灯塔邮局\n作者：豆豆\n第一章 甲\n正文"
        if BookMetadata.author(in: text) != "豆豆" {
            errors.append("作者行没有解析出来")
        }
        if BookMetadata.author(in: "作者:林书") != "林书" {
            errors.append("半角冒号的作者行没有解析出来")
        }
        let longName = "作者：" + String(repeating: "名", count: 21)
        if !BookMetadata.author(in: longName).isEmpty {
            errors.append("过长的作者名应当忽略")
        }
    }

    private static func checkBlockWords(_ errors: inout [String]) {
        let filtered = ChapterTextBuilder.plainParagraphs("甲\n这是广告句\n乙", blockWords: "广告")
        if filtered != "甲\n乙" {
            errors.append("屏蔽词没有去掉整段：\(filtered)")
        }
    }

    private static func checkSample(_ errors: inout [String]) {
        let titles = ChapterSplitter.split(SampleNovel.text, fallbackTitle: SampleNovel.title).map(\.title)
        let expected = ["序章", "第一章 雨夜的信封", "第二章 灯塔不回信", "第三章 第三班邮船", "第四章 把地址写对", "尾声"]
        if titles != expected {
            errors.append("示例章节不符 \(titles)")
        }
        if BookMetadata.author(in: SampleNovel.text) != "豆豆" {
            errors.append("示例作者不符")
        }
    }

    private static func checkConversion(_ errors: inout [String]) {
        let traditional = ChineseConverter.convert("后", to: .traditional)
        if traditional == "后" {
            errors.append("简体转繁体没有生效")
        }
        if ChineseConverter.convert(traditional, to: .simplified) != "后" {
            errors.append("繁体转回简体失败")
        }
        if ChineseConverter.convert("后", to: .original) != "后" {
            errors.append("原文模式不应改字")
        }
    }

    /// 书源大量使用明文 HTTP。局部 ATS 例外会让全局放行失效。
    private static func checkTransportPolicy(_ errors: inout [String]) {
        let ats = Bundle.main.infoDictionary?["NSAppTransportSecurity"] as? [String: Any]
        if (ats?["NSAllowsArbitraryLoads"] as? Bool) != true {
            errors.append("ATS 没有允许明文 HTTP，书源会被系统拦截")
        }
        let overriding = [
            "NSAllowsLocalNetworking",
            "NSAllowsArbitraryLoadsInWebContent",
            "NSAllowsArbitraryLoadsForMedia"
        ].filter { ats?[$0] != nil }
        if overriding.isEmpty != true {
            errors.append("ATS 局部例外会让明文放行失效 \(overriding)")
        }
    }

    private static func checkSources(_ errors: inout [String]) {
        if SourceURL.parse("https://example.com/api")?.host != "example.com" {
            errors.append("https 书源地址没有被接受")
        }
        if SourceURL.parse("http://example.com") != nil {
            errors.append("公网 http 书源应当被拒绝")
        }
        if SourceURL.parse("http://10.0.0.8/catalog")?.host != "10.0.0.8" {
            errors.append("局域网 http 书源应当被接受")
        }
        if SourceURL.parse("http://127.0.0.1") == nil || SourceURL.parse("http://192.168.1.9/books") == nil {
            errors.append("本机或 192.168 的 http 应当被接受")
        }
        if SourceURL.parse("http://172.16.0.4/a") == nil || SourceURL.parse("http://172.15.0.4/a") != nil {
            errors.append("172 网段的 http 判断不对")
        }
        if SourceURL.parse("http://169.254.169.254/") != nil || SourceURL.parse("file:///tmp/book.txt") != nil {
            errors.append("链路本地地址或文件地址不应当成为书源")
        }
        if let stripped = SourceURL.parse("https://user:secret@example.com/api?token=1#part"),
           let parts = URLComponents(url: stripped, resolvingAgainstBaseURL: false) {
            if parts.user != nil || parts.query != nil || parts.fragment != nil || parts.path != "/api" {
                errors.append("书源地址应当去掉账号、查询和片段")
            }
        } else {
            errors.append("带账号的 https 书源没有被解析")
        }

        let base = URL(string: "https://books.example/v1")!
        guard let search = SourceEndpoint.search(base, query: "灯塔"),
              let searchParts = URLComponents(url: search, resolvingAgainstBaseURL: false) else {
            errors.append("搜索地址没有生成")
            return
        }
        if !search.path.hasSuffix("/search") || searchParts.queryItems?.first(where: { $0.name == "q" })?.value != "灯塔" {
            errors.append("搜索地址应当是 /search?q=灯塔")
        }
        if SourceEndpoint.safeID("a/b") != nil || SourceEndpoint.safeID("..") != nil || SourceEndpoint.safeID("") != nil {
            errors.append("不安全的书号没有被拒绝")
        }
        if SourceEndpoint.book(base, id: "../secret") != nil || SourceEndpoint.chapter(base, bookID: "demo", chapterID: "a?b") != nil {
            errors.append("带路径或查询的书号不应当拼进地址")
        }
        if SourceEndpoint.book(base, id: "demo")?.path != "/v1/books/demo" {
            errors.append("书籍地址应当是 /books/{id}")
        }

        do {
            let books = try CatalogParser.books(from: Data(
                #"{"books":[{"id":"demo","title":"海岸来信","author":"林书","summary":"一封信"}]}"#.utf8
            ))
            if books.count != 1 || books[0].id != "demo" || books[0].title != "海岸来信" || books[0].author != "林书" {
                errors.append("书源搜索结果解析不符")
            }
            let detail = try CatalogParser.detail(from: Data(
                #"{"id":"demo","title":"海岸来信","author":"林书","chapters":[{"id":"c1","title":"第一章 来信"},{"id":"c2","title":"第二章 回信"}]}"#.utf8
            ))
            let first = try CatalogParser.chapter(from: Data(
                #"{"id":"c1","title":"第一章 来信","content":"信封是湿的。"}"#.utf8
            ))
            let second = try CatalogParser.chapter(from: Data(
                #"{"id":"c2","title":"第二章 回信","content":"灯塔亮了一夜。"}"#.utf8
            ))
            let assembled = CatalogText.assemble(
                author: detail.author,
                chapters: [(first.title, first.content), (second.title, second.content)]
            )
            let titles = ChapterSplitter.split(assembled, fallbackTitle: detail.title).map(\.title)
            if !titles.contains("第一章 来信") || !titles.contains("第二章 回信") || BookMetadata.author(in: assembled) != "林书" {
                errors.append("拼好的正文切章不符 \(titles)")
            }
        } catch {
            errors.append("书源 JSON 解析失败")
        }
        do {
            _ = try CatalogParser.books(from: Data("[]".utf8))
            errors.append("坏的书源 JSON 应当失败")
        } catch let error as SourceError {
            if case .badResponse = error {
            } else {
                errors.append("书源 JSON 失败原因不对")
            }
        } catch {
            errors.append("书源 JSON 解析抛出了意外错误")
        }

        let kept = SourceRecord(name: "家里", baseURL: "http://10.0.0.8/catalog")
        kept.enabled = true
        let disabled = SourceRecord(name: "停用", baseURL: "http://192.168.0.2/catalog")
        disabled.enabled = false
        let rejected = SourceRecord(name: "公网", baseURL: "http://example.com/catalog")
        let catalogs = BookCatalogs.enabled(records: [kept, disabled, rejected])
        if catalogs.map(\.id) != [SampleBookCatalog.stableID, kept.id.uuidString] || catalogs.map(\.name) != ["豆豆书库", "家里"] {
            errors.append("可用书源应当保留内置和启用的局域网源")
        }

        switch finishAsync({ try await probeCatalogs() }) {
        case .failure(let error):
            errors.append("书源请求没有完成：\(error)")
        case .success(let probe):
            let sampleTitles = ChapterSplitter.split(probe.sampleText, fallbackTitle: probe.sampleFetchedTitle).map(\.title)
            let remoteTitles = ChapterSplitter.split(probe.remoteText, fallbackTitle: probe.remoteFetchedTitle).map(\.title)
            if probe.sampleTitle != SampleNovel.title || probe.sampleAuthor != "豆豆" || probe.sampleID != "lighthouse" {
                errors.append("内置书库搜索不符")
            }
            if !probe.sampleMissed || sampleTitles != ["序章", "第一章 雨夜的信封", "第二章 灯塔不回信", "第三章 第三班邮船", "第四章 把地址写对", "尾声"] {
                errors.append("内置书库正文不符 \(sampleTitles)")
            }
            if !probe.sampleMissing {
                errors.append("内置书库应当拒绝不存在的书")
            }
            if probe.remoteTitle != "海岸来信" || probe.remoteID != "demo" || BookMetadata.author(in: probe.remoteText) != "林书" {
                errors.append("远端书源搜索或作者不符")
            }
            if !remoteTitles.contains("第一章 来信") || !remoteTitles.contains("第二章 回信") || probe.marks != ["1/2", "2/2"] {
                errors.append("远端书源章节不符 \(remoteTitles) \(probe.marks)")
            }
            if probe.openingCount != 2
                || !probe.openingText.contains("信封是湿的。")
                || probe.openingText.contains("灯塔亮了一夜。")
                || !probe.openingNext.contains("灯塔亮了一夜。") {
                errors.append("点开远端书应当只带第一章")
            }
            if !probe.missingIsNotFound || !probe.badJSON {
                errors.append("远端书源的错误结果不对")
            }
        }
        CatalogURLStub.setRoutes([:])
    }

    private static func checkBookSourceParsing(_ errors: inout [String]) {
        // 1. 测试阅读 3.0 (Legado) 单源与数组解析
        let legadoJSON = """
        [
          {
            "bookSourceName": "测试笔趣阁",
            "bookSourceUrl": "https://biquge.test",
            "bookSourceGroup": "阅读精选",
            "searchUrl": "https://biquge.test/search?keyword={{key}}",
            "ruleSearch": {
              "bookList": ".search-list .item",
              "name": ".title@text",
              "author": ".author@text",
              "bookUrl": ".title a@href",
              "intro": ".desc@text"
            },
            "ruleToc": {
              "chapterList": ".chapters a",
              "chapterName": "text",
              "chapterUrl": "href"
            },
            "ruleContent": {
              "content": "#content@text",
              "replaceRegex": "##广告.*##"
            }
          }
        ]
        """
        do {
            let parsed = try BookSourceParser.parse(text: legadoJSON)
            if parsed.count != 1 {
                errors.append("阅读 3.0 书源解析数量不为 1")
            } else {
                let first = parsed[0]
                if first.kind != .legado || first.name != "测试笔趣阁" || first.group != "阅读精选" {
                    errors.append("阅读 3.0 书源元数据不符")
                }
                if first.searchRule.urlTemplate != "https://biquge.test/search?keyword={{key}}" {
                    errors.append("阅读 3.0 搜索模板不符")
                }
                if first.searchRule.nameSelector != ".title@text" || first.contentRule.replaceRules != ["##广告.*##"] {
                    errors.append("阅读 3.0 规则选择器不符")
                }
            }
        } catch {
            errors.append("阅读 3.0 JSON 解析失败：\(error)")
        }

        // 2. 测试香色闺阁 (XiangSe) alias 字典格式解析
        let xiangseJSON = """
        {
          "bato-v1": {
            "sourceName": "测试香色源",
            "sourceUrl": "https://xiangse.test",
            "sourceType": "text",
            "weight": "8888",
            "searchBook": {
              "actionID": "searchBook",
              "requestInfo": "https://xiangse.test/search?word=%@keyWord&page=%@pageIndex",
              "list": "//ul[@id='result']/li",
              "bookName": "//h2/a/text()",
              "author": "//span[@class='author']/text()",
              "detailUrl": "//h2/a/@href",
              "desc": "//p[@class='intro']/text()"
            },
            "chapterList": {
              "actionID": "chapterList",
              "list": "//div[@id='chapters']/a",
              "title": "//text()",
              "url": "//@href"
            },
            "chapterContent": {
              "actionID": "chapterContent",
              "content": "//div[@id='content']/text()"
            }
          }
        }
        """
        do {
            let parsed = try BookSourceParser.parse(text: xiangseJSON)
            if parsed.count != 1 {
                errors.append("香色闺阁书源解析数量不为 1")
            } else {
                let first = parsed[0]
                if first.kind != .xiangse || first.name != "测试香色源" || first.weight != 8888 {
                    errors.append("香色闺阁元数据不符")
                }
                if !first.searchRule.urlTemplate.contains("word=%@keyWord") {
                    errors.append("香色闺阁搜索链接模板不符")
                }
                if first.searchRule.listSelector != "//ul[@id='result']/li" {
                    errors.append("香色闺阁搜索列表选择器不符")
                }
                if !first.exploreRule.urlTemplate.isEmpty {
                    errors.append("没有发现规则的香色书源不应带发现地址")
                }
            }
        } catch {
            errors.append("香色闺阁 JSON 解析失败：\(error)")
        }

        checkSourceSwitch(&errors)

        // 3. 测试 HTMLMiniParser 与选择器引擎
        let sampleHTML = """
        <html>
          <body>
            <div id="wrapper">
              <ul class="book-list">
                <li class="book-item">
                  <a href="/book/101">海边的&nbsp;&amp;&nbsp;灯塔</a>
                  <span class="author">林书</span>
                </li>
                <li class="book-item">
                  <a href="/book/102">第二本书</a>
                  <span class="author">测试</span>
                </li>
              </ul>
              <div id="content">
                第一行正文。<br/>第二行正文。
                广告：点击购买会员
              </div>
            </div>
          </body>
        </html>
        """
        let dom = HTMLMiniParser.parse(sampleHTML)
        let listItems = HTMLMiniParser.queryNodes(root: dom, rule: "//ul[@class='book-list']/li")
        if listItems.count != 2 {
            errors.append("HTMLMiniParser 列表节点匹配数量不为 2: \(listItems.count)")
        } else {
            let firstTitle = HTMLMiniParser.queryStrings(root: listItems[0], rule: "a@text").first
            if firstTitle != "海边的 & 灯塔" {
                errors.append("HTMLMiniParser 文本提取或实体解码不符：\(firstTitle ?? "nil")")
            }
            let firstHref = HTMLMiniParser.queryStrings(root: listItems[0], rule: "a@href").first
            if firstHref != "/book/101" {
                errors.append("HTMLMiniParser 属性提取不符：\(firstHref ?? "nil")")
            }
        }
        let cleanContent = HTMLMiniParser.queryStrings(root: dom, rule: "#content@text##广告.*##").first
        if cleanContent?.contains("广告") == true {
            errors.append("HTMLMiniParser 正则替换未生效：\(cleanContent ?? "nil")")
        }
        let commaHTML = """
        <div class="newbox"><ul><li><a href="/book/1">甲</a></li></ul></div>
        <div class="mybox"><li><a href="/book/2">乙</a></li></div>
        """
        let commaNodes = HTMLMiniParser.queryNodes(root: HTMLMiniParser.parse(commaHTML), rule: ".newbox ul li, .mybox li")
        if commaNodes.count != 2 {
            errors.append("逗号选择器没有分别匹配：\(commaNodes.count)")
        }

        // 3.5 @js: 规则字面量提取：纯 @js: 不应被整体丢弃。
        let jsReturn = HTMLMiniParser.queryStrings(root: dom, rule: "@js:return 'https://site.test/ch/1'").first
        if jsReturn != "https://site.test/ch/1" {
            errors.append("@js: return 字面量提取不符：\(jsReturn ?? "nil")")
        }
        let jsURL = HTMLMiniParser.queryStrings(root: dom, rule: "@js:result = 'https://direct.test/x';").first
        if jsURL != "https://direct.test/x" {
            errors.append("@js: 字面 URL 提取不符：\(jsURL ?? "nil")")
        }
        // 带选择器主体 + @js: 后缀时，选择器照常执行、JS 部分跳过。
        let withSelector = HTMLMiniParser.queryStrings(root: dom, rule: "a@text||@js:result.title").first
        if withSelector?.contains("灯塔") != true && withSelector?.contains("第二本") != true {
            errors.append("@js: 后缀附加在选择器后未保留选择器结果：\(withSelector ?? "nil")")
        }

        // 3.6 XPath 函数谓词：contains / starts-with / text()= / last()
        let containsNodes = HTMLMiniParser.queryNodes(root: dom, rule: "//li[contains(@class,'book-item')]")
        if containsNodes.count != 2 {
            errors.append("contains 谓词匹配数量不为 2：\(containsNodes.count)")
        }
        let startsNodes = HTMLMiniParser.queryStrings(root: dom, rule: "//a[starts-with(@href,'/book/1')]/@text")
        if startsNodes.first != "海边的 & 灯塔" {
            errors.append("starts-with 谓词匹配不符：\(startsNodes.first ?? "nil")")
        }
        let textEqNodes = HTMLMiniParser.queryNodes(root: dom, rule: "//a[text()='第二本书']")
        if textEqNodes.count != 1 {
            errors.append("text()= 谓词匹配数量不为 1：\(textEqNodes.count)")
        }
        let lastNodes = HTMLMiniParser.queryNodes(root: dom, rule: "//li[last()]")
        if lastNodes.count != 1 || lastNodes[0].allText.contains("灯塔") {
            errors.append("last() 谓词未取到最后一个 li")
        }

        // 4. 测试 RuleBasedBookCatalog 端到端链路与网络模拟
        switch finishAsync({ try await probeRuleCatalog() }) {
        case .failure(let error):
            errors.append("规则书源请求测试失败：\(error)")
        case .success(let passed):
            if !passed {
                errors.append("规则书源搜索或内容抓取不符")
            }
        }
        if let shuba = BookSourceLibrary.switchable(records: []).first(where: { $0.id == "preset-69shuba" }) {
            switch finishAsync({ try await probeShubaBook(recordID: shuba.id, source: shuba.source) }) {
            case .failure(let error):
                errors.append("69书吧正文抓取失败：\(error)")
            case .success(let message):
                if let message {
                    errors.append(message)
                }
            }
        } else {
            errors.append("切换列表没有 69书吧")
        }
        if let b365 = BookSourceLibrary.switchable(records: []).first(where: { $0.id == "preset-biqu365" }) {
            switch finishAsync({ try await probeBiqu365Book(recordID: b365.id, source: b365.source) }) {
            case .failure(let error):
                errors.append("笔趣阁365正文抓取失败：\(error)")
            case .success(let message):
                if let message {
                    errors.append(message)
                }
            }
        } else {
            errors.append("切换列表没有笔趣阁365")
        }
        switch finishAsync({ try await probeOpeningChapterOrder() }) {
        case .failure(let error):
            errors.append("最新章节横幅目录测试失败：\(error)")
        case .success(let message):
            if let message {
                errors.append(message)
            }
        }
        CatalogURLStub.setRoutes([:])

        // 5. 测试 SourceRecord 与 SwiftData 兼容字段
        let record = SourceRecord(
            name: "阅读源",
            baseURL: "https://example.com",
            format: BookSourceKind.legado.rawValue,
            rawJSON: legadoJSON
        )
        if record.format != "legado" || record.rawJSON != legadoJSON {
            errors.append("SourceRecord 新增字段保存不符")
        }
        let enabledCatalogs = BookCatalogs.enabled(records: [record])
        if !enabledCatalogs.contains(where: { $0 is RuleBasedBookCatalog }) {
            errors.append("启用书源中未生成 RuleBasedBookCatalog")
        }

        // 6. 测试预设书源规范与完整性
        let presets = PresetBookSources.all
        if presets.count != 28 {
            errors.append("预设书源数量不为 28: \(presets.count)")
        }
        let legadoPresets = presets.filter { $0.kind == .legado }
        let xiangsePresets = presets.filter { $0.kind == .xiangse }
        if legadoPresets.isEmpty || xiangsePresets.isEmpty {
            errors.append("预设书源必须同时包含阅读 3.0 与香色闺阁格式")
        }
        for item in presets {
            if item.source.name.isEmpty || item.source.sourceURL.isEmpty || item.source.searchRule.urlTemplate.isEmpty {
                errors.append("预设书源 \(item.name) 关键规则缺失")
            }
            if item.source.exploreRule.urlTemplate.isEmpty {
                errors.append("预设书源 \(item.name) 缺少发现规则")
            }
        }
    }

    private static func checkSourceSwitch(_ errors: inout [String]) {
        let sites = BookSourceLibrary.switchable(records: [])
        guard let feilu = sites.first(where: { $0.id == "site-feilu" }),
              let shuba = sites.first(where: { $0.id == "preset-69shuba" }),
              let xiangshu = sites.first(where: { $0.id == "preset-xiangshu" }) else {
            errors.append("切换列表缺少飞卢、69书吧或香书小说")
            return
        }
        let removedIDs = [
            "site-y52", "preset-qidian", "site-allnovel", "site-witch",
            "site-kuangren", "site-wanwenxue", "site-gegedang", "site-wuwen"
        ]
        if sites.contains(where: { removedIDs.contains($0.id) }) {
            errors.append("无法解析出书的书源仍在切换列表")
        }
        if !feilu.source.sourceURL.contains("faloo.com") {
            errors.append("飞卢没有切到自己的站点 \(feilu.source.sourceURL)")
        }
        if sites.contains(where: { $0.id != feilu.id && $0.source.sourceURL.contains("faloo.com") }) {
            errors.append("别的书源占用了飞卢地址")
        }
        let presetHosts = PresetBookSources.all.map { BookSourceLibrary.hostKey($0.source.sourceURL) }
        if Set(presetHosts).count != presetHosts.count {
            errors.append("预设书源主机重复 \(presetHosts)")
        }
        if PresetBookSources.all.contains(where: { $0.kind == .xiangse && $0.id == "preset-xiangshu" }) != true {
            errors.append("香书小说没有作为香色闺阁格式保留")
        }
        let filterTemplate = "男频::https://www.qidian.com/all/chanId{{分类}}-subCateId-1-orderId{{排序}}-style{{属性}}-pageSize20-siteid1-pubflag0-hiddenField0-page{{page}}/?words={{字数}}&status={{状态}}&quality={{品质}}&update={{更新}}&&分类&&全部::-1&&玄幻::21&&字数&&全部::0&&30万字以下::1"
        let filterChannels = ExploreURLParser.channels(from: filterTemplate)
        if filterChannels.first?.title != "男频"
            || filterChannels.first?.filters.first(where: { $0.key == "分类" })?.options.contains(where: { $0.label == "玄幻" && $0.value == "21" }) != true {
            errors.append("发现筛选语法不符")
        }
        if let template = filterChannels.first?.urlTemplate {
            let url = ExploreURLParser.resolve(
                template: template,
                selections: ["分类": "21", "排序": "0", "属性": "-1", "字数": "1", "状态": "0", "品质": "-1", "更新": "0"],
                page: 2
            )
            if !url.contains("chanId21") || !url.contains("page2") || !url.contains("words=1") {
                errors.append("发现地址没有套用筛选 \(url)")
            }
        }
        let xiangshuHTML = """
        <div id="newscontent"><div class="l"><ul>
          <li><span class="s2"><a href="http://www.ibiqugu.net/166/166645/">旧生物</a></span><span class="s4">穿黄衣的阿肥</span></li>
          <li><span class="s2"><a href="http://www.ibiqugu.net/146/146318/">御兽，我是最强路人</a></span><span class="s5">雾雨风雾霭</span></li>
        </ul></div></div>
        """
        let xiangshuBooks = books(in: xiangshuHTML, rule: xiangshu.source.exploreRule)
        if xiangshuBooks.first?.title != "旧生物" || xiangshuBooks.first?.author != "穿黄衣的阿肥"
            || xiangshuBooks.contains(where: { $0.title == "御兽，我是最强路人" && $0.author == "雾雨风雾霭" }) != true {
            errors.append("香书小说没有解析出书籍 \(xiangshuBooks)")
        }

        let disabled = SourceRecord(
            name: "飞卢小说网",
            baseURL: "https://wap.faloo.com",
            format: BookSourceKind.legado.rawValue,
            rawJSON: ""
        )
        disabled.enabled = false
        let hidden = BookSourceLibrary.switchable(records: [disabled])
        if hidden.contains(where: { $0.id == "site-feilu" || BookSourceLibrary.hostKey($0.source.sourceURL) == "wap.faloo.com" }) {
            errors.append("关闭飞卢后它仍出现在切换列表")
        }

        if let preset = PresetBookSources.all.first {
            do {
                let data = try JSONEncoder().encode(preset.source)
                guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    errors.append("旧书源 JSON 不是对象")
                    return
                }
                object.removeValue(forKey: "exploreRule")
                if var toc = object["tocRule"] as? [String: Any] {
                    toc.removeValue(forKey: "startAtFirstChapter")
                    object["tocRule"] = toc
                }
                let stripped = try JSONSerialization.data(withJSONObject: object)
                let decoded = try JSONDecoder().decode(UniversalBookSource.self, from: stripped)
                if decoded.name != preset.source.name || !decoded.exploreRule.urlTemplate.isEmpty {
                    errors.append("旧书源 JSON 缺少发现规则时还原失败")
                }
                if decoded.tocRule.startAtFirstChapter {
                    errors.append("旧目录规则被当成从第1章开始")
                }
            } catch {
                errors.append("旧书源 JSON 解码失败 \(error)")
            }
        }

        let exploreJSON = """
        {
          "bookSourceName": "发现测试",
          "bookSourceUrl": "https://explore.test",
          "exploreUrl": "玄幻::/xuanhuan/{{page}}.html\\n都市::/dushi/{{page}}.html",
          "ruleExplore": {"bookList": ".book", "name": "a@text", "bookUrl": "a@href"}
        }
        """
        do {
            let parsed = try BookSourceParser.parse(text: exploreJSON)
            if parsed.first?.exploreRule.listSelector != ".book" {
                errors.append("阅读发现选择器没有解析")
            }
            let found = ExploreURLParser.channels(from: parsed.first?.exploreRule.urlTemplate ?? "")
            if found.map(\.title) != ["玄幻", "都市"] {
                errors.append("阅读发现频道不符 \(found.map(\.title))")
            }
        } catch {
            errors.append("阅读发现 JSON 解析失败 \(error)")
        }

        let findJSON = """
        {
          "sourceName": "香色发现",
          "sourceUrl": "https://xiangse.test",
          "findBook": {
            "requestInfo": "言情::/yanqing/{{page}}.html",
            "list": "//li",
            "bookName": "//a/text()",
            "detailUrl": "//a/@href"
          }
        }
        """
        do {
            let parsed = try BookSourceParser.parse(text: findJSON)
            let rule = parsed.first?.exploreRule
            if rule?.listSelector != "//li" || rule?.urlTemplate.contains("https://xiangse.test/yanqing/") != true {
                errors.append("香色发现规则不符 \(rule?.urlTemplate ?? "nil")")
            }
        } catch {
            errors.append("香色发现 JSON 解析失败 \(error)")
        }

        if let penguin = sites.first(where: { $0.id == "site-penguin" }) {
            if !penguin.source.sourceURL.contains("qiexs.cc") {
                errors.append("企鹅小说仍指向 \(penguin.source.sourceURL)")
            }
            let home = """
            <ul class="list-group list-top">
              <li class="list-group-item">
                <a href="https://www.qiexs.cc/xiaoshuo/7399.html" title="江边柔风起">江边柔风起</a>
                <small class="text-muted">/ 暮二十九</small>
              </li>
            </ul>
            """
            let homeBooks = books(in: home, rule: penguin.source.exploreRule)
            if homeBooks.first?.title != "江边柔风起" || homeBooks.first?.author != "暮二十九" {
                errors.append("企鹅小说首页没有解析出排行 \(homeBooks)")
            }
            let category = """
            <table class="mytable table">
              <tr><th>书名</th><th>作者</th></tr>
              <tr>
                <td><a href="https://www.qiexs.cc/xiaoshuo/21094.html" title="边关第一猎户">边关第一猎户</a></td>
                <td class="hidden-xs"><a class="text-muted" href="https://www.qiexs.cc/xiaoshuo/21094/1.html">第1章</a></td>
                <td class="text-muted">柳白飞</td>
                <td class="text-nowrap">连载</td>
              </tr>
            </table>
            """
            let categoryBooks = books(in: category, rule: penguin.source.exploreRule)
            if categoryBooks.first?.title != "边关第一猎户" || categoryBooks.first?.author != "柳白飞" {
                errors.append("企鹅小说分类页没有解析出表格 \(categoryBooks)")
            }
            let searchCard = """
            <div class="col-md-10">
              <h4 class="bookTitle"><a href="https://www.qiexs.cc/xiaoshuo/948.html"><em>斗破</em>之无上之境</a></h4>
              <p class="booktag"><a class="red" href="https://www.qiexs.cc/author/1741.html">夜雨闻铃0</a></p>
            </div>
            """
            let searched = books(in: searchCard, rule: penguin.source.searchRule)
            if searched.first?.author != "夜雨闻铃0" || searched.first?.title.contains("斗破") != true {
                errors.append("企鹅小说搜索结果没有解析 \(searched)")
            }
        } else {
            errors.append("切换列表缺少企鹅小说")
        }

        let shubaChannels = ExploreURLParser.channels(from: shuba.source.exploreRule.urlTemplate)
        if shubaChannels.first?.title != "全部分类" || shubaChannels.contains(where: { $0.urlTemplate.contains("/novels/class/1.htm") }) != true {
            errors.append("69书吧发现频道不符 \(shubaChannels.map(\.title))")
        }
        let shubaHTML = """
        <div id="article_list_content">
          <ul>
            <li>
              <h3><a href="/class/1.htm">玄幻</a><a href="/book/1.htm">灯塔传说</a></h3>
              <label>守塔人</label>
              <p class="ellipsis_2">海岸上的灯</p>
            </li>
          </ul>
        </div>
        """
        let shubaBooks = books(in: shubaHTML, rule: shuba.source.exploreRule)
        if shubaBooks.first?.title != "灯塔传说" || shubaBooks.first?.author != "守塔人" {
            errors.append("69书吧分类页没有解析出书籍 \(shubaBooks)")
        }

        let feiluChannels = ExploreURLParser.channels(from: feilu.source.exploreRule.urlTemplate)
        if !feilu.source.sourceURL.contains("wap.faloo.com")
            || feiluChannels.contains(where: { $0.urlTemplate.contains("y_4_14_0_0_0_0.html") }) != true {
            errors.append("飞卢发现地址不符 \(feilu.source.sourceURL)")
        }
        let falooHome = """
        <li><a href="//wap.faloo.com/1547460.html" title="四合院：李云龙是我大哥"><div class="novelName">四合院：李云龙是我大哥</div></a></li>
        """
        let falooBooks = books(in: falooHome, rule: feilu.source.exploreRule)
        if falooBooks.first?.title != "四合院：李云龙是我大哥" || falooBooks.first?.author != "" {
            errors.append("飞卢首页没有解析出书卡 \(falooBooks)")
        }
        let falooCategory = """
        <div class="nl_r1">
          <div class="bl_r1_tit"><a href="//wap.faloo.com/1406705.html">四合院：从民国开始起飞</a></div>
          <div class="nl_r1_author"><a href="//wap.faloo.com/author">计算机</a><a href="//wap.faloo.com/y_4_14_0_0_0_0.html">都市生活</a></div>
        </div>
        """
        let falooCategoryBooks = books(in: falooCategory, rule: feilu.source.exploreRule)
        if falooCategoryBooks.first?.title != "四合院：从民国开始起飞" || falooCategoryBooks.first?.author != "计算机" {
            errors.append("飞卢分类页没有解析出书籍 \(falooCategoryBooks)")
        }

        guard let wucuo = sites.first(where: { $0.id == "preset-wucuo" }),
              let jiujiu = sites.first(where: { $0.id == "site-jiujiu" }),
              let zongheng = sites.first(where: { $0.id == "site-zongheng" }),
              let shuqi = sites.first(where: { $0.id == "site-shuqi" }) else {
            errors.append("切换列表缺少无错、久久、纵横或书旗")
            return
        }
        if !wucuo.source.sourceURL.contains("m.wucuoxs.com")
            || !wucuo.source.exploreRule.urlTemplate.contains("/sort-1-1/") {
            errors.append("无错小说仍指向 \(wucuo.source.sourceURL)")
        }
        let wucuoHTML = """
        <article>
          <a href="/wcxs-26874/"><div class="info"><h2 class="title">江左伪郎</h2><p>作者：历史系之狼</p><p class="intro">简介：衣冠南渡</p></div></a>
        </article>
        """
        let wucuoBooks = books(in: wucuoHTML, rule: wucuo.source.exploreRule)
        if wucuoBooks.first?.title != "江左伪郎" || wucuoBooks.first?.author != "历史系之狼" {
            errors.append("无错小说没有解析出书籍 \(wucuoBooks)")
        }
        if !jiujiu.source.sourceURL.contains("ijjxsxzw.com")
            || !jiujiu.source.exploreRule.urlTemplate.contains("/txt/chuanyue/") {
            errors.append("久久小说仍指向 \(jiujiu.source.sourceURL)")
        }
        let jiujiuHome = """
        <span class="line-main"><span class="cat">穿越</span><a href="/txt/57617.html">清澈女大的六零年代</a><span class="author">九紫</span></span>
        """
        let jiujiuBooks = books(in: jiujiuHome, rule: jiujiu.source.exploreRule)
        if jiujiuBooks.first?.title != "清澈女大的六零年代" || jiujiuBooks.first?.author != "九紫" {
            errors.append("久久首页没有解析出书籍 \(jiujiuBooks)")
        }
        let jiujiuCategory = """
        <div class="listbg">
          <a class="img" href="/txt/57617.html"></a>
          <span class="title"><a href="/txt/57617.html">清澈女大的六零年代</a></span>
          <span class="mainGreen"><a href="/zuozhe/1101.html">九紫</a></span>
        </div>
        """
        let jiujiuCategoryBooks = books(in: jiujiuCategory, rule: jiujiu.source.exploreRule)
        if jiujiuCategoryBooks.first?.title != "清澈女大的六零年代" || jiujiuCategoryBooks.first?.author != "九紫" {
            errors.append("久久分类页没有解析出书籍 \(jiujiuCategoryBooks)")
        }
        let jiujiuSearch = """
        <div class="searchTopic">1 、<a href="/txt/57617.html" class="searchtitle"><mark>清澈</mark>女大的六零年代</a> 作者：九紫</div>
        """
        let jiujiuSearched = books(in: jiujiuSearch, rule: jiujiu.source.searchRule)
        if jiujiuSearched.first?.title.contains("女大的六零年代") != true || jiujiuSearched.first?.author != "九紫" {
            errors.append("久久搜索没有解析出书籍 \(jiujiuSearched)")
        }
        if !zongheng.source.exploreRule.urlTemplate.contains("cateFineId=8101") {
            errors.append("纵横发现地址不符 \(zongheng.source.exploreRule.urlTemplate)")
        }
        let zonghengHTML = """
        <div class="recommend-item">
          <a class="recommend-img--cover" href="//www.zongheng.com/detail/1327987" title="史上最强师父"></a>
          <div class="recommend-type"><a href="//home.zongheng.com/u">炒方便面</a><a href="//www.zongheng.com/categories?cateFineId=8101">玄幻奇幻</a></div>
        </div>
        <div class="zh-modules-rank-book">
          <p class="book-rank--title-text"><a href="//www.zongheng.com/detail/1610880">明君</a></p>
        </div>
        """
        let zonghengBooks = books(in: zonghengHTML, rule: zongheng.source.exploreRule)
        if zonghengBooks.first?.title != "史上最强师父" || zonghengBooks.first?.author != "炒方便面"
            || zonghengBooks.contains(where: { $0.title == "明君" }) != true {
            errors.append("纵横首页没有解析出书籍 \(zonghengBooks)")
        }
        if !shuqi.source.sourceURL.contains("t.shuqi.com") {
            errors.append("书旗仍指向 \(shuqi.source.sourceURL)")
        }
        let shuqiHTML = """
        <a class="item" href="/book/8229478.html"><p class="book-name">玄幻：从蛋开始无敌</p><p class="author-name">突兀</p></a>
        <a class="book-item-a" href="/book/6813921.html"><h3>鸿蒙道尊</h3><label>九支书竹</label></a>
        """
        let shuqiBooks = books(in: shuqiHTML, rule: shuqi.source.exploreRule)
        if shuqiBooks.first?.title != "玄幻：从蛋开始无敌" || shuqiBooks.first?.author != "突兀"
            || shuqiBooks.contains(where: { $0.title == "鸿蒙道尊" && $0.author == "九支书竹" }) != true {
            errors.append("书旗首页没有解析出书籍 \(shuqiBooks)")
        }

        if let bijian = sites.first(where: { $0.id == "preset-bijian" }) {
            let html = """
            <div class="l"><ul>
              <li><span class="s2"><a href="http://www.xbiquwk.com/0_580/">绝世唐门</a></span><span class="s4">唐家三少</span><span class="s5">10-09</span></li>
            </ul></div>
            """
            let parsed = books(in: html, rule: bijian.source.exploreRule)
            if parsed.first?.title != "绝世唐门" || parsed.first?.author != "唐家三少" {
                errors.append("笔尖中文没有解析出书籍 \(parsed)")
            }
        } else {
            errors.append("切换列表缺少笔尖中文")
        }
        if let b365 = sites.first(where: { $0.id == "preset-biqu365" }) {
            let html = """
            <ul class="gengxin"><li><span class="name"><a href="/book/21601/">军工科技</a></span></li></ul>
            """
            let parsed = books(in: html, rule: b365.source.exploreRule)
            if parsed.first?.title != "军工科技" {
                errors.append("笔趣阁365没有解析出书籍 \(parsed)")
            }
            let searched = books(in: """
            <ul class="search"><li class="fen"><span class="name">书名</span></li><li><span class="name"><a href="/book/007042/">军工：开局打造神级战机</a></span></li></ul>
            """, rule: b365.source.searchRule)
            if searched.first?.title != "军工：开局打造神级战机" {
                errors.append("笔趣阁365搜索没有解析出书籍 \(searched)")
            }
        } else {
            errors.append("切换列表缺少笔趣阁365")
        }
        if let quanben = sites.first(where: { $0.id == "preset-quanben5" }) {
            let html = """
            <div class="pic_txt_list"><h3><a href="/n/xinghedadi/"><span>星河大帝</span></a></h3><p class="info">作者: <span class="author">梦入神机</span></p></div>
            <ul class="list2"><li><a href="/n/jueshiwushen/">绝世武神</a></li></ul>
            """
            let parsed = books(in: html, rule: quanben.source.exploreRule)
            if parsed.contains(where: { $0.title == "星河大帝" && $0.author == "梦入神机" }) != true
                || parsed.contains(where: { $0.title == "绝世武神" }) != true {
                errors.append("全本小说网没有解析出书籍 \(parsed)")
            }
        } else {
            errors.append("切换列表缺少全本小说网")
        }
        if let yeudu = sites.first(where: { $0.id == "preset-yeudu" }) {
            let html = """
            <li class="recommend-item"><a class="ends" href="http://www.yeudusk.com/html/510/510881/">夜玄</a></li>
            <div class="c_subject"><a class="note" href="http://www.yeudusk.com/html/1440/1440726/">目录</a><a href="http://www.yeudusk.com/book/1440726/">妖女，快住口！</a></div>
            """
            let parsed = books(in: html, rule: yeudu.source.exploreRule)
            if parsed.first?.title != "夜玄"
                || parsed.contains(where: { $0.title == "妖女，快住口！" && $0.author == "" }) != true {
                errors.append("阅读库没有解析出书籍 \(parsed)")
            }
            if parsed.contains(where: { $0.title == "目录" }) {
                errors.append("阅读库把目录图标当成了书")
            }
        } else {
            errors.append("切换列表缺少阅读库")
        }
        if let ujxsw = sites.first(where: { $0.id == "preset-ujxsw" }) {
            let html = """
            <dl><dt><a href="http://www.ujxsw.org/book/1022/"><img alt="大奉打更人"></a></dt><dd><a href="http://www.ujxsw.org/book/1022/">大奉打更人</a></dd><dd class="tit">作者：卖报小郎君</dd></dl>
            """
            let parsed = books(in: html, rule: ujxsw.source.exploreRule)
            if parsed.first?.title != "大奉打更人" || parsed.first?.author != "卖报小郎君" {
                errors.append("悠久小说网没有解析出书籍 \(parsed)")
            }
        } else {
            errors.append("切换列表缺少悠久小说网")
        }
    }

    private static func books(in html: String, rule: SourceExploreRule) -> [(title: String, author: String)] {
        books(
            in: html,
            list: rule.listSelector,
            name: rule.nameSelector,
            author: rule.authorSelector,
            detail: rule.detailURLSelector
        )
    }

    private static func books(in html: String, rule: SourceSearchRule) -> [(title: String, author: String)] {
        books(
            in: html,
            list: rule.listSelector,
            name: rule.nameSelector,
            author: rule.authorSelector,
            detail: rule.detailURLSelector
        )
    }

    private static func books(
        in html: String,
        list: String,
        name: String,
        author: String,
        detail: String
    ) -> [(title: String, author: String)] {
        let root = HTMLMiniParser.parse(html)
        return HTMLMiniParser.queryNodes(root: root, rule: list).compactMap { node in
            let title = HTMLMiniParser.queryStrings(root: node, rule: name).first ?? ""
            let author = HTMLMiniParser.queryStrings(root: node, rule: author).first ?? ""
            let href = node.nearestHref(preferred: HTMLMiniParser.queryStrings(root: node, rule: detail).first) ?? ""
            guard !title.isEmpty, !href.isEmpty else { return nil }
            return (title, author)
        }
    }

    private nonisolated static func probeRuleCatalog() async throws -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let searchHTML = """
        <div class="search-list">
          <div class="item">
            <div class="title"><a href="/novel/99">灯塔传说</a></div>
            <span class="author">守塔人</span>
            <p class="desc">关于灯塔的故事</p>
          </div>
        </div>
        """
        let detailHTML = """
        <h1>灯塔传说</h1>
        <span class="author">守塔人</span>
        <div class="chapters">
          <a href="/novel/99/c1">第一章 晨曦</a>
          <a href="/novel/99/c2">第二章 黄昏</a>
        </div>
        """
        let c1HTML = """
        <div id="content">清晨的雾气笼罩着海岸。##广告:请勿相信##</div>
        """
        let c2HTML = """
        <div id="content">落日把海面染成了金色。</div>
        """

        CatalogURLStub.setRoutes([
            "/search": (200, Data(searchHTML.utf8)),
            "/explore/21/1.html": (200, Data(searchHTML.utf8)),
            "/novel/99": (200, Data(detailHTML.utf8)),
            "/novel/99/c1": (200, Data(c1HTML.utf8)),
            "/novel/99/c2": (200, Data(c2HTML.utf8))
        ])

        let source = UniversalBookSource(
            kind: .legado,
            name: "测试规则源",
            sourceURL: "https://catalog.test",
            searchRule: SourceSearchRule(
                urlTemplate: "https://catalog.test/search?keyword={{key}}",
                listSelector: ".search-list .item",
                nameSelector: ".title a@text",
                authorSelector: ".author@text",
                detailURLSelector: ".title a@href",
                summarySelector: ".desc@text"
            ),
            tocRule: SourceTocRule(
                listSelector: ".chapters a",
                nameSelector: "text",
                urlSelector: "href"
            ),
            contentRule: SourceContentRule(
                contentSelector: "#content@text",
                replaceRules: ["##广告.*?##"]
            ),
            exploreRule: SourceExploreRule(
                urlTemplate: "男频::https://catalog.test/explore/{{分类}}/{{page}}.html&&分类&&全部::-1&&玄幻::21",
                listSelector: ".search-list .item",
                nameSelector: ".title a@text",
                authorSelector: ".author@text",
                detailURLSelector: ".title a@href",
                summarySelector: ".desc@text"
            )
        )

        let catalog = RuleBasedBookCatalog(recordID: "test-rule-id", source: source, session: session)
        let found = try await catalog.search(query: "灯塔")
        guard found.count == 1, found[0].title == "灯塔传说", found[0].author == "守塔人" else {
            return false
        }

        let downloaded = try await catalog.fetchText(bookID: found[0].id, progress: nil)
        guard downloaded.title == "灯塔传说" else {
            return false
        }
        guard downloaded.text.contains("第一章 晨曦"), downloaded.text.contains("第二章 黄昏") else {
            return false
        }
        guard !downloaded.text.contains("广告") else {
            return false
        }

        let channels = ExploreURLParser.channels(from: source.exploreRule.urlTemplate)
        guard let channel = channels.first else { return false }
        let explored = try await catalog.explore(channelURL: channel.urlTemplate, selections: ["分类": "21"], page: 1)
        guard explored.count == 1, explored[0].title == "灯塔传说", explored[0].author == "守塔人" else {
            return false
        }

        return true
    }

    /// 详情页没有目录。目录在把 .htm 换成 / 的地址上，而且最新章节排在前面。
    private nonisolated static func probeShubaBook(recordID: String, source: UniversalBookSource) async throws -> String? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let detail = """
        <h1>灯塔传说</h1>
        <div class="booknav2"><a href="/author/1">守塔人</a></div>
        """
        let catalog = """
        <div id="catalog"><ul>
          <li data-num="2"><a href="/txt/88/2">第2章 黄昏</a></li>
          <li data-num="1"><a href="/txt/88/1">第1章 晨曦</a></li>
          <li data-num="0"><a href="/book/88.htm">灯塔传说目录</a></li>
        </ul></div>
        """
        let first = """
        <div class="txtnav">
          <h1>第1章 晨曦</h1>
          <div class="txtinfo">作者：守塔人</div>
          <div id="txtright">广告位</div>
          清晨的雾气笼罩着海岸。
          <br>69书吧 www.69shuba.com
        </div>
        """
        let second = """
        <div class="txtnav">
          <h1>第2章 黄昏</h1>
          <div class="txtinfo">作者：守塔人</div>
          落日把海面染成了金色。
        </div>
        """
        CatalogURLStub.setRoutes([
            "/book/88.htm": (200, Data(detail.utf8)),
            "/book/88": (200, Data(catalog.utf8)),
            "/txt/88/1": (200, Data(first.utf8)),
            "/txt/88/2": (200, Data(second.utf8))
        ])
        let downloader = RuleBasedBookCatalog(recordID: recordID, source: source, session: session)
        let fetched = try await downloader.fetchText(bookID: "https://www.69shuba.com/book/88.htm", progress: nil)
        if fetched.title != "灯塔传说" {
            return "69书吧书名不符 \(fetched.title)"
        }
        guard let dawn = fetched.text.range(of: "第1章 晨曦"),
              let dusk = fetched.text.range(of: "第2章 黄昏"),
              dawn.lowerBound < dusk.lowerBound else {
            return "69书吧章节顺序不符"
        }
        if !fetched.text.contains("清晨的雾气笼罩着海岸。") || !fetched.text.contains("落日把海面染成了金色。") {
            return "69书吧没有抓到正文"
        }
        if fetched.text.contains("广告位") || fetched.text.contains("69书吧") || fetched.text.contains("灯塔传说目录") {
            return "69书吧正文混进了广告或目录链接"
        }
        let opening = try await downloader.fetchOpening(bookID: "https://www.69shuba.com/book/88.htm")
        if opening.chapters.count != 2 {
            return "69书吧目录章数不符 \(opening.chapters.count)"
        }
        if !opening.text.contains("清晨的雾气笼罩着海岸。") || opening.text.contains("落日把海面染成了金色。") {
            return "点开 69书吧应当只带第一章"
        }
        let next = try await downloader.fetchChapterText(url: opening.chapters[1].url)
        if !next.contains("落日把海面染成了金色。") || next.contains("清晨的雾气笼罩着海岸。") {
            return "69书吧下一章正文不符"
        }
        return nil
    }

    /// 详情页没有完整目录。目录在 div.gongneng 指向的 ul.info。正文用 br 分行，两页写在同一个 #txt 里。
    private nonisolated static func probeBiqu365Book(recordID: String, source: UniversalBookSource) async throws -> String? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let detail = """
        <h1>词条修仙</h1>
        <div class="gongneng">
          <span><a href="/newbook/082952/">全部章节目录</a></span>
          <span><a href="javascript:void(0)">加入书架</a></span>
        </div>
        <ul class="newchapter"><li><a href="/chapter/082952/2.html">第2章 后写的</a></li></ul>
        """
        let catalog = """
        <ul class="info">
          <li><a href="/chapter/082952/1.html">第1章 开局</a></li>
          <li><a href="/chapter/082952/2.html">第2章 后写的</a></li>
        </ul>
        """
        let first = """
        <div id="txt" class="txt">
          <p style="font-weight:bold";>一秒记住【笔趣阁】biquge365.net，更新快，无弹窗！</p><br>
          &nbsp;&nbsp;&nbsp;&nbsp;第1章 开局(第1/2页)<br/>
          &nbsp;&nbsp;&nbsp;&nbsp;开局只有一条大裤衩。<br/>
          &nbsp;&nbsp;&nbsp;&nbsp;（本章未完，请点击下一页继续阅读）第1章 开局(第2/2页)<br/>
          &nbsp;&nbsp;&nbsp;&nbsp;海风灌进裤管。<br/>
        </div>
        """
        let second = """
        <div id="txt"><p>一秒记住【笔趣阁】biquge365.net，更新快，无弹窗！</p><br>&nbsp;&nbsp;&nbsp;&nbsp;灯塔还亮着。</div>
        """
        CatalogURLStub.setRoutes([
            "/book/082952": (200, Data(detail.utf8)),
            "/book/082952/": (200, Data(detail.utf8)),
            "/newbook/082952": (200, Data(catalog.utf8)),
            "/newbook/082952/": (200, Data(catalog.utf8)),
            "/chapter/082952/1.html": (200, Data(first.utf8)),
            "/chapter/082952/2.html": (200, Data(second.utf8))
        ])
        let downloader = RuleBasedBookCatalog(recordID: recordID, source: source, session: session)
        let opening = try await downloader.fetchOpening(bookID: "https://www.biquge365.net/book/082952/")
        if opening.title != "词条修仙" {
            return "笔趣阁365书名不符 \(opening.title)"
        }
        if opening.chapters.count != 2 || opening.chapters.first?.title != "第1章 开局" {
            return "笔趣阁365目录不符 \(opening.chapters.map(\.title))"
        }
        guard let pants = opening.text.range(of: "开局只有一条大裤衩。"),
              let wind = opening.text.range(of: "海风灌进裤管。"),
              pants.upperBound < wind.lowerBound else {
            return "笔趣阁365两页顺序不符 \(opening.text)"
        }
        if opening.text.contains("开局只有一条大裤衩。 海风灌进裤管。") {
            return "笔趣阁365正文被连成一段 \(opening.text)"
        }
        if opening.text.contains("笔趣阁") || opening.text.contains("本章未完") || opening.text.contains("第1/2页") || opening.text.contains("第2/2页") {
            return "笔趣阁365正文混进了水印或分页 \(opening.text)"
        }
        if opening.text.contains("灯塔还亮着") {
            return "点开笔趣阁365应当只带第一章"
        }
        let next = try await downloader.fetchChapterText(url: opening.chapters[1].url)
        if !next.contains("灯塔还亮着。") || next.contains("笔趣阁") || next.contains("大裤衩") {
            return "笔趣阁365下一章正文不符 \(next)"
        }
        return nil
    }

    /// 横幅在前、第1章在后时，打开的是第1章，横幅里多出来的章补到目录末尾。没开这个开关时仍按页面顺序。
    private nonisolated static func probeOpeningChapterOrder() async throws -> String? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let detail = """
        <h1>横幅测试</h1>
        <div id="list">
          <dd><a href="/banner/3.html">第3章 只在横幅</a></dd>
          <dd><a href="/banner/1.html">第 1 章 开端</a></dd>
          <dd><a href="/banner/2.html">第2章 接着</a></dd>
        </div>
        """
        let first = "<div id=\"content\">开端写在第一章。</div>"
        let second = "<div id=\"content\">接着写下去。</div>"
        let third = "<div id=\"content\">横幅里的句子。</div>"
        CatalogURLStub.setRoutes([
            "/bannerbook/9": (200, Data(detail.utf8)),
            "/banner/1.html": (200, Data(first.utf8)),
            "/banner/2.html": (200, Data(second.utf8)),
            "/banner/3.html": (200, Data(third.utf8))
        ])

        func source(startsAtFirst: Bool) -> UniversalBookSource {
            UniversalBookSource(
                kind: .legado,
                name: "横幅目录",
                sourceURL: "https://banner.test",
                searchRule: SourceSearchRule(urlTemplate: "https://banner.test/?keyword={{key}}"),
                tocRule: SourceTocRule(
                    listSelector: "#list a",
                    nameSelector: "text",
                    urlSelector: "href",
                    startAtFirstChapter: startsAtFirst
                ),
                contentRule: SourceContentRule(contentSelector: "#content@text")
            )
        }

        let ordered = RuleBasedBookCatalog(recordID: "banner-order", source: source(startsAtFirst: true), session: session)
        let opening = try await ordered.fetchOpening(bookID: "https://banner.test/bannerbook/9")
        if opening.chapters.count != 3
            || opening.chapters[0].title != "第 1 章 开端"
            || opening.chapters[2].title != "第3章 只在横幅" {
            return "横幅目录没有从第1章排到补上的末章 \(opening.chapters.map(\.title))"
        }
        if !opening.text.contains("开端写在第一章。") || opening.text.contains("横幅里的句子") {
            return "横幅目录打开的不是第一章 \(opening.text)"
        }
        let kept = RuleBasedBookCatalog(recordID: "banner-keep", source: source(startsAtFirst: false), session: session)
        let original = try await kept.fetchOpening(bookID: "https://banner.test/bannerbook/9")
        if original.chapters.first?.title != "第3章 只在横幅" || !original.text.contains("横幅里的句子") {
            return "没开从第1章开始时目录被改写了 \(original.chapters.map(\.title))"
        }
        return nil
    }

    private nonisolated struct SourceProbe: Sendable {
        var sampleTitle = ""
        var sampleAuthor = ""
        var sampleID = ""
        var sampleMissed = false
        var sampleMissing = false
        var sampleFetchedTitle = ""
        var sampleText = ""
        var remoteTitle = ""
        var remoteID = ""
        var remoteFetchedTitle = ""
        var remoteText = ""
        var openingText = ""
        var openingCount = 0
        var openingNext = ""
        var marks: [String] = []
        var missingIsNotFound = false
        var badJSON = false
    }

    private nonisolated static func probeCatalogs() async throws -> SourceProbe {
        var probe = SourceProbe()
        let sample = SampleBookCatalog()
        let found = try await sample.search(query: "灯塔")
        probe.sampleTitle = found.first?.title ?? ""
        probe.sampleAuthor = found.first?.author ?? ""
        probe.sampleID = found.first?.id ?? ""
        probe.sampleMissed = try await sample.search(query: "没有这本书xyz").isEmpty
        let fetched = try await sample.fetchText(bookID: "lighthouse", progress: nil)
        probe.sampleFetchedTitle = fetched.title
        probe.sampleText = fetched.text
        do {
            _ = try await sample.fetchText(bookID: "missing", progress: nil)
        } catch let error as SourceError {
            if case .notFound = error { probe.sampleMissing = true }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let root = URL(string: "https://catalog.test/v1")!
        CatalogURLStub.setRoutes([
            "/v1/search": (200, Data(#"{"books":[{"id":"demo","title":"海岸来信","author":"林书","summary":"一封没有地址的信"}]}"#.utf8)),
            "/v1/books/demo": (200, Data(#"{"id":"demo","title":"海岸来信","author":"林书","summary":"一封没有地址的信","chapters":[{"id":"c1","title":"第一章 来信"},{"id":"c2","title":"第二章 回信"}]}"#.utf8)),
            "/v1/books/demo/chapters/c1": (200, Data(#"{"id":"c1","title":"第一章 来信","content":"信封是湿的。"}"#.utf8)),
            "/v1/books/demo/chapters/c2": (200, Data(#"{"id":"c2","title":"第二章 回信","content":"灯塔亮了一夜。"}"#.utf8))
        ])
        let remote = RemoteBookCatalog(id: "test", name: "测试", baseURL: root, session: session)
        let remoteFound = try await remote.search(query: "海岸")
        probe.remoteTitle = remoteFound.first?.title ?? ""
        probe.remoteID = remoteFound.first?.id ?? ""
        let opening = try await remote.fetchOpening(bookID: "demo")
        probe.openingText = opening.text
        probe.openingCount = opening.chapters.count
        if opening.chapters.count > 1 {
            probe.openingNext = try await remote.fetchChapterText(url: opening.chapters[1].url)
        }
        let marks = MarkList()
        let remoteText = try await remote.fetchText(bookID: "demo") { done, total in
            marks.values.append("\(done)/\(total)")
        }
        probe.marks = marks.values
        probe.remoteFetchedTitle = remoteText.title
        probe.remoteText = remoteText.text

        CatalogURLStub.setRoutes(["/v1/books/missing": (404, Data("{}".utf8))])
        do {
            _ = try await remote.fetchText(bookID: "missing", progress: nil)
        } catch let error as SourceError {
            if case .notFound = error { probe.missingIsNotFound = true }
        }

        CatalogURLStub.setRoutes(["/v1/search": (200, Data("nope".utf8))])
        do {
            _ = try await remote.search(query: "海岸")
        } catch let error as SourceError {
            if case .badResponse = error { probe.badJSON = true }
        }
        return probe
    }

    private nonisolated final class MarkList: @unchecked Sendable {
        var values: [String] = []
    }

    private struct ProbeFailure: Error, CustomStringConvertible {
        var description: String
    }

    private nonisolated final class StoredResultBox<T: Sendable>: @unchecked Sendable {
        var value: T?
        var failure: String?
    }

    private static func finishAsync<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) -> Result<T, ProbeFailure> {
        let box = StoredResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                box.value = try await body()
            } catch {
                box.failure = String(describing: error)
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 8) != .success {
            return .failure(ProbeFailure(description: "超时"))
        }
        if let value = box.value {
            return .success(value)
        }
        return .failure(ProbeFailure(description: box.failure ?? "没有结果"))
    }

    private static func checkEpub(_ errors: inout [String]) {
        let marked = ChapterSplitter.forcedHeadingPrefix + "Chapter 9: The long road goes on past the gate"
        if !ChapterSplitter.isHeading(marked)
            || ChapterSplitter.displayTitle(marked) != "Chapter 9: The long road goes on past the gate" {
            errors.append("EPUB 强制标题没有被识别")
        }
        if ChapterSplitter.isHeading("Chapter 9: The long road goes on past the gate") {
            errors.append("带标点的长标题不该被普通规则认成章节")
        }
        do {
            let book = try EpubParser.parse(sampleEpub())
            if book.title != "豆豆 EPUB" || book.author != "测试作者" {
                errors.append("EPUB 书名或作者不符 \(book.title) / \(book.author)")
            }
            if book.text.contains("封面不要进来") {
                errors.append("EPUB 把非正文封面读进来了")
            }
            let slices = ChapterSplitter.split(book.text, fallbackTitle: book.title)
            let titles = slices.map(\.title)
            if titles != ["第一章 雨", "终章：风", "序章", "Chapter 3: End"] {
                errors.append("EPUB 章节不符 \(titles)")
            }
            for needle in ["正文甲，下了雨。", "第二段。", "正文乙，起了风。", "序的正文。", "结尾。"] where !book.text.contains(needle) {
                errors.append("EPUB 正文缺少 \(needle)")
            }
            if let wind = slices.first(where: { $0.title == "终章：风" }) {
                let body = ChapterSplitter.substring(book.text, start: wind.bodyStart, end: wind.bodyEnd)
                if body.contains("终章") {
                    errors.append("EPUB 章节正文重复了标题")
                }
            }
        } catch {
            errors.append("EPUB 解析失败 \((error as? LocalizedError)?.errorDescription ?? String(describing: error))")
        }

        do {
            let headed = try EpubParser.parse(headingEpub())
            let titles = ChapterSplitter.split(headed.text, fallbackTitle: headed.title).map(\.title)
            if titles != ["Chapter 1: Rain", "Chapter 2: Wind"]
                || !headed.text.contains("甲的正文")
                || !headed.text.contains("乙的正文") {
                errors.append("同一文件里的标题没有拆成章节 \(titles)")
            }
        } catch {
            errors.append("标题拆章失败 \((error as? LocalizedError)?.errorDescription ?? String(describing: error))")
        }

        do {
            let legacy = try EpubParser.parse(ncxEpub())
            let titles = ChapterSplitter.split(legacy.text, fallbackTitle: legacy.title).map(\.title)
            if legacy.title != "旧书" || titles != ["楔子"] || !legacy.text.contains("旧目录正文") {
                errors.append("NCX 目录没有成为章节 \(titles)")
            }
        } catch {
            errors.append("NCX EPUB 解析失败 \((error as? LocalizedError)?.errorDescription ?? String(describing: error))")
        }

        do {
            let archive = try ZipArchive.open(deflateZip())
            let hello = try archive.file("hello.txt")
            let blob = try archive.file("blob.txt")
            let expectedBlob = Data(String(repeating: "甲乙丙丁戊己庚辛。", count: 300).utf8)
            if hello != Data("你好，章节。".utf8) || blob != expectedBlob {
                errors.append("EPUB 的 deflate 没有解开")
            }
        } catch {
            errors.append("deflate 解压失败 \(error)")
        }

        do {
            _ = try EpubParser.parse(Data("不是电子书".utf8))
            errors.append("坏 EPUB 应当失败")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            if message != "这本 EPUB 打不开" {
                errors.append("坏 EPUB 的提示不符 \(message)")
            }
        }

        do {
            _ = try EpubParser.parse(encryptedEpub())
            errors.append("加密 EPUB 应当失败")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            if message != "这本 EPUB 加了密，打不开" {
                errors.append("加密 EPUB 的提示不符 \(message)")
            }
        }
    }

    private static func sampleEpub() -> Data {
        let container = """
        <?xml version="1.0" encoding="utf-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/book.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        let opf = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0">
          <metadata>
            <dc:title>豆豆 EPUB</dc:title>
            <dc:creator opf:role="aut">测试作者</dc:creator>
            <dc:language>zh-CN</dc:language>
          </metadata>
          <manifest>
            <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>
            <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/>
            <item id="split" href="split.xhtml" media-type="application/xhtml+xml"/>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
          </manifest>
          <spine>
            <itemref idref="cover" linear="no"/>
            <itemref idref="c1"/>
            <itemref idref="c2"/>
            <itemref idref="split"/>
          </spine>
        </package>
        """
        let cover = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>封面不要进来</p></body></html>"
        let c1 = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>第一章 雨</title></head><body><h1>第一章 雨</h1><p>正文甲，下了雨。</p><p>第二段。</p></body></html>"
        let c2 = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><h1>终章：风</h1><p>正文乙，起了风。</p></body></html>"
        let split = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><section id=\"a\"><h2>序章</h2><p>序的正文。</p></section><section id=\"b\"><h2>Chapter 3: End</h2><p>结尾。</p></section></body></html>"
        let nav = """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <body><nav epub:type="toc"><ol>
            <li><a href="c1.xhtml">第一章 雨</a></li>
            <li><a href="c2.xhtml">终章：风</a></li>
            <li><a href="split.xhtml#a">序章</a></li>
            <li><a href="split.xhtml#b">Chapter 3: End</a></li>
          </ol></nav></body>
        </html>
        """
        return zipParts([
            ZipPart(name: "mimetype", plain: Data("application/epub+zip".utf8)),
            ZipPart(name: "META-INF/container.xml", plain: Data(container.utf8)),
            ZipPart(name: "OEBPS/book.opf", plain: Data(opf.utf8)),
            ZipPart(name: "OEBPS/cover.xhtml", plain: Data(cover.utf8)),
            ZipPart(name: "OEBPS/c1.xhtml", plain: Data(c1.utf8)),
            ZipPart(name: "OEBPS/c2.xhtml", plain: Data(c2.utf8), compressed: hexBytes("b3b1afc8cd51284b2d2acecccfb35532d433505248cd4bce4fc9cc4bb7552a2d49d3b550b2b7e3b2c928012a032acd2bb655ca282929b0d2d72f2f2fd72b37d6cb2f4ad737b4b4b4d4af00a951b2b349ca4fa9b4b3c930b47bbebbe3f9ea05eff7cc7ab9b8cf461f28605360f76cede267d3da9fec9cf97e4fcf8baddb9fec6a034a3e6e68b2d12fb0b3d18768d50719640700")),
            ZipPart(name: "OEBPS/split.xhtml", plain: Data(split.utf8)),
            ZipPart(name: "OEBPS/nav.xhtml", plain: Data(nav.utf8)),
        ])
    }

    private static func headingEpub() -> Data {
        let container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let opf = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0">
          <metadata><dc:title>标题拆章</dc:title><dc:creator>豆豆</dc:creator></metadata>
          <manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="c"/></spine>
        </package>
        """
        let chapter = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><h1>Chapter 1: Rain</h1><p>甲的正文。</p><h1>Chapter 2: Wind</h1><p>乙的正文。</p></body></html>"
        return zipParts([
            ZipPart(name: "mimetype", plain: Data("application/epub+zip".utf8)),
            ZipPart(name: "META-INF/container.xml", plain: Data(container.utf8)),
            ZipPart(name: "book.opf", plain: Data(opf.utf8)),
            ZipPart(name: "c.xhtml", plain: Data(chapter.utf8)),
        ])
    }

    private static func ncxEpub() -> Data {
        let container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let opf = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0">
          <metadata><dc:title>旧书</dc:title><dc:creator>旧作者</dc:creator></metadata>
          <manifest>
            <item id="c" href="c.xhtml" media-type="application/xhtml+xml"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
          </manifest>
          <spine toc="ncx"><itemref idref="c"/></spine>
        </package>
        """
        let chapter = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>旧目录正文。</p></body></html>"
        let ncx = """
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/">
          <navMap>
            <navPoint id="n1" playOrder="1">
              <navLabel><text>楔子</text></navLabel>
              <content src="c.xhtml"/>
            </navPoint>
          </navMap>
        </ncx>
        """
        return zipParts([
            ZipPart(name: "mimetype", plain: Data("application/epub+zip".utf8)),
            ZipPart(name: "META-INF/container.xml", plain: Data(container.utf8)),
            ZipPart(name: "book.opf", plain: Data(opf.utf8)),
            ZipPart(name: "c.xhtml", plain: Data(chapter.utf8)),
            ZipPart(name: "toc.ncx", plain: Data(ncx.utf8)),
        ])
    }

    private static func encryptedEpub() -> Data {
        let container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let opf = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0">
          <metadata><dc:title>密文</dc:title></metadata>
          <manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="c"/></spine>
        </package>
        """
        return zipParts([
            ZipPart(name: "mimetype", plain: Data("application/epub+zip".utf8)),
            ZipPart(name: "META-INF/container.xml", plain: Data(container.utf8)),
            ZipPart(name: "book.opf", plain: Data(opf.utf8)),
            ZipPart(name: "c.xhtml", plain: Data("<p>秘密</p>".utf8), encrypted: true),
        ])
    }

    private static func deflateZip() -> Data {
        zipParts([
            ZipPart(
                name: "hello.txt",
                plain: Data("你好，章节。".utf8),
                compressed: hexBytes("7bb277c1d3a57bdfefe979be7ac18baea6c70d4d00")
            ),
            ZipPart(
                name: "blob.txt",
                plain: Data(String(repeating: "甲乙丙丁戊己庚辛。", count: 300).utf8),
                compressed: hexBytes("edc9b91140400000c0d69dc88825a882e48e4033ee510645087766b36dd39e8f39a74fa8c358e256cee5b9d6bbeb9b524a29a594524a29a594524a29a594524a29a5feab17")
            ),
        ])
    }

    private struct ZipPart {
        var name: String
        var plain: Data
        var compressed: Data? = nil
        var encrypted: Bool = false
    }

    private static func zipParts(_ parts: [ZipPart]) -> Data {
        var local = Data()
        var central = Data()
        for part in parts {
            let name = Data(part.name.utf8)
            let payload = part.compressed ?? part.plain
            let method: UInt16 = part.compressed == nil ? 0 : 8
            var flags: UInt16 = 1 << 11
            if part.encrypted { flags |= 1 }
            let offset = UInt32(local.count)
            append32(0x04034B50, to: &local)
            append16(20, to: &local)
            append16(flags, to: &local)
            append16(method, to: &local)
            append16(0, to: &local)
            append16(0, to: &local)
            append32(zipCRC(part.plain), to: &local)
            append32(UInt32(payload.count), to: &local)
            append32(UInt32(part.plain.count), to: &local)
            append16(UInt16(name.count), to: &local)
            append16(0, to: &local)
            local.append(name)
            local.append(payload)

            append32(0x02014B50, to: &central)
            append16(20, to: &central)
            append16(20, to: &central)
            append16(flags, to: &central)
            append16(method, to: &central)
            append16(0, to: &central)
            append16(0, to: &central)
            append32(zipCRC(part.plain), to: &central)
            append32(UInt32(payload.count), to: &central)
            append32(UInt32(part.plain.count), to: &central)
            append16(UInt16(name.count), to: &central)
            append16(0, to: &central)
            append16(0, to: &central)
            append16(0, to: &central)
            append16(0, to: &central)
            append32(0, to: &central)
            append32(offset, to: &central)
            central.append(name)
        }
        let directoryOffset = UInt32(local.count)
        var archive = local
        archive.append(central)
        append32(0x06054B50, to: &archive)
        append16(0, to: &archive)
        append16(0, to: &archive)
        append16(UInt16(parts.count), to: &archive)
        append16(UInt16(parts.count), to: &archive)
        append32(UInt32(central.count), to: &archive)
        append32(directoryOffset, to: &archive)
        append16(0, to: &archive)
        return archive
    }

    private static func zipCRC(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask: UInt32 = (crc & 1) == 1 ? 0xEDB8_8320 : 0
                crc = (crc >> 1) ^ mask
            }
        }
        return ~crc
    }

    private static func append16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8))
    }

    private static func append32(_ value: UInt32, to data: inout Data) {
        var remaining = value
        for _ in 0..<4 {
            data.append(UInt8(remaining & 0xFF))
            remaining >>= 8
        }
    }

    private static func checkBookSearch(_ errors: inout [String]) {
        if BookSearch.shelfHit(title: "灯塔邮局", author: "豆豆", query: "  ") {
            errors.append("空白关键词不该命中书架")
        }
        if !BookSearch.shelfHit(title: "灯塔邮局", author: "豆豆", query: "灯塔")
            || !BookSearch.shelfHit(title: "灯塔邮局", author: "豆豆", query: "豆") {
            errors.append("书架搜索没有命中书名或作者")
        }
        let suiteName = "doudou.search.logic.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            errors.append("搜索历史无法建立测试存储")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var history = BookSearchHistory.remember(" 灯塔 ", defaults: defaults)
        history = BookSearchHistory.remember("完美世界", defaults: defaults)
        history = BookSearchHistory.remember("灯塔", defaults: defaults)
        if history != ["灯塔", "完美世界"] {
            errors.append("搜索历史没有去重或没有把最近的词放到前面 \(history)")
        }
        history = BookSearchHistory.remember("Light", defaults: defaults)
        history = BookSearchHistory.remember("light", defaults: defaults)
        if history.first != "light" || history.filter({ $0.caseInsensitiveCompare("light") == .orderedSame }).count != 1 {
            errors.append("搜索历史大小写没有合并 \(history)")
        }
        for index in 0..<14 {
            history = BookSearchHistory.remember("词\(index)", defaults: defaults)
        }
        if history.count != BookSearchHistory.limit || history.first != "词13" || history.contains("灯塔") {
            errors.append("搜索历史没有只保留最近 \(BookSearchHistory.limit) 条 \(history)")
        }
        BookSearchHistory.clear(defaults: defaults)
        if !BookSearchHistory.load(defaults: defaults).isEmpty {
            errors.append("清空搜索历史失败")
        }

        let kept = SourceSearchBatch(sourceID: "a", sourceName: "甲", phase: .books([
            CatalogBook(id: "1", title: "灯塔", author: "", summary: "")
        ]))
        let empty = SourceSearchBatch(sourceID: "b", sourceName: "乙", phase: .books([]))
        let waiting = SourceSearchBatch(sourceID: "c", sourceName: "丙", phase: .searching)
        let failed = SourceSearchBatch(sourceID: "d", sourceName: "丁", phase: .failed("超时"))
        let listed = BookSearch.listed([kept, empty, waiting, failed]).map(\.sourceID)
        if listed != ["a", "c", "d"] {
            errors.append("没有结果的书源仍留在切换条上 \(listed)")
        }

        let outcome = finishAsync { () -> [String] in
            let box = StoredResultBox<[String]>()
            box.value = []
            await BookSearch.run(
                query: " 灯塔 ",
                sources: [
                    searchStub("fast", "快"),
                    searchStub("slow", "慢"),
                    searchStub("bad", "坏")
                ],
                concurrency: 2,
                timeout: .milliseconds(250),
                search: { source, query in
                    if source.id == "fast" {
                        if query != "灯塔" { throw SourceError.badResponse }
                        return [CatalogBook(id: "1", title: "灯塔邮局", author: "豆豆", summary: "")]
                    }
                    if source.id == "slow" {
                        try await Task.sleep(for: .seconds(30))
                        return []
                    }
                    throw SourceError.unreachable
                },
                onUpdate: { batch in
                    let mark: String
                    switch batch.phase {
                    case .books(let books):
                        mark = books.map(\.title).joined(separator: ",")
                    case .failed(let message):
                        mark = "失败:" + message
                    case .searching:
                        mark = "搜索中"
                    }
                    box.value?.append(batch.sourceID + "=" + mark)
                }
            )
            return box.value ?? []
        }
        switch outcome {
        case .failure(let failure):
            errors.append("多书源搜索没有完成 \(failure)")
        case .success(let lines):
            let text = lines.sorted().joined(separator: "|")
            if text != "bad=失败:连不上这本书源|fast=灯塔邮局|slow=失败:超时" {
                errors.append("多书源搜索结果不对 \(text)")
            }
        }

        let cancelled = finishAsync { () -> String in
            let task = Task {
                await BookSearch.run(
                    query: "灯塔",
                    sources: [searchStub("slow", "慢")],
                    timeout: .seconds(30),
                    search: { _, _ in
                        try await Task.sleep(for: .seconds(30))
                        return []
                    },
                    onUpdate: { _ in }
                )
                return "结束"
            }
            task.cancel()
            return await task.value
        }
        if case .failure(let failure) = cancelled {
            errors.append("取消搜索没有停下来 \(failure)")
        }
    }

    private nonisolated static func searchStub(_ id: String, _ name: String) -> SwitchableSource {
        SwitchableSource(
            id: id,
            name: name,
            icon: "",
            note: "",
            group: "",
            host: "",
            source: UniversalBookSource(kind: .doudou, name: name, sourceURL: "https://example.com")
        )
    }

    private static func hexBytes(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            if let byte = UInt8(hex[index..<next], radix: 16) {
                data.append(byte)
            }
            index = next
        }
        return data
    }
}
