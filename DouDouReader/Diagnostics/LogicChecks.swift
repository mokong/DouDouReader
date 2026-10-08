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
        checkEncoding(&errors)
        checkAuthor(&errors)
        checkBlockWords(&errors)
        checkSample(&errors)
        checkConversion(&errors)
        checkSources(&errors)
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
            if !probe.missingIsNotFound || !probe.badJSON {
                errors.append("远端书源的错误结果不对")
            }
        }
        CatalogURLStub.setRoutes([:])
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
}
