import Foundation

/// 书源格式类型
enum BookSourceKind: String, Codable, Sendable, CaseIterable {
    case legado = "legado"    // 阅读 3.0 (开源安卓阅读 Legado)
    case xiangse = "xiangse"  // 香色闺阁 (iOS StandarReader)
    case doudou = "doudou"    // 豆豆原生标准接口

    var displayName: String {
        switch self {
        case .legado: "阅读 3.0"
        case .xiangse: "香色闺阁"
        case .doudou: "豆豆标准"
        }
    }

    var badgeColorName: String {
        switch self {
        case .legado: "green"
        case .xiangse: "purple"
        case .doudou: "blue"
        }
    }
}

/// 发现规则。频道和筛选项写在 urlTemplate 里，选择器为空时执行阶段回退到搜索规则。
nonisolated struct SourceExploreRule: Codable, Sendable, Equatable {
    var urlTemplate: String = ""
    var listSelector: String = ""
    var nameSelector: String = ""
    var authorSelector: String = ""
    var detailURLSelector: String = ""
    var summarySelector: String = ""
    var coverSelector: String = ""
    var categorySelector: String = ""
    var statusSelector: String = ""

    nonisolated init(
        urlTemplate: String = "",
        listSelector: String = "",
        nameSelector: String = "",
        authorSelector: String = "",
        detailURLSelector: String = "",
        summarySelector: String = "",
        coverSelector: String = "",
        categorySelector: String = "",
        statusSelector: String = ""
    ) {
        self.urlTemplate = urlTemplate
        self.listSelector = listSelector
        self.nameSelector = nameSelector
        self.authorSelector = authorSelector
        self.detailURLSelector = detailURLSelector
        self.summarySelector = summarySelector
        self.coverSelector = coverSelector
        self.categorySelector = categorySelector
        self.statusSelector = statusSelector
    }

    private enum CodingKeys: String, CodingKey {
        case urlTemplate, listSelector, nameSelector, authorSelector
        case detailURLSelector, summarySelector, coverSelector
        case categorySelector, statusSelector
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        urlTemplate = try container.decodeIfPresent(String.self, forKey: .urlTemplate) ?? ""
        listSelector = try container.decodeIfPresent(String.self, forKey: .listSelector) ?? ""
        nameSelector = try container.decodeIfPresent(String.self, forKey: .nameSelector) ?? ""
        authorSelector = try container.decodeIfPresent(String.self, forKey: .authorSelector) ?? ""
        detailURLSelector = try container.decodeIfPresent(String.self, forKey: .detailURLSelector) ?? ""
        summarySelector = try container.decodeIfPresent(String.self, forKey: .summarySelector) ?? ""
        coverSelector = try container.decodeIfPresent(String.self, forKey: .coverSelector) ?? ""
        categorySelector = try container.decodeIfPresent(String.self, forKey: .categorySelector) ?? ""
        statusSelector = try container.decodeIfPresent(String.self, forKey: .statusSelector) ?? ""
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(urlTemplate, forKey: .urlTemplate)
        try container.encode(listSelector, forKey: .listSelector)
        try container.encode(nameSelector, forKey: .nameSelector)
        try container.encode(authorSelector, forKey: .authorSelector)
        try container.encode(detailURLSelector, forKey: .detailURLSelector)
        try container.encode(summarySelector, forKey: .summarySelector)
        try container.encode(coverSelector, forKey: .coverSelector)
        try container.encode(categorySelector, forKey: .categorySelector)
        try container.encode(statusSelector, forKey: .statusSelector)
    }
}

