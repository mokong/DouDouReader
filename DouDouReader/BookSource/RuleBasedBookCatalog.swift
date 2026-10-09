import Foundation

/// 基于规则（阅读 3.0 或香色闺阁）的通用书源目录执行器
nonisolated struct RuleBasedBookCatalog: IncrementalBookCatalog {
    var id: String
    var name: String
    var source: UniversalBookSource
    var session: URLSession

    init(recordID: String, source: UniversalBookSource, session: URLSession = .shared) {
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

        let data = try await loadData(request: request)
        let htmlOrJSON = decodeString(from: data, preferredCharset: detectedCharset)

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

        let data = try await loadData(request: request)
        let prefersGBK = source.rawJSON.lowercased().contains("gbk")
            || source.searchRule.urlTemplate.lowercased().contains("gbk")
        let text = decodeString(from: data, preferredCharset: prefersGBK ? "gbk" : nil)
        if let jsonBooks = tryParseJSONSearchResults(text) {
            return jsonBooks
        }
        return parseHTMLBooks(text, baseURL: url, selectors: exploreFieldSelectors())
    }

    // MARK: - 获取正文

    func fetchText(bookID: String, progress: (@Sendable (Int, Int) -> Void)?) async throws -> (title: String, text: String) {
        let prepared = try await prepare(bookID: bookID)
        var assembledChapters: [(title: String, content: String)] = []
        var totalBytes = 0
        for (index, item) in prepared.chapters.enumerated() {
            progress?(index + 1, prepared.chapters.count)
            let rawContent = try await downloadChapter(item.url)
            totalBytes += rawContent.utf8.count
            if totalBytes > BookStorage.byteLimit {
                throw ImportError.tooLarge
            }
            assembledChapters.append((item.title, rawContent))
        }
        let fullText = CatalogText.assemble(author: prepared.author, chapters: assembledChapters)
        guard assembledChapters.contains(where: { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
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
        return OnlineOpening(title: prepared.title, author: prepared.author, text: text, chapters: refs)
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
        var chapters: [(title: String, url: URL)]
    }

    private func prepare(bookID: String) async throws -> PreparedBook {
        guard let bookURL = resolveURL(bookID, relativeTo: source.sourceURL) else {
            throw SourceError.badURL
        }

        var detailRequest = URLRequest(url: bookURL)
        detailRequest.timeoutInterval = 20
        applyBrowserHeaders(to: &detailRequest, baseURL: bookURL)

        let detailData = try await loadData(request: detailRequest)
        let detailHtml = decodeString(from: detailData)
        let detailRoot = HTMLMiniParser.parse(detailHtml)

        let title = HTMLMiniParser.queryStrings(root: detailRoot, rule: "//h1/text()").first
            ?? HTMLMiniParser.queryStrings(root: detailRoot, rule: "title").first
            ?? "未知书名"
        let author = HTMLMiniParser.queryStrings(root: detailRoot, rule: "//span[@class='author']/text()").first ?? ""
        let chapters = try await loadChapterList(bookURL: bookURL, detailRoot: detailRoot)
        guard !chapters.isEmpty else { throw SourceError.emptyBook }
        return PreparedBook(title: title, author: author, chapters: chapters)
    }

    private func downloadChapter(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        applyBrowserHeaders(to: &request, baseURL: url)
        let data = try await loadData(request: request)
        let root = HTMLMiniParser.parse(decodeString(from: data))
        return chapterBody(from: root)
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

    private func loadData(request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        let host = request.url?.host ?? "书源服务器"

        do {
            (data, response) = try await session.data(for: request)
        } catch let err as SourceError {
            throw err
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut:
                throw SourceError.detailedUnreachable("连接超时（\(host) 响应超时，请检查网络或稍后重试）")
            case .cannotFindHost:
                throw SourceError.detailedUnreachable("找不到主机域名（\(host) DNS 解析失败，可能域名已失效或被封禁）")
            case .cannotConnectToHost:
                throw SourceError.detailedUnreachable("无法连接到服务器（\(host) 拒绝连接或站点已停机维护）")
            case .networkConnectionLost:
                throw SourceError.detailedUnreachable("网络连接意外中断，请重试")
            case .notConnectedToInternet:
                throw SourceError.detailedUnreachable("当前设备未连接互联网，请检查 Wi-Fi 或蜂窝网络设置")
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                throw SourceError.detailedUnreachable("SSL 证书安全校验未通过（\(host) 证书可能已过期或不安全）")
            case .appTransportSecurityRequiresSecureConnection:
                throw SourceError.detailedUnreachable("系统安全策略拦截(ATS)：书源站点使用未加密 HTTP，已被系统拦截")
            default:
                throw SourceError.detailedUnreachable("网络请求失败: \(urlError.localizedDescription)")
            }
        } catch {
            throw SourceError.detailedUnreachable("连接书源失败: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw SourceError.badResponse
        }

        if http.statusCode == 404 {
            throw SourceError.notFound
        }

        if http.statusCode == 403 {
            throw SourceError.detailedBadResponse("HTTP 403 Forbidden（书源站点启用了反爬保护或 Cloudflare 防护，已拦截请求）")
        }

        if (500...599).contains(http.statusCode) {
            throw SourceError.detailedBadResponse("HTTP \(http.statusCode)（书源服务器发生内部故障）")
        }

        guard (200..<300).contains(http.statusCode) else {
            throw SourceError.detailedBadResponse("HTTP 状态码 \(http.statusCode)")
        }

        return data
    }

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

    private func decodeString(from data: Data, preferredCharset: String? = nil) -> String {
        let gbkEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let sniffed = sniffCharset(data)
        let preferred = sniffed ?? preferredCharset

        if let preferred = preferred?.lowercased(), preferred.contains("gb") {
            if let gbk = String(data: data, encoding: String.Encoding(rawValue: gbkEncoding)) {
                return gbk
            }
        }

        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }

        if let gbk = String(data: data, encoding: String.Encoding(rawValue: gbkEncoding)) {
            return gbk
        }

        return String(decoding: data, as: UTF8.self)
    }

    /// 页头的 charset 是 ASCII。69书吧正文是 GBK，不能先按 UTF-8 把汉字解坏。
    private func sniffCharset(_ data: Data) -> String? {
        guard let head = String(data: data.prefix(4096), encoding: .isoLatin1)?.lowercased() else {
            return nil
        }
        if head.range(of: #"charset\s*=\s*["']?gb(k|2312|18030)"#, options: .regularExpression) != nil {
            return "gbk"
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
                    let data = try await loadData(request: request)
                    root = HTMLMiniParser.parse(decodeString(from: data))
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

    /// /book/123.htm、/txt/123.htm、/txt/123/456 的目录都在 /book/123/。
    private func shubaCatalogURLs(from url: URL) -> [URL] {
        let host = (url.host ?? "").lowercased()
        let sourceHost = (URL(string: source.sourceURL)?.host ?? "").lowercased()
        guard host.contains("69shu") || sourceHost.contains("69shu") else { return [] }
        guard let regex = try? NSRegularExpression(pattern: #"(?:/book/|/txt/)(\d+)"#) else { return [] }
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
        return entries.map { ($0.title, $0.url) }
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
        for replaceRule in source.contentRule.replaceRules {
            let parts = replaceRule.components(separatedBy: "##").filter { !$0.isEmpty }
            if parts.count >= 1 {
                let pattern = parts[0]
                let repl = parts.count > 1 ? parts[1] : ""
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    rawContent = regex.stringByReplacingMatches(
                        in: rawContent,
                        range: NSRange(location: 0, length: (rawContent as NSString).length),
                        withTemplate: repl
                    )
                }
            }
        }
        return rawContent
    }

    // MARK: - 解析搜索结果

    private struct FieldSelectors {
        var list: String
        var name: String
        var author: String
        var detail: String
        var summary: String
    }

    private func searchFieldSelectors() -> FieldSelectors {
        FieldSelectors(
            list: source.searchRule.listSelector,
            name: source.searchRule.nameSelector,
            author: source.searchRule.authorSelector,
            detail: source.searchRule.detailURLSelector,
            summary: source.searchRule.summarySelector
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
            summary: pick(source.exploreRule.summarySelector, source.searchRule.summarySelector)
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
                summary: summary
            ))
        }

        return books
    }

    private func tryParseJSONSearchResults(_ text: String) -> [CatalogBook]? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        var listArray: [[String: Any]] = []
        if let array = json as? [[String: Any]] {
            listArray = array
        } else if let dict = json as? [String: Any] {
            let keys = ["books", "list", "data", "results", "items"]
            for key in keys {
                if let sub = dict[key] as? [[String: Any]] {
                    listArray = sub
                    break
                }
            }
        }

        guard !listArray.isEmpty else { return nil }

        var books: [CatalogBook] = []
        for item in listArray {
            let id = (item["id"] as? CustomStringConvertible)?.description
                ?? (item["bookId"] as? CustomStringConvertible)?.description
                ?? (item["url"] as? String) ?? UUID().uuidString
            let title = (item["title"] as? String) ?? (item["name"] as? String) ?? (item["bookName"] as? String) ?? "未命名"
            let author = (item["author"] as? String) ?? ""
            let summary = (item["summary"] as? String) ?? (item["desc"] as? String) ?? (item["intro"] as? String) ?? ""

            books.append(CatalogBook(id: id, title: title, author: author, summary: summary))
        }

        return books
    }
}
