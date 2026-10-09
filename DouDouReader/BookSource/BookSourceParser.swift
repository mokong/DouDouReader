import Foundation

enum BookSourceParserError: LocalizedError {
    case invalidJSON
    case unsupportedFormat
    case emptySource
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON: "无法解析为合法的 JSON 数据"
        case .unsupportedFormat: "未能识别为“阅读”或“香色闺阁”支持的书源格式"
        case .emptySource: "解析结果为空，没有有效的书源"
        case .networkError(let msg): "拉取书源失败：\(msg)"
        }
    }
}

/// 书源解析器：支持“阅读 3.0” (Legado) 与 “香色闺阁” (StandarReader / XBS) 的 JSON 配置解析与导入
enum BookSourceParser {
    // MARK: - 主解析入口

    static func parse(text: String) throws -> [UniversalBookSource] {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\u{FEFF}") {
            trimmed = String(trimmed.dropFirst())
        }
        guard !trimmed.isEmpty else {
            throw BookSourceParserError.emptySource
        }

        guard let data = trimmed.data(using: .utf8) else {
            throw BookSourceParserError.invalidJSON
        }

        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw BookSourceParserError.invalidJSON
        }

        var results: [UniversalBookSource] = []

        if let array = jsonObject as? [[String: Any]] {
            for dict in array {
                if let source = parseDictionary(dict) {
                    results.append(source)
                }
            }
        } else if let dict = jsonObject as? [String: Any] {
            // 1. 判断是否直接是单个书源字典
            if let direct = parseDictionary(dict) {
                results.append(direct)
            } else {
                // 2. 判断是否是香色闺阁的 alias 字典结构，如 { "aliasKey": { "sourceName": ... } }
                for (_, value) in dict {
                    if let innerDict = value as? [String: Any], let source = parseDictionary(innerDict) {
                        results.append(source)
                    }
                }
            }
        }

        guard !results.isEmpty else {
            throw BookSourceParserError.unsupportedFormat
        }

        return results
    }

    /// 从网络 URL 拉取并解析书源
    static func fetchAndParse(from rawURL: String) async throws -> [UniversalBookSource] {
        var urlStr = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)

        // 支持阅读一键导入链接：legado://import/bookSource?src=https://...
        if urlStr.hasPrefix("legado://") || urlStr.hasPrefix("yuedu://") {
            if let components = URLComponents(string: urlStr),
               let src = components.queryItems?.first(where: { $0.name == "src" })?.value {
                urlStr = src
            }
        }

        guard let url = URL(string: urlStr), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw BookSourceParserError.networkError("无效的网络链接")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw BookSourceParserError.networkError(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BookSourceParserError.networkError("服务器返回 HTTP \(http.statusCode)")
        }

        // 解码文本
        let content: String
        if let utf8Str = String(data: data, encoding: .utf8) {
            content = utf8Str
        } else if let gbkEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)) as UInt?,
                  let gbkStr = String(data: data, encoding: String.Encoding(rawValue: gbkEncoding)) {
            content = gbkStr
        } else {
            throw BookSourceParserError.networkError("无法识别返回内容的字符编码")
        }

        return try parse(text: content)
    }

    // MARK: - 字典分类解析

    static func parseDictionary(_ dict: [String: Any]) -> UniversalBookSource? {
        // 1. 判断是否为阅读 3.0 (Legado)
        if dict["bookSourceName"] != nil || dict["bookSourceUrl"] != nil || dict["ruleSearch"] != nil {
            return parseLegado(dict)
        }

        // 2. 判断是否为香色闺阁 (XiangSe)
        if dict["sourceName"] != nil || dict["searchBook"] != nil || dict["chapterContent"] != nil {
            return parseXiangSe(dict)
        }

        // 3. 判断是否为豆豆原生源 (DouDou)
        if dict["baseURL"] != nil {
            return parseDouDou(dict)
        }

        return nil
    }

    // MARK: - 解析“阅读 3.0” (Legado)

    private static func parseLegado(_ dict: [String: Any]) -> UniversalBookSource? {
        let name = (dict["bookSourceName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "未命名阅读源"
        let sourceUrl = (dict["bookSourceUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let group = (dict["bookSourceGroup"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "阅读 3.0"

        var enabled = true
        if let enabledBool = dict["enabled"] as? Bool {
            enabled = enabledBool
        } else if let enabledInt = dict["enabled"] as? Int {
            enabled = enabledInt != 0
        }

        let weight = (dict["customOrder"] as? Int) ?? (dict["weight"] as? Int) ?? 100

        // 搜索规则
        var searchRule = SourceSearchRule()
        if let searchUrlStr = dict["searchUrl"] as? String {
            // Legado 的 searchUrl 可能附带 JSON 请求参数，如 "/search,{"method":"POST"}"
            let parsedSearch = parseLegadoSearchURL(searchUrlStr, baseURL: sourceUrl)
            searchRule.urlTemplate = parsedSearch.url
            searchRule.httpMethod = parsedSearch.method
            searchRule.postBody = parsedSearch.body
            searchRule.headers = parsedSearch.headers
        }

        if let ruleSearch = dict["ruleSearch"] as? [String: Any] {
            searchRule.listSelector = ruleSearch["bookList"] as? String ?? ""
            searchRule.nameSelector = ruleSearch["name"] as? String ?? ""
            searchRule.authorSelector = ruleSearch["author"] as? String ?? ""
            searchRule.detailURLSelector = (ruleSearch["bookUrl"] as? String) ?? (ruleSearch["bookURL"] as? String) ?? ""
            searchRule.summarySelector = (ruleSearch["intro"] as? String) ?? (ruleSearch["summary"] as? String) ?? ""
            searchRule.coverSelector = (ruleSearch["coverUrl"] as? String) ?? (ruleSearch["cover"] as? String) ?? ""
        }

        // 目录规则
        var tocRule = SourceTocRule()
        if let ruleBookInfo = dict["ruleBookInfo"] as? [String: Any] {
            tocRule.tocURLSelector = (ruleBookInfo["tocUrl"] as? String) ?? ""
        }
        if let ruleToc = dict["ruleToc"] as? [String: Any] {
            tocRule.listSelector = ruleToc["chapterList"] as? String ?? ""
            tocRule.nameSelector = (ruleToc["chapterName"] as? String) ?? (ruleToc["name"] as? String) ?? ""
            tocRule.urlSelector = (ruleToc["chapterUrl"] as? String) ?? (ruleToc["url"] as? String) ?? ""
        }

        // 正文规则
        var contentRule = SourceContentRule()
        if let ruleContent = dict["ruleContent"] as? [String: Any] {
            contentRule.contentSelector = ruleContent["content"] as? String ?? ""
            if let replace = ruleContent["replaceRegex"] as? String, !replace.isEmpty {
                contentRule.replaceRules = [replace]
            }
        }

        // 发现规则：切换站点后，频道和筛选都从这里来
        var exploreRule = SourceExploreRule()
        if let exploreURL = dict["exploreUrl"] as? String {
            exploreRule.urlTemplate = exploreURL
        } else if let exploreArray = dict["exploreUrl"] as? [[String: Any]],
                  let data = try? JSONSerialization.data(withJSONObject: exploreArray),
                  let text = String(data: data, encoding: .utf8) {
            exploreRule.urlTemplate = text
        }
        if let ruleExplore = dict["ruleExplore"] as? [String: Any] {
            exploreRule.listSelector = ruleExplore["bookList"] as? String ?? ""
            exploreRule.nameSelector = ruleExplore["name"] as? String ?? ""
            exploreRule.authorSelector = ruleExplore["author"] as? String ?? ""
            exploreRule.detailURLSelector = (ruleExplore["bookUrl"] as? String) ?? (ruleExplore["bookURL"] as? String) ?? ""
            exploreRule.summarySelector = (ruleExplore["intro"] as? String) ?? (ruleExplore["summary"] as? String) ?? ""
            exploreRule.coverSelector = (ruleExplore["coverUrl"] as? String) ?? (ruleExplore["cover"] as? String) ?? ""
        }

        let rawJSON = (try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""

        return UniversalBookSource(
            kind: .legado,
            name: name,
            sourceURL: sourceUrl,
            group: group,
            enabled: enabled,
            weight: weight,
            searchRule: searchRule,
            tocRule: tocRule,
            contentRule: contentRule,
            exploreRule: exploreRule,
            rawJSON: rawJSON
        )
    }

    private static func parseLegadoSearchURL(_ raw: String, baseURL: String) -> (url: String, method: String, body: String?, headers: [String: String]) {
        var url = raw
        var method = "GET"
        var body: String? = nil
        var headers: [String: String] = [:]

        // 判断是否有逗号分隔的附加参数，如 "/search,{"method":"POST","body":"keyword={{key}}"}"
        if let commaIndex = raw.firstIndex(of: ",") {
            let possibleJSON = String(raw[raw.index(after: commaIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if possibleJSON.hasPrefix("{") && possibleJSON.hasSuffix("}"),
               let data = possibleJSON.data(using: .utf8),
               let paramDict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                url = String(raw[..<commaIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                if let m = paramDict["method"] as? String {
                    method = m.uppercased()
                }
                if let b = paramDict["body"] as? String {
                    body = b
                }
                if let h = paramDict["headers"] as? [String: String] {
                    headers = h
                }
            }
        }

        // 补全相对路径
        if !url.contains("://") && !baseURL.isEmpty {
            let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
            let sub = url.hasPrefix("/") ? url : ("/" + url)
            url = base + sub
        }

        return (url, method, body, headers)
    }

    // MARK: - 解析“香色闺阁” (XiangSe)

    private static func parseXiangSe(_ dict: [String: Any]) -> UniversalBookSource? {
        let name = (dict["sourceName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (dict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "未命名香色源"
        let sourceUrl = (dict["sourceUrl"] as? String) ?? (dict["host"] as? String) ?? ""
        let group = (dict["sourceGroup"] as? String) ?? (dict["group"] as? String) ?? "香色闺阁"

        var enabled = true
        if let enableInt = dict["enable"] as? Int {
            enabled = enableInt != 0
        } else if let enableBool = dict["enable"] as? Bool {
            enabled = enableBool
        }

        var weight = 100
        if let weightStr = dict["weight"] as? String, let w = Int(weightStr) {
            weight = w
        } else if let weightInt = dict["weight"] as? Int {
            weight = weightInt
        }

        // 搜索规则 searchBook
        var searchRule = SourceSearchRule()
        if let searchAction = dict["searchBook"] as? [String: Any] {
            if let reqInfo = searchAction["requestInfo"] as? String {
                searchRule.urlTemplate = normalizeXiangSeURL(reqInfo, baseURL: sourceUrl)
            }
            searchRule.listSelector = searchAction["list"] as? String ?? ""
            searchRule.nameSelector = (searchAction["bookName"] as? String) ?? (searchAction["title"] as? String) ?? ""
            searchRule.authorSelector = searchAction["author"] as? String ?? ""
            searchRule.detailURLSelector = (searchAction["detailUrl"] as? String) ?? (searchAction["url"] as? String) ?? ""
            searchRule.summarySelector = (searchAction["desc"] as? String) ?? (searchAction["intro"] as? String) ?? ""
            searchRule.coverSelector = searchAction["cover"] as? String ?? ""
        }

        // 目录规则 chapterList
        var tocRule = SourceTocRule()
        if let chapterAction = dict["chapterList"] as? [String: Any] {
            tocRule.listSelector = chapterAction["list"] as? String ?? ""
            tocRule.nameSelector = chapterAction["title"] as? String ?? ""
            tocRule.urlSelector = (chapterAction["url"] as? String) ?? (chapterAction["detailUrl"] as? String) ?? ""
        }

        // 正文规则 chapterContent
        var contentRule = SourceContentRule()
        if let contentAction = dict["chapterContent"] as? [String: Any] {
            contentRule.contentSelector = contentAction["content"] as? String ?? ""
        }

        // 发现规则 findBook：香色闺阁切换站点后用它渲染频道、筛选和书单
        var exploreRule = SourceExploreRule()
        if let findAction = dict["findBook"] as? [String: Any] {
            if let requestInfo = findAction["requestInfo"] as? String {
                exploreRule.urlTemplate = normalizeExploreTemplate(requestInfo, baseURL: sourceUrl)
            }
            exploreRule.listSelector = findAction["list"] as? String ?? ""
            exploreRule.nameSelector = (findAction["bookName"] as? String) ?? (findAction["title"] as? String) ?? ""
            exploreRule.authorSelector = findAction["author"] as? String ?? ""
            exploreRule.detailURLSelector = (findAction["detailUrl"] as? String) ?? (findAction["url"] as? String) ?? ""
            exploreRule.summarySelector = (findAction["desc"] as? String) ?? (findAction["intro"] as? String) ?? ""
            exploreRule.coverSelector = findAction["cover"] as? String ?? ""
        }

        let rawJSON = (try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""

        return UniversalBookSource(
            kind: .xiangse,
            name: name,
            sourceURL: sourceUrl,
            group: group,
            enabled: enabled,
            weight: weight,
            searchRule: searchRule,
            tocRule: tocRule,
            contentRule: contentRule,
            exploreRule: exploreRule,
            rawJSON: rawJSON
        )
    }

    /// 发现地址经常是多行规则，只补全每一行里的相对链接，避免把整段文本拼到域名后面。
    private static func normalizeExploreTemplate(_ raw: String, baseURL: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") {
            return trimmed
        }
        if trimmed.contains("\n") || trimmed.contains("::") {
            let lines = trimmed.split(whereSeparator: \.isNewline).map { line -> String in
                let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let range = text.range(of: "::") else {
                    return normalizeXiangSeURL(text, baseURL: baseURL)
                }
                let left = String(text[..<range.lowerBound])
                let right = String(text[range.upperBound...])
                if left.contains("://") || left.contains("/") {
                    return normalizeXiangSeURL(text, baseURL: baseURL)
                }
                let segments = right.components(separatedBy: "&&")
                guard var first = segments.first else { return text }
                first = normalizeXiangSeURL(first, baseURL: baseURL)
                var rebuilt = [first]
                rebuilt.append(contentsOf: segments.dropFirst())
                return left + "::" + rebuilt.joined(separator: "&&")
            }
            return lines.joined(separator: "\n")
        }
        return normalizeXiangSeURL(trimmed, baseURL: baseURL)
    }

    private static func normalizeXiangSeURL(_ raw: String, baseURL: String) -> String {
        var str = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 如果是 @js: 代码抽取 url
        if str.contains("@js:") {
            if let urlMatch = str.range(of: #"['"](https?://[^'"]+)['"]"#, options: .regularExpression) {
                str = String(str[urlMatch]).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            }
        }

        // 补全相对路径
        if !str.contains("://") && !baseURL.isEmpty && !str.hasPrefix("%@") {
            let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
            let sub = str.hasPrefix("/") ? str : ("/" + str)
            str = base + sub
        }

        return str
    }

    // MARK: - 解析豆豆标准原生源

    private static func parseDouDou(_ dict: [String: Any]) -> UniversalBookSource? {
        let name = dict["name"] as? String ?? "标准书源"
        let baseURL = dict["baseURL"] as? String ?? ""
        guard !baseURL.isEmpty else { return nil }

        let rawJSON = (try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""

        return UniversalBookSource(
            kind: .doudou,
            name: name,
            sourceURL: baseURL,
            group: "豆豆标准",
            enabled: true,
            weight: 100,
            searchRule: SourceSearchRule(urlTemplate: baseURL + "/search?q={{key}}"),
            rawJSON: rawJSON
        )
    }

    // MARK: - 编码与单条还原

    static func encode(source: UniversalBookSource) throws -> String {
        let data = try JSONEncoder().encode(source)
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeSingleSource(json: String) throws -> UniversalBookSource {
        if let data = json.data(using: .utf8),
           let source = try? JSONDecoder().decode(UniversalBookSource.self, from: data) {
            return source
        }
        let sources = try parse(text: json)
        guard let first = sources.first else {
            throw BookSourceParserError.emptySource
        }
        return first
    }
}