/// 统一的书源模型，抽象“阅读 3.0”、“香色闺阁”和“豆豆标准源”
nonisolated struct UniversalBookSource: Identifiable, Codable, Sendable, Equatable {
    var id: String
    var kind: BookSourceKind
    var name: String
    var sourceURL: String
    var group: String
    var enabled: Bool
    var weight: Int

    // 搜索规则
    var searchRule: SourceSearchRule
    // 目录与书籍详情规则
    var tocRule: SourceTocRule
    // 正文提取规则
    var contentRule: SourceContentRule
    // 发现规则（香色闺阁切换站点后的频道、筛选与书单）
    var exploreRule: SourceExploreRule

    // 原始 JSON 配置（用于持久化与调试）
    var rawJSON: String

    nonisolated init(
        id: String = UUID().uuidString,
        kind: BookSourceKind,
        name: String,
        sourceURL: String,
        group: String = "",
        enabled: Bool = true,
        weight: Int = 100,
        searchRule: SourceSearchRule = SourceSearchRule(),
        tocRule: SourceTocRule = SourceTocRule(),
        contentRule: SourceContentRule = SourceContentRule(),
        exploreRule: SourceExploreRule = SourceExploreRule(),
        rawJSON: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.sourceURL = sourceURL
        self.group = group
        self.enabled = enabled
        self.weight = weight
        self.searchRule = searchRule
        self.tocRule = tocRule
        self.contentRule = contentRule
        self.exploreRule = exploreRule
        self.rawJSON = rawJSON
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, sourceURL, group, enabled, weight
        case searchRule, tocRule, contentRule, exploreRule, rawJSON
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = try container.decode(BookSourceKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        sourceURL = try container.decode(String.self, forKey: .sourceURL)
        group = try container.decodeIfPresent(String.self, forKey: .group) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        weight = try container.decodeIfPresent(Int.self, forKey: .weight) ?? 100
        searchRule = try container.decodeIfPresent(SourceSearchRule.self, forKey: .searchRule) ?? SourceSearchRule()
        tocRule = try container.decodeIfPresent(SourceTocRule.self, forKey: .tocRule) ?? SourceTocRule()
        contentRule = try container.decodeIfPresent(SourceContentRule.self, forKey: .contentRule) ?? SourceContentRule()
        exploreRule = try container.decodeIfPresent(SourceExploreRule.self, forKey: .exploreRule) ?? SourceExploreRule()
        rawJSON = try container.decodeIfPresent(String.self, forKey: .rawJSON) ?? ""
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(sourceURL, forKey: .sourceURL)
        try container.encode(group, forKey: .group)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(weight, forKey: .weight)
        try container.encode(searchRule, forKey: .searchRule)
        try container.encode(tocRule, forKey: .tocRule)
        try container.encode(contentRule, forKey: .contentRule)
        try container.encode(exploreRule, forKey: .exploreRule)
        try container.encode(rawJSON, forKey: .rawJSON)
    }
}

/// 搜索规则
nonisolated struct SourceSearchRule: Codable, Sendable, Equatable {
    /// 搜索请求地址模板，例如 "https://example.com/search?q={{key}}" 或 "...?word=%@keyWord"
    var urlTemplate: String = ""
    /// 请求方式：GET 或 POST
    var httpMethod: String = "GET"
    /// POST Body 模板（若为 POST）
    var postBody: String? = nil
    /// 请求头信息
    var headers: [String: String] = [:]

    /// 搜索结果列表选择器（CSS/XPath/JSONPath）
    var listSelector: String = ""
    /// 书名选择器
    var nameSelector: String = ""
    /// 作者选择器
    var authorSelector: String = ""
    /// 详情页/书籍 URL 选择器
    var detailURLSelector: String = ""
    /// 简介选择器
    var summarySelector: String = ""
    /// 封面图选择器
    var coverSelector: String = ""
    /// 搜索结果里的最新章节（阅读 3.0 的 lastChapter，香色闺阁的 lastChapter）。
    var lastChapterSelector: String = ""
    /// 分类选择器（阅读 3.0 的 kind，香色闺阁的 cat/category）。
    var categorySelector: String = ""
    /// 连载状态选择器（香色闺阁的 status）。
    var statusSelector: String = ""

    nonisolated init(
        urlTemplate: String = "",
        httpMethod: String = "GET",
        postBody: String? = nil,
        headers: [String: String] = [:],
        listSelector: String = "",
        nameSelector: String = "",
        authorSelector: String = "",
        detailURLSelector: String = "",
        summarySelector: String = "",
        coverSelector: String = "",
        lastChapterSelector: String = "",
        categorySelector: String = "",
        statusSelector: String = ""
    ) {
        self.urlTemplate = urlTemplate
        self.httpMethod = httpMethod
        self.postBody = postBody
        self.headers = headers
        self.listSelector = listSelector
        self.nameSelector = nameSelector
        self.authorSelector = authorSelector
        self.detailURLSelector = detailURLSelector
        self.summarySelector = summarySelector
        self.coverSelector = coverSelector
        self.lastChapterSelector = lastChapterSelector
        self.categorySelector = categorySelector
        self.statusSelector = statusSelector
    }

    private enum CodingKeys: String, CodingKey {
        case urlTemplate, httpMethod, postBody, headers
        case listSelector, nameSelector, authorSelector, detailURLSelector
        case summarySelector, coverSelector, lastChapterSelector
        case categorySelector, statusSelector
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        urlTemplate = try container.decodeIfPresent(String.self, forKey: .urlTemplate) ?? ""
        httpMethod = try container.decodeIfPresent(String.self, forKey: .httpMethod) ?? "GET"
        postBody = try container.decodeIfPresent(String.self, forKey: .postBody)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        listSelector = try container.decodeIfPresent(String.self, forKey: .listSelector) ?? ""
        nameSelector = try container.decodeIfPresent(String.self, forKey: .nameSelector) ?? ""
        authorSelector = try container.decodeIfPresent(String.self, forKey: .authorSelector) ?? ""
        detailURLSelector = try container.decodeIfPresent(String.self, forKey: .detailURLSelector) ?? ""
        summarySelector = try container.decodeIfPresent(String.self, forKey: .summarySelector) ?? ""
        coverSelector = try container.decodeIfPresent(String.self, forKey: .coverSelector) ?? ""
        lastChapterSelector = try container.decodeIfPresent(String.self, forKey: .lastChapterSelector) ?? ""
        categorySelector = try container.decodeIfPresent(String.self, forKey: .categorySelector) ?? ""
        statusSelector = try container.decodeIfPresent(String.self, forKey: .statusSelector) ?? ""
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(urlTemplate, forKey: .urlTemplate)
        try container.encode(httpMethod, forKey: .httpMethod)
        try container.encodeIfPresent(postBody, forKey: .postBody)
        try container.encode(headers, forKey: .headers)
        try container.encode(listSelector, forKey: .listSelector)
        try container.encode(nameSelector, forKey: .nameSelector)
        try container.encode(authorSelector, forKey: .authorSelector)
        try container.encode(detailURLSelector, forKey: .detailURLSelector)
        try container.encode(summarySelector, forKey: .summarySelector)
        try container.encode(coverSelector, forKey: .coverSelector)
        try container.encode(lastChapterSelector, forKey: .lastChapterSelector)
        try container.encode(categorySelector, forKey: .categorySelector)
        try container.encode(statusSelector, forKey: .statusSelector)
    }
}

/// 目录与详情规则
nonisolated struct SourceTocRule: Codable, Sendable, Equatable {
    /// 详情页到目录页的跳转链接（如果目录页单独存在）
    var tocURLSelector: String = ""
    /// 章节列表选择器
    var listSelector: String = ""
    /// 章节名称选择器
    var nameSelector: String = ""
    /// 章节正文地址选择器
    var urlSelector: String = ""
    /// 目录最前面是最新章节横幅时，从第一次出现的第1章接着读，并把横幅里多出来的章补到末尾。
    var startAtFirstChapter: Bool = false
    /// 详情页书名选择器（来自 ruleBookInfo.name 或 bookDetail.bookName），为空时回退硬编码 //h1。
    var infoNameSelector: String = ""
    /// 详情页作者选择器（来自 ruleBookInfo.author 或 bookDetail.author），为空时回退硬编码 //span[@class='author']。
    var infoAuthorSelector: String = ""
    /// 详情页封面选择器（来自 ruleBookInfo.coverUrl 或 bookDetail.cover）。
    var infoCoverSelector: String = ""
    /// 详情页 URL 模板（香色 bookDetail.requestInfo 规范化后的结果）。搜索结果只给出纯书号时用它拼装详情页地址。
    var detailRequestTemplate: String = ""

    nonisolated init(
        tocURLSelector: String = "",
        listSelector: String = "",
        nameSelector: String = "",
        urlSelector: String = "",
        startAtFirstChapter: Bool = false,
        infoNameSelector: String = "",
        infoAuthorSelector: String = "",
        infoCoverSelector: String = "",
        detailRequestTemplate: String = ""
    ) {
        self.tocURLSelector = tocURLSelector
        self.listSelector = listSelector
        self.nameSelector = nameSelector
        self.urlSelector = urlSelector
        self.startAtFirstChapter = startAtFirstChapter
        self.infoNameSelector = infoNameSelector
        self.infoAuthorSelector = infoAuthorSelector
        self.infoCoverSelector = infoCoverSelector
        self.detailRequestTemplate = detailRequestTemplate
    }

    private enum CodingKeys: String, CodingKey {
        case tocURLSelector, listSelector, nameSelector, urlSelector, startAtFirstChapter
        case infoNameSelector, infoAuthorSelector, infoCoverSelector
        case detailRequestTemplate
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tocURLSelector = try container.decodeIfPresent(String.self, forKey: .tocURLSelector) ?? ""
        listSelector = try container.decodeIfPresent(String.self, forKey: .listSelector) ?? ""
        nameSelector = try container.decodeIfPresent(String.self, forKey: .nameSelector) ?? ""
        urlSelector = try container.decodeIfPresent(String.self, forKey: .urlSelector) ?? ""
        startAtFirstChapter = try container.decodeIfPresent(Bool.self, forKey: .startAtFirstChapter) ?? false
        infoNameSelector = try container.decodeIfPresent(String.self, forKey: .infoNameSelector) ?? ""
        infoAuthorSelector = try container.decodeIfPresent(String.self, forKey: .infoAuthorSelector) ?? ""
        infoCoverSelector = try container.decodeIfPresent(String.self, forKey: .infoCoverSelector) ?? ""
        detailRequestTemplate = try container.decodeIfPresent(String.self, forKey: .detailRequestTemplate) ?? ""
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tocURLSelector, forKey: .tocURLSelector)
        try container.encode(listSelector, forKey: .listSelector)
        try container.encode(nameSelector, forKey: .nameSelector)
        try container.encode(urlSelector, forKey: .urlSelector)
        try container.encode(startAtFirstChapter, forKey: .startAtFirstChapter)
        try container.encode(infoNameSelector, forKey: .infoNameSelector)
        try container.encode(infoAuthorSelector, forKey: .infoAuthorSelector)
        try container.encode(infoCoverSelector, forKey: .infoCoverSelector)
        try container.encode(detailRequestTemplate, forKey: .detailRequestTemplate)
    }
}

