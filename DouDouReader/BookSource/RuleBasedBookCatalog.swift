import Foundation

/// 基于规则（阅读 3.0 或香色闺阁）的通用书源目录执行器
nonisolated struct RuleBasedBookCatalog: IncrementalBookCatalog {
    var id: String
    var name: String
    var source: UniversalBookSource
    var session: URLSession

    /// 带 URLCache 与共享 Cookie 存储的默认会话，避免每次请求都新建连接、丢失会话 Cookie。
    nonisolated static let configuredSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 20 * 1024 * 1024, diskCapacity: 0)
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpShouldSetCookies = true
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config)
    }()

    init(recordID: String, source: UniversalBookSource, session: URLSession = RuleBasedBookCatalog.configuredSession) {
        self.id = recordID
        self.name = source.name
        self.source = source
        self.session = session
    }

    // MARK: - 搜索

    func search(query: String) async throws -> [CatalogBook] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        let (request, detectedCharset) = try buildSearchRequest(needle: needle)

        let (data, response) = try await loadData(request: request)
        let htmlOrJSON = decode(data, response: response, preferredCharset: detectedCharset)

        // 优先尝试作为 JSON 响应解析
        if let jsonBooks = tryParseJSONSearchResults(htmlOrJSON) {
            return jsonBooks
        }

        // 作为 HTML 响应解析
        guard let requestURL = request.url else {
            throw SourceError.badURL
        }
        return parseHTMLBooks(htmlOrJSON, baseURL: requestURL, selectors: searchFieldSelectors())
    }

    // MARK: - 发现

    /// 按当前频道和筛选抓取发现页。切换书源后必须走这本书源自己的发现地址。
    func explore(channelURL: String, selections: [String: String], page: Int) async throws -> [CatalogBook] {
        let substituted = ExploreURLParser.resolve(template: channelURL, selections: selections, page: page)
        guard let url = resolveURL(substituted, relativeTo: source.sourceURL) else {
            throw SourceError.badURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.httpMethod = "GET"
        applyBrowserHeaders(to: &request, baseURL: url)

        let (data, response) = try await loadData(request: request)
        let prefersGBK = source.rawJSON.lowercased().contains("gbk")
            || source.searchRule.urlTemplate.lowercased().contains("gbk")
        let text = decode(data, response: response, preferredCharset: prefersGBK ? "gbk" : nil)
        if let jsonBooks = tryParseJSONSearchResults(text) {
            return jsonBooks
        }
        return parseHTMLBooks(text, baseURL: url, selectors: exploreFieldSelectors())
    }

    // MARK: - 获取正文

    func fetchText(bookID: String, progress: (@Sendable (Int, Int) -> Void)?) async throws -> (title: String, text: String) {
        let prepared = try await prepare(bookID: bookID)
        let count = prepared.chapters.count
        // 约 4 路并发下载；字节累计用 actor 保证线程安全。
        let semaphore = DispatchSemaphore(value: 4)
        let counter = ByteCounter()
        let collected = try await withThrowingTaskGroup(of: (Int, String).self) { group -> [(Int, String)] in
            for (index, item) in prepared.chapters.enumerated() {
                group.addTask {
                    semaphore.wait()
                    defer { semaphore.signal() }
                    let content = try await downloadChapter(item.url)
                    try await counter.add(content.utf8.count)
                    return (index, content)
                }
            }
            var results: [(Int, String)] = []
            var done = 0
            for try await entry in group {
                results.append(entry)
                done += 1
                progress?(done, count)
            }
            return results
        }
        let ordered = collected.sorted { $0.0 < $1.0 }.map { (prepared.chapters[$0.0].title, $0.1) }
        let fullText = CatalogText.assemble(author: prepared.author, chapters: ordered)
        guard ordered.contains(where: { !$1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw SourceError.emptyBook
        }
        return (prepared.title, fullText)
    }

    func fetchOpening(bookID: String) async throws -> OnlineOpening {
        let prepared = try await prepare(bookID: bookID)
        guard let first = prepared.chapters.first else { throw SourceError.emptyBook }
        let body = try await downloadChapter(first.url)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourceError.emptyBook
        }
        let text = CatalogText.assemble(author: prepared.author, chapters: [(first.title, body)])
        let refs = prepared.chapters.map {
            RemoteChapterRef(title: $0.title, url: $0.url.absoluteString)
        }
        return OnlineOpening(
            title: prepared.title,
            author: prepared.author,
            text: text,
            chapters: refs,
            openingBody: body,
            coverURL: prepared.coverURL
        )
    }

    /// 书架检查更新用：只拉详情页和目录，不下任何章节正文。
    func fetchTOC(bookID: String) async throws -> OnlineTOC {
        let prepared = try await prepare(bookID: bookID)
        return OnlineTOC(
            title: prepared.title,
            author: prepared.author,
            chapters: prepared.chapters.map { RemoteChapterRef(title: $0.title, url: $0.url.absoluteString) },
            coverURL: prepared.coverURL
        )
    }

    func fetchChapterText(url: String) async throws -> String {
        guard let chapterURL = resolveURL(url, relativeTo: source.sourceURL) else {
            throw SourceError.badURL
        }
        let body = try await downloadChapter(chapterURL)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourceError.emptyBook
        }
        return body
    }

    private struct PreparedBook {
        var title: String
        var author: String
        var coverURL: String
        var chapters: [(title: String, url: URL)]
    }

    private func prepare(bookID: String) async throws -> PreparedBook {
        guard let bookURL = resolveURL(bookID, relativeTo: source.sourceURL) else {
            throw SourceError.badURL
        }

        var detailRequest = URLRequest(url: bookURL)
        detailRequest.timeoutInterval = 20
        applyBrowserHeaders(to: &detailRequest, baseURL: bookURL)

        let (detailData, detailResponse) = try await loadData(request: detailRequest)
        let detailHtml = decode(detailData, response: detailResponse)
        let detailRoot = HTMLMiniParser.parse(detailHtml)

        let titleRule = source.tocRule.infoNameSelector.isEmpty ? "//h1/text()" : source.tocRule.infoNameSelector
        let title = HTMLMiniParser.queryStrings(root: detailRoot, rule: titleRule).first
            ?? HTMLMiniParser.queryStrings(root: detailRoot, rule: "title").first
            ?? "未知书名"
        let authorRule = source.tocRule.infoAuthorSelector.isEmpty ? "//span[@class='author']/text()" : source.tocRule.infoAuthorSelector
        let author = HTMLMiniParser.queryStrings(root: detailRoot, rule: authorRule).first ?? ""
        let coverURL = extractDetailCoverURL(from: detailRoot, baseURL: bookURL)
        let chapters = try await loadChapterList(bookURL: bookURL, detailRoot: detailRoot)
        guard !chapters.isEmpty else { throw SourceError.emptyBook }
        return PreparedBook(title: title, author: author, coverURL: coverURL, chapters: chapters)
    }

    private func downloadChapter(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        applyBrowserHeaders(to: &request, baseURL: url)
        let data = try await loadData(request: request)
        let raw = decode(data.0, response: data.1)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 正文接口直接返回 JSON 时，按 $.a.b[0] 极简 JSONPath 取值。
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            let body = chapterBodyFromJSON(trimmed)
            if !body.isEmpty {
                return body
            }
        }
        let root = HTMLMiniParser.parse(raw)
        return chapterBody(from: root)
    }

    /// 从 JSON 正文响应中按 contentRule.contentSelector（如 $.chapter.content）提取正文。
    private func chapterBodyFromJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return "" }
        let selector = source.contentRule.contentSelector
        guard !selector.isEmpty, let value = navigateJSON(json, path: selector) else { return "" }
        let body = Self.stringFromJSONValue(value)
        return applyReplaceRules(body).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 极简 JSONPath 导航：支持 $.a.b[0].c。字典段按 key 取，数组段按 [n] 取下标。
    private func navigateJSON(_ json: Any, path: String) -> Any? {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hasPrefix("$") { p = String(p.dropFirst()) }
        if p.hasPrefix(".") { p = String(p.dropFirst()) }
        guard !p.isEmpty else { return json }
        var current: Any = json
        for segment in p.components(separatedBy: ".") where !segment.isEmpty {
            let keyRange = segment.range(of: "[")
            let key = keyRange.map { String(segment[..<$0.lowerBound]) } ?? segment
            if !key.isEmpty {
                guard let dict = current as? [String: Any],
                      let next = dict[key] else { return nil }
                current = next
            }
            if let keyRange {
                let bracketContent = segment[keyRange.upperBound...]
                if let endBracket = bracketContent.range(of: "]") {
                    let idxText = String(bracketContent[..<endBracket.lowerBound])
                    if let idx = Int(idxText) {
                        guard let arr = current as? [Any], idx >= 0, idx < arr.count else { return nil }
                        current = arr[idx]
                    }
                }
            }
        }
        return current
    }

    private static func stringFromJSONValue(_ value: Any) -> String {
        if let str = value as? String {
            return str
        }
        if let arr = value as? [String] {
            return arr.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        if let arr = value as? [Any] {
            return arr.map { stringFromJSONValue($0) }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
        }
        return "\(value)"
    }

    // MARK: - 构建搜索请求

    private func buildSearchRequest(needle: String) throws -> (request: URLRequest, charset: String) {
        var rawTemplate = source.searchRule.urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawTemplate.isEmpty {
            rawTemplate = source.sourceURL + "/search?q={{key}}"
        }

        var baseTemplate = rawTemplate
        var method = source.searchRule.httpMethod.uppercased()
        var bodyTemplate = source.searchRule.postBody
        var extraHeaders: [String: String] = [:]
        var charsetOption: String? = nil

        // 解析阅读 3.0 的后缀扩展选项，例如：url,{"method":"POST","body":"key={{key}}","charset":"gbk"}
        if let commaIndex = rawTemplate.firstIndex(of: ",") {
            let suffix = String(rawTemplate[rawTemplate.index(after: commaIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if suffix.hasPrefix("{") && suffix.hasSuffix("}"),
               let data = suffix.data(using: .utf8),
               let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                baseTemplate = String(rawTemplate[..<commaIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                if let m = dict["method"] as? String { method = m.uppercased() }
                if let b = dict["body"] as? String { bodyTemplate = b }
                if let h = dict["headers"] as? [String: String] { extraHeaders = h }
                if let c = dict["charset"] as? String { charsetOption = c }
            }
        }

        // 检测是否使用 GBK / GB2312 编码
        let isGBK = (charsetOption?.lowercased().contains("gb") == true)
            || baseTemplate.contains("{{key%gbk}}")
            || baseTemplate.contains("{{key%GBK}}")
            || baseTemplate.lowercased().contains("charset=gbk")
            || baseTemplate.lowercased().contains("charset=gb2312")
            || baseTemplate.contains("modules/article/")
            || baseTemplate.contains("waps.php")
            || source.rawJSON.lowercased().contains("\"charset\":\"gbk\"")
            || source.rawJSON.lowercased().contains("\"charset\": \"gbk\"")

        let encodedNeedle: String
        if isGBK {
            encodedNeedle = Self.gbkPercentEncode(needle)
        } else {
            encodedNeedle = needle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? needle
        }

        // 变量替换
        let interpolatedURLString = interpolateVariables(baseTemplate, encodedQuery: encodedNeedle)

        // 构造完整 URL（支持相对路径与基于 sourceURL 补齐）
        guard let finalURL = resolveURL(interpolatedURLString, relativeTo: source.sourceURL) else {
            throw SourceError.badURL
        }

        var request = URLRequest(url: finalURL)
        request.timeoutInterval = 20
        request.httpMethod = method
        applyBrowserHeaders(to: &request, baseURL: finalURL)

        for (k, v) in source.searchRule.headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        for (k, v) in extraHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }

        if method == "POST", let bodyTemplate = bodyTemplate {
            let body = interpolateVariables(bodyTemplate, encodedQuery: encodedNeedle)
            let charsetName = isGBK ? "gbk" : "utf-8"
            if isGBK {
                let cfEnc = CFStringEncodings.GB_18030_2000.rawValue
                let nsEnc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEnc))
                request.httpBody = body.data(using: String.Encoding(rawValue: nsEnc)) ?? body.data(using: .utf8)
            } else {
                request.httpBody = body.data(using: .utf8)
            }
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/x-www-form-urlencoded; charset=\(charsetName)", forHTTPHeaderField: "Content-Type")
            }
        }

        return (request, isGBK ? "gbk" : "utf-8")
    }

    private func interpolateVariables(_ template: String, encodedQuery: String) -> String {
        var str = template
        let keyPlaceholders = [
            "{{key%gbk}}", "{{key%GBK}}", "{{key}}", "{{keyWord}}", "{{keyword}}",
            "%@keyWord", "%@keyword", "%@key", "%@result"
        ]
        for p in keyPlaceholders {
            str = str.replacingOccurrences(of: p, with: encodedQuery)
        }
        let pagePlaceholders = ["{{page}}", "{{pageIndex}}", "%@pageIndex", "%@page"]
        for p in pagePlaceholders {
            str = str.replacingOccurrences(of: p, with: "1")
        }
        return str
    }

    // MARK: - 网络请求与错误诊断

    private func applyBrowserHeaders(to request: inout URLRequest, baseURL: URL) {
        let host = baseURL.host?.lowercased() ?? ""
        let userAgent: String
        if host == "zongheng.com" || host.hasSuffix(".zongheng.com") {
            // 手机版 m.zongheng.com 直接 500。桌面首页才把书单渲染进 HTML。
            userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        } else {
            userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
        }
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh-Hans;q=0.9,zh;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        if let host = baseURL.host {
            let scheme = baseURL.scheme ?? "https"
            request.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
        }
    }

    private func loadData(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // 对超时、连接中断、5xx 做 1 次退避重试。
        for attempt in 0...1 {
            do {
                let (data, http) = try await performLoad(request: request)
                if (500...599).contains(http.statusCode) {
                    if attempt == 0 {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        continue
                    }
                    throw SourceError.detailedBadResponse("HTTP \(http.statusCode)（书源服务器发生内部故障）")
                }
                return (data, http)
            } catch let error as URLError {
                if (error.code == .timedOut || error.code == .networkConnectionLost), attempt == 0 {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    continue
                }
                throw mapURLError(error)
            }
        }
        throw SourceError.badResponse
    }

    /// 单次网络请求。404/403/非 2xx 直接抛 SourceError；5xx 正常返回，由 loadData 决定是否重试。
    private func performLoad(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.badResponse
        }
        if http.statusCode == 404 {
            throw SourceError.notFound
        }
        if http.statusCode == 403 {
            throw SourceError.detailedBadResponse("HTTP 403 Forbidden（书源站点启用了反爬保护或 Cloudflare 防护，已拦截请求）")
        }
        if !(200..<300).contains(http.statusCode) && !(500...599).contains(http.statusCode) {
            throw SourceError.detailedBadResponse("HTTP 状态码 \(http.statusCode)")
        }
        return (data, http)
    }

    private func mapURLError(_ urlError: URLError) -> SourceError {
        let host = urlError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String
            ?? requestHostFallback
        switch urlError.code {
        case .timedOut:
            return SourceError.detailedUnreachable("连接超时（\(host) 响应超时，请检查网络或稍后重试）")
        case .cannotFindHost:
            return SourceError.detailedUnreachable("找不到主机域名（\(host) DNS 解析失败，可能域名已失效或被封禁）")
        case .cannotConnectToHost:
            return SourceError.detailedUnreachable("无法连接到服务器（\(host) 拒绝连接或站点已停机维护）")
        case .networkConnectionLost:
            return SourceError.detailedUnreachable("网络连接意外中断，请重试")
        case .notConnectedToInternet:
            return SourceError.detailedUnreachable("当前设备未连接互联网，请检查 Wi-Fi 或蜂窝网络设置")
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return SourceError.detailedUnreachable("SSL 证书安全校验未通过（\(host) 证书可能已过期或不安全）")
        case .appTransportSecurityRequiresSecureConnection:
            return SourceError.detailedUnreachable("系统安全策略拦截(ATS)：书源站点使用未加密 HTTP，已被系统拦截")
        default:
            return SourceError.detailedUnreachable("网络请求失败: \(urlError.localizedDescription)")
        }
    }

    private var requestHostFallback: String { "书源服务器" }

    // MARK: - 辅助方法

    private func resolveURL(_ path: String, relativeTo base: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        // 飞卢、纵横的链接写成 //host/path，相对解析不会补上协议。
        if trimmed.hasPrefix("//") {
            return URL(string: "https:" + trimmed)
        }

        var baseTrimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if !baseTrimmed.contains("://") && !baseTrimmed.isEmpty {
            baseTrimmed = "https://" + baseTrimmed
        }

        guard let baseURL = URL(string: baseTrimmed) else {
            if !trimmed.contains("://") {
                return URL(string: "https://" + trimmed)
            }
            return URL(string: trimmed)
        }

        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }

    private static func gbkPercentEncode(_ str: String) -> String {
        let cfEnc = CFStringEncodings.GB_18030_2000.rawValue
        let nsEnc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEnc))
        guard let data = str.data(using: String.Encoding(rawValue: nsEnc)) else {
            return str.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? str
        }
        return data.map { byte in
            // ASCII unreserved: 0-9, A-Z, a-z, '-', '_', '.', '~'
            if (byte >= 0x30 && byte <= 0x39) ||
               (byte >= 0x41 && byte <= 0x5A) ||
               (byte >= 0x61 && byte <= 0x7A) ||
               byte == 0x2D || byte == 0x5F || byte == 0x2E || byte == 0x7E {
                return String(UnicodeScalar(byte))
            } else {
                return String(format: "%%%02X", byte)
            }
        }.joined()
    }

    /// 三层编码判定：①响应头 Content-Type charset ②HTML 全文 meta charset ③UTF-8 严格解码失败再回退 GBK。
    private func decode(_ data: Data, response: HTTPURLResponse? = nil, preferredCharset: String? = nil) -> String {
        let gbkEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let header = response?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let meta = sniffCharset(data)

        // 任一来源声明 GBK，就优先按 GBK 解，避免先按 UTF-8 把汉字解坏。
        let signaledGB = meta == "gbk"
            || header.contains("gb")
            || (preferredCharset?.lowercased().contains("gb") ?? false)
        if signaledGB,
           let gbk = String(data: data, encoding: String.Encoding(rawValue: gbkEncoding)) {
            return gbk
        }

        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }

        if let gbk = String(data: data, encoding: String.Encoding(rawValue: gbkEncoding)) {
            return gbk
        }

        return String(decoding: data, as: UTF8.self)
    }

    /// 全文（前 256KB）扫描 meta charset，不再只看前 4096 字节。返回 "gbk"/"utf-8"/nil。
    private func sniffCharset(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .isoLatin1)?.lowercased() else {
            return nil
        }
        let scan = String(text.prefix(256_000))
        if scan.range(of: #"charset\s*=\s*["']?gb(k|2312|18030)"#, options: .regularExpression) != nil {
            return "gbk"
        }
        if scan.range(of: #"charset\s*=\s*["']?utf-?8"#, options: .regularExpression) != nil {
            return "utf-8"
        }
        return nil
    }

    private func loadChapterList(bookURL: URL, detailRoot: HTMLNode) async throws -> [(title: String, url: URL)] {
        let listRule = source.tocRule.listSelector.isEmpty ? "//div[@class='chapters']//a" : source.tocRule.listSelector
        var transport: Error?
        for candidate in catalogCandidates(bookURL: bookURL, detailRoot: detailRoot) {
            let root: HTMLNode
            if candidate.absoluteString == bookURL.absoluteString {
                root = detailRoot
            } else {
                do {
                    var request = URLRequest(url: candidate)
                    request.timeoutInterval = 20
                    applyBrowserHeaders(to: &request, baseURL: candidate)
                    let (data, chapterResponse) = try await loadData(request: request)
                    root = HTMLMiniParser.parse(decode(data, response: chapterResponse))
                } catch let error as SourceError {
                    if case .notFound = error { continue }
                    transport = error
                    continue
                } catch {
                    transport = error
                    continue
                }
            }
            // 父节点是 weak。必须在这棵树还活着时读 data-num 并排序。
            let nodes = HTMLMiniParser.queryNodes(root: root, rule: listRule)
            let entries = chapterEntries(from: nodes, pageURL: candidate)
            if !entries.isEmpty {
                return entries
            }
        }
        if let transport { throw transport }
        throw SourceError.emptyBook
    }

    /// 先跟「完整目录」，再试 69书吧把详情地址换成目录地址，最后才用详情页自己。
    private func catalogCandidates(bookURL: URL, detailRoot: HTMLNode) -> [URL] {
        var urls: [URL] = []
        func append(_ url: URL?) {
            guard let url else { return }
            if !urls.contains(where: { $0.absoluteString == url.absoluteString }) {
                urls.append(url)
            }
        }

        for part in source.tocRule.tocURLSelector.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !part.isEmpty {
            if part.hasPrefix("rewrite:") {
                append(rewriteCatalogURL(bookURL, spec: String(part.dropFirst("rewrite:".count))))
            } else if let href = HTMLMiniParser.queryStrings(root: detailRoot, rule: part).first {
                append(resolveURL(href, relativeTo: bookURL.absoluteString))
            }
        }
        for derived in shubaCatalogURLs(from: bookURL) {
            append(derived)
        }
        append(bookURL)
        return urls
    }

    private func rewriteCatalogURL(_ url: URL, spec: String) -> URL? {
        var text = url.absoluteString
        for pair in spec.split(separator: "|") {
            let sides = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard sides.count == 2, !sides[0].isEmpty else { continue }
            text = text.replacingOccurrences(of: sides[0], with: sides[1])
        }
        guard text != url.absoluteString else { return nil }
        return URL(string: text)
    }

    private static let shubaRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"(?:/book/|/txt/)(\d+)"#)
    }()

    /// /book/123.htm、/txt/123.htm、/txt/123/456 的目录都在 /book/123/。
    private func shubaCatalogURLs(from url: URL) -> [URL] {
        let host = (url.host ?? "").lowercased()
        let sourceHost = (URL(string: source.sourceURL)?.host ?? "").lowercased()
        guard host.contains("69shu") || sourceHost.contains("69shu") else { return [] }
        guard let regex = Self.shubaRegex else { return [] }
        let path = url.path
        let range = NSRange(path.startIndex..., in: path)
        guard let match = regex.firstMatch(in: path, range: range),
              let idRange = Range(match.range(at: 1), in: path) else {
            return []
        }
        let id = String(path[idRange])
        return ["/book/\(id)/", "/\(id)/"].compactMap { catalogPath in
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            parts?.path = catalogPath
            parts?.query = nil
            parts?.fragment = nil
            let derived = parts?.url
            return derived?.absoluteString == url.absoluteString ? nil : derived
        }
    }

    private func chapterEntries(from nodes: [HTMLNode], pageURL: URL) -> [(title: String, url: URL)] {
        var entries: [(title: String, url: URL, sort: Int?)] = []
        for node in nodes {
            let chapTitle = HTMLMiniParser.queryStrings(
                root: node,
                rule: source.tocRule.nameSelector.isEmpty ? "text" : source.tocRule.nameSelector
            ).first ?? node.allText
            let chapHref = HTMLMiniParser.queryStrings(
                root: node,
                rule: source.tocRule.urlSelector.isEmpty ? "href" : source.tocRule.urlSelector
            ).first ?? node.get(attr: "href")
            guard let chapHref, let chapURL = resolveURL(chapHref, relativeTo: pageURL.absoluteString) else {
                continue
            }
            if isBookInfoLink(chapURL) { continue }
            let cleanedTitle = chapTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let sort = Int(node.parent?.get(attr: "data-num") ?? "")
            entries.append((cleanedTitle.isEmpty ? "章节" : cleanedTitle, chapURL, sort))
        }
        // 目录页按更新倒序。有 data-num 时排回第一章在前。
        if entries.contains(where: { $0.sort != nil }) {
            entries.sort { ($0.sort ?? Int.max) < ($1.sort ?? Int.max) }
        }
        var ordered = entries.map { ($0.title, $0.url) }
        // 没有 data-num 时，站点常把最新章放最前、第1章压在末尾；识别到第1章在末尾就整体翻正序。
        if !entries.contains(where: { $0.sort != nil }) {
            ordered = normalizeAscending(ordered)
        }
        if source.tocRule.startAtFirstChapter {
            return openingChapterOrder(ordered)
        }
        return ordered
    }

    /// 站点目录可能按更新倒序（最新章在前、第1章在后）。
    /// 开头不是第1章而末尾是第1章时，整份翻回正序，保证 remoteIndex 0 是第一章。
    private func normalizeAscending(_ entries: [(title: String, url: URL)]) -> [(title: String, url: URL)] {
        guard entries.count >= 2 else { return entries }
        let firstIsOpening = RemoteChapterList.looksLikeOpening(entries[0].title)
        let lastIsOpening = RemoteChapterList.looksLikeOpening(entries[entries.count - 1].title)
        if !firstIsOpening, lastIsOpening {
            return entries.reversed()
        }
        return entries
    }

    /// 最新章节横幅通常只有几条，紧跟着才是从第1章排到接近最新章的正文目录。
    private func openingChapterOrder(_ entries: [(title: String, url: URL)]) -> [(title: String, url: URL)] {
        guard let index = entries.firstIndex(where: { isOpeningChapter($0.title) }), index <= 40 else {
            return entries
        }
        if index == 0 {
            return dedupeChapters(entries)
        }
        let prefix = entries[..<index]
        var result = dedupeChapters(Array(entries[index...]))
        var seen = Set(result.map { $0.url.absoluteString })
        for item in prefix.reversed() where seen.insert(item.url.absoluteString).inserted {
            result.append(item)
        }
        return result
    }

    private func dedupeChapters(_ entries: [(title: String, url: URL)]) -> [(title: String, url: URL)] {
        var seen = Set<String>()
        var result: [(title: String, url: URL)] = []
        for entry in entries where seen.insert(entry.url.absoluteString).inserted {
            result.append(entry)
        }
        return result
    }

    /// 去掉空白和「1.」这类序号后，只认第1章、第一章、第一回、序章、楔子。
    private func isOpeningChapter(_ title: String) -> Bool {
        let compact = title.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        var text = String(String.UnicodeScalarView(compact))
        if let range = text.range(of: #"^\d+[\.、]"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        return text.range(
            of: #"^(序章|楔子|前言|引子|第[0０]*[1１一][章节回节])"#,
            options: .regularExpression
        ) != nil
    }

    /// 目录页里指回书籍详情的链接不是章节。
    private func isBookInfoLink(_ url: URL) -> Bool {
        url.path.range(of: #"/book/\d+\.htm$"#, options: .regularExpression) != nil
    }

    private func chapterBody(from root: HTMLNode) -> String {
        let rule = source.contentRule.contentSelector
        let raw: String
        if rule.contains("txtnav"),
           let nav = HTMLMiniParser.queryNodes(root: root, rule: ".txtnav").first {
            raw = readableText(nav)
        } else {
            let selector = rule.isEmpty ? "//div[@id='content']/text()" : rule
            raw = HTMLMiniParser.queryStrings(root: root, rule: selector).joined(separator: "\n\n")
        }
        return applyReplaceRules(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 正文容器里的标题、作者栏和右侧广告不算正文。
    private func readableText(_ node: HTMLNode) -> String {
        var lines: [String] = []
        func walk(_ current: HTMLNode) {
            if current.tag == "h1" || current.tag == "script" || current.tag == "style" { return }
            let className = current.attributes["class"] ?? ""
            let elementID = current.attributes["id"] ?? ""
            if className.contains("txtinfo") || elementID == "txtright" || className.contains("contentadv")
                || className.contains("bottom-ad") || className.contains("page1") {
                return
            }
            if current.tag == "br" {
                lines.append("")
                return
            }
            if current.tag == "#text" {
                let text = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lines.append(text) }
                return
            }
            for child in current.children {
                walk(child)
            }
        }
        walk(node)
        return lines.filter { line in
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return true }
            if text.count <= 40, text.contains("69书吧") || text.contains("69shuba.com") {
                return false
            }
            return true
        }.joined(separator: "\n")
    }

    private func applyReplaceRules(_ text: String) -> String {
        var rawContent = text
        // 多规则串联：replaceRules 为数组，逐条按 pattern##replacement（缺省 replacement 即删除匹配）应用。
        for replaceRule in source.contentRule.replaceRules {
            let parts = replaceRule.components(separatedBy: "##").filter { !$0.isEmpty }
            guard let pattern = parts.first else { continue }
            let repl = parts.count > 1 ? parts[1] : ""
            if let regex = try? NSRegularExpression(pattern: pattern) {
                rawContent = regex.stringByReplacingMatches(
                    in: rawContent,
                    range: NSRange(location: 0, length: (rawContent as NSString).length),
                    withTemplate: repl
                )
            }
        }
        // 按行过滤：删掉清洗后变空的广告行/水印行，并折叠多余空行为单空行。
        var kept: [String] = []
        for line in rawContent.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if kept.last?.isEmpty == false { kept.append("") }
            } else {
                kept.append(trimmed)
            }
        }
        return kept.joined(separator: "\n")
    }

    // MARK: - 解析搜索结果

    private struct FieldSelectors {
        var list: String
        var name: String
        var author: String
        var detail: String
        var summary: String
        var cover: String
        var lastChapter: String
        var category: String
        var status: String
    }

    private func searchFieldSelectors() -> FieldSelectors {
        FieldSelectors(
            list: source.searchRule.listSelector,
            name: source.searchRule.nameSelector,
            author: source.searchRule.authorSelector,
            detail: source.searchRule.detailURLSelector,
            summary: source.searchRule.summarySelector,
            cover: source.searchRule.coverSelector,
            lastChapter: source.searchRule.lastChapterSelector,
            category: source.searchRule.categorySelector,
            status: source.searchRule.statusSelector
        )
    }

    private func exploreFieldSelectors() -> FieldSelectors {
        func pick(_ explore: String, _ search: String) -> String {
            explore.isEmpty ? search : explore
        }
        return FieldSelectors(
            list: pick(source.exploreRule.listSelector, source.searchRule.listSelector),
            name: pick(source.exploreRule.nameSelector, source.searchRule.nameSelector),
            author: pick(source.exploreRule.authorSelector, source.searchRule.authorSelector),
            detail: pick(source.exploreRule.detailURLSelector, source.searchRule.detailURLSelector),
            summary: pick(source.exploreRule.summarySelector, source.searchRule.summarySelector),
            cover: pick(source.exploreRule.coverSelector, source.searchRule.coverSelector),
            lastChapter: source.searchRule.lastChapterSelector,
            category: pick(source.exploreRule.categorySelector, source.searchRule.categorySelector),
            status: pick(source.exploreRule.statusSelector, source.searchRule.statusSelector)
        )
    }

    private func parseHTMLBooks(_ html: String, baseURL: URL, selectors: FieldSelectors) -> [CatalogBook] {
        let root = HTMLMiniParser.parse(html)
        let listRule = selectors.list.isEmpty ? "//ul[@id='result']/li" : selectors.list
        let nodes = HTMLMiniParser.queryNodes(root: root, rule: listRule)

        var books: [CatalogBook] = []
        var seen = Set<String>()
        for node in nodes {
            let title = HTMLMiniParser.queryStrings(
                root: node,
                rule: selectors.name.isEmpty ? "//a/text()" : selectors.name
            ).first ?? ""

            let author = HTMLMiniParser.queryStrings(
                root: node,
                rule: selectors.author.isEmpty ? "//span[@class='author']/text()" : selectors.author
            ).first ?? ""

            let summary = HTMLMiniParser.queryStrings(
                root: node,
                rule: selectors.summary.isEmpty ? "//p[@class='desc']/text()" : selectors.summary
            ).first ?? ""

            let queriedHref = HTMLMiniParser.queryStrings(
                root: node,
                rule: selectors.detail.isEmpty ? "//a/@href" : selectors.detail
            ).first
            let detailHref = node.nearestHref(preferred: queriedHref) ?? ""

            let coverURL = extractCoverURL(from: node, selector: selectors.cover, baseURL: baseURL)
            let latestChapter = selectors.lastChapter.isEmpty
                ? ""
                : (HTMLMiniParser.queryStrings(root: node, rule: selectors.lastChapter).first ?? "")
            let category = selectors.category.isEmpty
                ? ""
                : (HTMLMiniParser.queryStrings(root: node, rule: selectors.category).first ?? "")
            let status = selectors.status.isEmpty
                ? ""
                : (HTMLMiniParser.queryStrings(root: node, rule: selectors.status).first ?? "")

            guard !title.isEmpty, let resolvedDetailURL = resolveURL(detailHref, relativeTo: baseURL.absoluteString) else {
                continue
            }
            guard seen.insert(resolvedDetailURL.absoluteString).inserted else {
                continue
            }

            books.append(CatalogBook(
                id: resolvedDetailURL.absoluteString,
                title: title,
                author: author,
                summary: summary,
                category: category.trimmingCharacters(in: .whitespacesAndNewlines),
                status: status.trimmingCharacters(in: .whitespacesAndNewlines),
                coverURL: coverURL,
                latestChapter: LatestChapterLabel.clean(latestChapter)
            ))
        }

        return books
    }

    /// 提取列表项封面图：优先使用书源规则，其次兼容图片懒加载属性（data-original / data-src / data-lazy），并过滤站点的无封面占位图。
    private func extractCoverURL(from node: HTMLNode, selector: String, baseURL: URL) -> String {
        var candidates: [String] = []
        if !selector.isEmpty {
            candidates.append(contentsOf: HTMLMiniParser.queryStrings(root: node, rule: selector))
        }
        let fallbackRules = [
            "//img/@data-original",
            "//img/@data-src",
            "//img/@data-lazy",
            "//img/@data-echo",
            "//img/@src"
        ]
        for rule in fallbackRules {
            candidates.append(contentsOf: HTMLMiniParser.queryStrings(root: node, rule: rule))
        }
        for raw in candidates {
            if let valid = validatedCoverURL(raw, relativeTo: baseURL) {
                return valid
            }
        }
        return ""
    }

    /// 提取详情页封面图：优先使用 infoCoverSelector，其次尝试 OpenGraph og:image 与常见封面容器。
    private func extractDetailCoverURL(from root: HTMLNode, baseURL: URL) -> String {
        var candidates: [String] = []
        if !source.tocRule.infoCoverSelector.isEmpty {
            candidates.append(contentsOf: HTMLMiniParser.queryStrings(root: root, rule: source.tocRule.infoCoverSelector))
        }
        let detailFallbackRules = [
            "//meta[@property='og:image']/@content",
            "//div[@id='fmimg']//img/@data-original",
            "//div[@id='fmimg']//img/@data-src",
            "//div[@id='fmimg']//img/@src",
            "//div[@class='bookimg']//img/@data-original",
            "//div[@class='bookimg']//img/@data-src",
            "//div[@class='bookimg']//img/@src",
            "//div[@class='booknav2']//img/@src",
            "//div[@class='cover']//img/@data-original",
            "//div[@class='cover']//img/@data-src",
            "//div[@class='cover']//img/@src"
        ]
        for rule in detailFallbackRules {
            candidates.append(contentsOf: HTMLMiniParser.queryStrings(root: root, rule: rule))
        }
        for raw in candidates {
            if let valid = validatedCoverURL(raw, relativeTo: baseURL) {
                return valid
            }
        }
        return ""
    }

    private func validatedCoverURL(_ raw: String, relativeTo baseURL: URL) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !Self.isPlaceholderCover(trimmed) else { return nil }
        guard let resolved = resolveURL(trimmed, relativeTo: baseURL.absoluteString) else { return nil }
        let abs = resolved.absoluteString
        guard !Self.isPlaceholderCover(abs) else { return nil }
        return abs
    }

    nonisolated static func isPlaceholderCover(_ urlString: String) -> Bool {
        let lower = urlString.lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("data:image/gif") || lower.hasPrefix("about:") {
            return true
        }
        let placeholders = [
            "nocover", "no-cover", "no_cover", "noimg", "no-img", "no_img",
            "nopic", "no-pic", "no_pic", "default.jpg", "default.png",
            "default_cover", "default-cover", "defaultcover", "none.gif",
            "blank.gif", "loading.gif", "lazy.gif", "/s.gif"
        ]
        for token in placeholders where lower.contains(token) {
            return true
        }
        return false
    }

    private func tryParseJSONSearchResults(_ text: String) -> [CatalogBook]? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        var listAny: [Any]?
        // 优先按配置的 listSelector（如 $.data.list）导航到数组。
        let listSel = source.searchRule.listSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        if listSel.hasPrefix("$") || listSel.hasPrefix(".") {
            listAny = navigateJSON(json, path: listSel) as? [Any]
        }
        if listAny == nil {
            if let array = json as? [Any] {
                listAny = array
            } else if let dict = json as? [String: Any] {
                let keys = ["books", "list", "data", "results", "items"]
                for key in keys {
                    if let sub = dict[key] as? [Any] {
                        listAny = sub
                        break
                    }
                }
            }
        }

        guard let listArray = listAny, !listArray.isEmpty else { return nil }

        var books: [CatalogBook] = []
        for itemAny in listArray {
            guard let item = itemAny as? [String: Any] else { continue }
            let id = (item["id"] as? CustomStringConvertible)?.description
                ?? (item["bookId"] as? CustomStringConvertible)?.description
                ?? (item["url"] as? String) ?? UUID().uuidString
            let title = (item["title"] as? String) ?? (item["name"] as? String) ?? (item["bookName"] as? String) ?? "未命名"
            let author = (item["author"] as? String) ?? ""
            let summary = (item["summary"] as? String) ?? (item["desc"] as? String) ?? (item["intro"] as? String) ?? ""
            let rawCover = (item["cover"] as? String) ?? (item["coverUrl"] as? String) ?? (item["coverURL"] as? String) ?? (item["img"] as? String) ?? (item["coverImage"] as? String) ?? ""
            let cover = Self.isPlaceholderCover(rawCover) ? "" : (resolveURL(rawCover, relativeTo: source.sourceURL)?.absoluteString ?? rawCover)
            let category = (item["category"] as? String) ?? (item["cat"] as? String) ?? (item["kind"] as? String) ?? ""
            let status = (item["status"] as? String) ?? ""
            let latest = (item["lastChapter"] as? String)
                ?? (item["latestChapter"] as? String)
                ?? (item["newChapter"] as? String)
                ?? ""

            books.append(CatalogBook(
                id: id,
                title: title,
                author: author,
                summary: summary,
                category: category,
                status: status,
                coverURL: cover,
                latestChapter: LatestChapterLabel.clean(latest)
            ))
        }

        return books.isEmpty ? nil : books
    }
}

/// 并发整本下载时线程安全地累计字节数，超过 40MB 上限即抛错。
private actor ByteCounter {
    private var total = 0

    func add(_ bytes: Int) throws {
        total += bytes
        if total > BookStorage.byteLimit {
            throw ImportError.tooLarge
        }
    }
}