/// 正文提取规则
nonisolated struct SourceContentRule: Codable, Sendable, Equatable {
    /// 正文内容选择器
    var contentSelector: String = ""
    /// 正文清洗规则（正则表达式替换，如 "##广告##"）
    var replaceRules: [String] = []
    /// 章节内分页的下一页链接选择器，为空时由启发式识别「下一页」。
    var nextContentURLSelector: String = ""

    nonisolated init(
        contentSelector: String = "",
        replaceRules: [String] = [],
        nextContentURLSelector: String = ""
    ) {
        self.contentSelector = contentSelector
        self.replaceRules = replaceRules
        self.nextContentURLSelector = nextContentURLSelector
    }

    private enum CodingKeys: String, CodingKey {
        case contentSelector, replaceRules, nextContentURLSelector
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contentSelector = try container.decodeIfPresent(String.self, forKey: .contentSelector) ?? ""
        replaceRules = try container.decodeIfPresent([String].self, forKey: .replaceRules) ?? []
        nextContentURLSelector = try container.decodeIfPresent(String.self, forKey: .nextContentURLSelector) ?? ""
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contentSelector, forKey: .contentSelector)
        try container.encode(replaceRules, forKey: .replaceRules)
        try container.encode(nextContentURLSelector, forKey: .nextContentURLSelector)
    }
}
