import Foundation

/// 预设书源条目模型
nonisolated struct PresetBookSourceItem: Identifiable, Sendable {
    var id: String
    var name: String
    var icon: String
    var kind: BookSourceKind
    var group: String
    var summary: String
    var sourceURL: String
    var note: String
    var source: UniversalBookSource

    init(
        id: String,
        name: String,
        icon: String = "📄",
        kind: BookSourceKind,
        group: String,
        summary: String,
        sourceURL: String,
        note: String = "",
        source: UniversalBookSource
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.kind = kind
        self.group = group
        self.summary = summary
        self.sourceURL = sourceURL
        self.note = note
        var s = source
        if s.rawJSON.isEmpty {
            s.rawJSON = (try? BookSourceParser.encode(source: s)) ?? ""
        }
        self.source = s
    }

    var fullDisplayName: String {
        var res = ""
        if !icon.isEmpty { res += "\(icon) " }
        res += name
        if !note.isEmpty { res += " \(note)" }
        return res
    }
}

/// 常用精选预设书源库（阅读 3.0 与香色闺阁热门书源）
enum PresetBookSources {
    /// 10 个对照过线上页面的预设书源。发现列表、目录和至少一章正文都能从 HTML 里解析出来。
    static let all: [PresetBookSourceItem] = {
        var items = verifiedPresets()
        for index in items.indices {
            if items[index].source.exploreRule.urlTemplate.isEmpty {
                items[index].source.exploreRule = exploreRule(for: items[index])
            }
            items[index].source.rawJSON = (try? BookSourceParser.encode(source: items[index].source)) ?? items[index].source.rawJSON
        }
        return items
    }()

    /// 这些站点的首页或分类页能列出书，书籍页能进到章节正文。
    private static func verifiedPresets() -> [PresetBookSourceItem] {
        [
            xiangshuPreset(),
            catalogPreset(
                id: "preset-bijian",
                name: "笔尖中文",
                summary: "笔趣阁模板书库，玄幻修真都市分类和章节正文都在页面 HTML 里。",
                sourceURL: "http://www.xbiquwk.com",
                categories: [
                    ("玄幻小说", "/list/1_1.html"),
                    ("修真小说", "/list/2_1.html"),
                    ("都市小说", "/list/3_1.html"),
                    ("穿越小说", "/list/4_1.html"),
                    ("网游小说", "/list/5_1.html"),
                    ("科幻小说", "/list/6_1.html")
                ],
                weight: 9700
            ),
            catalogPreset(
                id: "preset-mengshu",
                name: "梦书中文",
                summary: "梦书中文的最近更新和分类页能列出书名作者，正文在章节页的内容区。",
                sourceURL: "http://www.mcxs.la",
                categories: [
                    ("玄幻奇幻", "/xuanhuanxiaoshuo/"),
                    ("修真仙侠", "/xiuzhenxiaoshuo/"),
                    ("都市青春", "/dushixiaoshuo/"),
                    ("历史穿越", "/chuanyuexiaoshuo/"),
                    ("网游竞技", "/wangyouxiaoshuo/"),
                    ("科幻灵异", "/kehuanxiaoshuo/"),
                    ("其它小说", "/qitaxiaoshuo/")
                ],
                weight: 9600
            ),
            catalogPreset(
                id: "preset-niaoshu",
                name: "鸟书网",
                summary: "鸟书网分类页用更新列表给出书名和作者，章节正文在内容区。",
                sourceURL: "http://www.99wx.info",
                categories: [
                    ("玄幻", "/type/1.html"),
                    ("武侠", "/type/2.html"),
                    ("都市", "/type/3.html"),
                    ("历史", "/type/4.html"),
                    ("科幻", "/type/5.html"),
                    ("网游", "/type/6.html"),
                    ("女生", "/type/7.html"),
                    ("全本", "/type/0.html")
                ],
                weight: 9500
            ),
            yeuduPreset(),
            biqu365Preset(),
            quanbenPreset(),
            ujxswPreset(),
            catalogPreset(
                id: "preset-b5200",
                name: "笔趣阁5200",
                summary: "新笔趣阁 5200，页面是 GBK。分类列表和章节正文都能直接解析。",
                sourceURL: "http://www.b5200.net",
                categories: [
                    ("玄幻小说", "/xuanhuanxiaoshuo/"),
                    ("修真小说", "/xiuzhenxiaoshuo/"),
                    ("都市小说", "/dushixiaoshuo/"),
                    ("穿越小说", "/chuanyuexiaoshuo/"),
                    ("网游小说", "/wangyouxiaoshuo/"),
                    ("科幻小说", "/kehuanxiaoshuo/"),
                    ("言情小说", "/yanqingxiaoshuo/"),
                    ("同人小说", "/tongrenxiaoshuo/")
                ],
                weight: 9000,
                charsetGBK: true
            ),
            catalogPreset(
                id: "preset-shuqu",
                name: "书趣阁",
                summary: "书趣阁手机站现在在 xshuquge.net，强推和分类列表都能解析到书。",
                sourceURL: "http://www.xshuquge.net",
                categories: [
                    ("玄幻", "/category/1_1.html"),
                    ("武侠", "/category/2_1.html"),
                    ("都市", "/category/3_1.html"),
                    ("历史", "/category/4_1.html"),
                    ("侦探", "/category/5_1.html"),
                    ("网游", "/category/6_1.html"),
                    ("科幻", "/category/7_1.html")
                ],
                weight: 8900
            )
        ]
    }

    /// 香书小说。规则写成香色闺阁的 XPath，页面结构和下面几家笔趣阁相同。
    private static func xiangshuPreset() -> PresetBookSourceItem {
        let base = "http://www.ibiqugu.net"
        let categories = [
            ("玄幻小说", "/xuanhuanxiaoshuo/"),
            ("修真小说", "/xiuzhenxiaoshuo/"),
            ("都市小说", "/dushixiaoshuo/"),
            ("穿越小说", "/chuanyuexiaoshuo/"),
            ("网游小说", "/wangyouxiaoshuo/"),
            ("科幻小说", "/kehuanxiaoshuo/")
        ]
        var lines = ["最新::\(base)/"]
        for (title, path) in categories {
            lines.append("\(title)::\(base)\(path)")
        }
        let list = "//div[@class='l']//li||//ul[@class='lis']//li"
        let name = "//span[@class='s2']/a/text()"
        let author = "//span[@class='s4']/text()||//span[@class='s5']/text()"
        let detail = "//span[@class='s2']/a/@href"
        return makePreset(
            id: "preset-xiangshu",
            name: "香书小说",
            kind: .xiangse,
            summary: "香书小说，原笔趣阁域名会跳到这里。更新列表和章节正文都在 HTML 里。",
            sourceURL: base,
            weight: 9800,
            search: SourceSearchRule(
                urlTemplate: "\(base)/?keyword={{key}}",
                listSelector: "//div[@id='searchresult']//li",
                nameSelector: name,
                authorSelector: author,
                detailURLSelector: detail
            ),
            toc: SourceTocRule(
                listSelector: "//div[@id='list']//dd/a",
                nameSelector: "text",
                urlSelector: "href"
            ),
            content: SourceContentRule(contentSelector: "//div[@id='content']/text()"),
            explore: SourceExploreRule(
                urlTemplate: lines.joined(separator: "\n"),
                listSelector: list,
                nameSelector: name,
                authorSelector: author,
                detailURLSelector: detail
            )
        )
    }

    /// 笔趣阁一类站点：左栏或分类页是 `div.l li`，强推是 `ul.lis`，作者在 s4 或 s5。
    private static func catalogPreset(
        id: String,
        name: String,
        summary: String,
        sourceURL: String,
        categories: [(String, String)],
        weight: Int,
        charsetGBK: Bool = false
    ) -> PresetBookSourceItem {
        let base = sourceURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var lines = ["最新::\(base)/"]
        for (title, path) in categories {
            lines.append("\(title)::\(base)\(path)")
        }
        let list = "div.l li, ul.lis li"
        let bookName = ".s2 a@text"
        let author = ".s4@text, .s5@text"
        let detail = ".s2 a@href"
        var searchURL = "\(base)/?keyword={{key}}"
        if charsetGBK {
            searchURL += ",{\"charset\":\"gbk\"}"
        }
        return makePreset(
            id: id,
            name: name,
            kind: .legado,
            summary: summary,
            sourceURL: base,
            weight: weight,
            search: SourceSearchRule(
                urlTemplate: searchURL,
                listSelector: ".search-list li",
                nameSelector: bookName,
                authorSelector: author,
                detailURLSelector: detail
            ),
            toc: SourceTocRule(
                listSelector: "#list dd a, .listmain dd a",
                nameSelector: "text",
                urlSelector: "href"
            ),
            content: SourceContentRule(contentSelector: "#content@text"),
            explore: SourceExploreRule(
                urlTemplate: lines.joined(separator: "\n"),
                listSelector: list,
                nameSelector: bookName,
                authorSelector: author,
                detailURLSelector: detail
            )
        )
    }

    private static func yeuduPreset() -> PresetBookSourceItem {
        let base = "http://www.yeudusk.com"
        let categories = [
            ("玄幻魔法", "/book/sort1/0/1.html"),
            ("武侠修真", "/book/sort2/0/1.html"),
            ("都市言情", "/book/sort3/0/1.html"),
            ("历史军事", "/book/sort4/0/1.html"),
            ("穿越架空", "/book/sort5/0/1.html"),
            ("游戏竞技", "/book/sort6/0/1.html")
        ]
        var lines = ["热门::\(base)/"]
        for (title, path) in categories {
            lines.append("\(title)::\(base)\(path)")
        }
        let list = "li.recommend-item, div.c_subject"
        let bookName = "a.ends@text, a[1]@text"
        let detail = "a.ends@href, a.note@href"
        return makePreset(
            id: "preset-yeudu",
            name: "阅读库",
            kind: .legado,
            summary: "阅读库首页是排行书卡，分类页书名旁边的目录链接能进到章节列表。",
            sourceURL: base,
            weight: 9400,
            search: SourceSearchRule(
                urlTemplate: "\(base)/?keyword={{key}}",
                listSelector: ".search-list li",
                nameSelector: bookName,
                authorSelector: ".author@text",
                detailURLSelector: detail
            ),
            toc: SourceTocRule(
                listSelector: "li.chapter a",
                nameSelector: "text",
                urlSelector: "href"
            ),
            content: SourceContentRule(contentSelector: "#content@text"),
            explore: SourceExploreRule(
                urlTemplate: lines.joined(separator: "\n"),
                listSelector: list,
                nameSelector: bookName,
                authorSelector: ".author@text",
                detailURLSelector: detail
            )
        )
    }

    private static func biqu365Preset() -> PresetBookSourceItem {
        let base = "https://www.biquge365.net"
        let categories = [
            ("玄幻魔法", "/sort/1_1/"),
            ("仙侠修真", "/sort/2_1/"),
            ("都市言情", "/sort/3_1/"),
            ("网游动漫", "/sort/4_1/"),
            ("科幻小说", "/sort/5_1/"),
            ("恐怖灵异", "/sort/6_1/"),
            ("历史军事", "/sort/7_1/"),
            ("其他小说", "/sort/8_1/")
        ]
        var lines = ["最新::\(base)/"]
        for (title, path) in categories {
            lines.append("\(title)::\(base)\(path)")
        }
        let list = "ul.gengxin li, ul.search li"
        let bookName = "span.name a@text"
        let detail = "span.name a@href"
        return makePreset(
            id: "preset-biqu365",
            name: "笔趣阁365",
            kind: .legado,
            summary: "笔趣阁365 的更新列表和搜索结果都有书名。正文按页拆开，先读到第一页。",
            sourceURL: base,
            weight: 9300,
            search: SourceSearchRule(
                urlTemplate: "\(base)/s.php,{\"method\":\"POST\",\"body\":\"type=articlename&s={{key}}\"}",
                httpMethod: "POST",
                listSelector: list,
                nameSelector: bookName,
                detailURLSelector: detail
            ),
            toc: SourceTocRule(
                tocURLSelector: "div.gongneng a@href",
                listSelector: "div.info li a",
                nameSelector: "text",
                urlSelector: "href"
            ),
            content: SourceContentRule(contentSelector: "#txt@text"),
            explore: SourceExploreRule(
                urlTemplate: lines.joined(separator: "\n"),
                listSelector: list,
                nameSelector: bookName,
                detailURLSelector: detail
            )
        )
    }

    private static func quanbenPreset() -> PresetBookSourceItem {
        let base = "https://quanben5.com"
        let categories = [
            ("玄幻", "/category/1.html"),
            ("都市", "/category/2.html"),
            ("仙侠", "/category/3.html"),
            ("武侠", "/category/4.html"),
            ("言情", "/category/5.html"),
            ("穿越", "/category/6.html"),
            ("网游", "/category/7.html"),
            ("奇幻", "/category/8.html"),
            ("科幻", "/category/9.html"),
            ("悬疑", "/category/10.html"),
            ("历史", "/category/14.html"),
            ("军事", "/category/13.html")
        ]
        var lines = ["热门::\(base)/"]
        for (title, path) in categories {
            lines.append("\(title)::\(base)\(path)")
        }
        let list = "ul.list2 li, div.pic_txt_list, ul.list li"
        let bookName = "h3 span@text, a span@text, a@text"
        let author = "span.author@text, p.info@text##作者[:：]\\s*##"
        let detail = "h3 a@href, a@href"
        return makePreset(
            id: "preset-quanben5",
            name: "全本小说网",
            kind: .legado,
            summary: "全本小说网首页和分类页都能列出书。点进书籍后从「点击阅读」进入章节。",
            sourceURL: base,
            weight: 9200,
            search: SourceSearchRule(
                urlTemplate: "\(base)/search.html?keyword={{key}}",
                listSelector: ".search-list li",
                nameSelector: bookName,
                authorSelector: author,
                detailURLSelector: detail
            ),
            toc: SourceTocRule(
                tocURLSelector: "a.s1@href",
                listSelector: "li.c3 a",
                nameSelector: "text",
                urlSelector: "href"
            ),
            content: SourceContentRule(contentSelector: "#content@text"),
            explore: SourceExploreRule(
                urlTemplate: lines.joined(separator: "\n"),
                listSelector: list,
                nameSelector: bookName,
                authorSelector: author,
                detailURLSelector: detail
            )
        )
    }

    private static func ujxswPreset() -> PresetBookSourceItem {
        let base = "http://www.ujxsw.org"
        let categories = [
            ("玄幻奇幻", "/xuanhuan/"),
            ("仙侠修真", "/wuxia/"),
            ("都市青春", "/dushi/"),
            ("历史军事", "/lishi/"),
            ("游戏动漫", "/youxi/"),
            ("科幻灵异", "/kehuan/"),
            ("女生言情", "/yanqing/")
        ]
        var lines = ["热门::\(base)/"]
        for (title, path) in categories {
            lines.append("\(title)::\(base)\(path)")
        }
        return makePreset(
            id: "preset-ujxsw",
            name: "悠久小说网",
            kind: .legado,
            summary: "悠久小说网首页和分类是书卡。目录在单独的阅读列表页，正文在章节页。",
            sourceURL: base,
            weight: 9100,
            search: SourceSearchRule(
                urlTemplate: "\(base)/?keyword={{key}}",
                listSelector: ".search-list li",
                nameSelector: "dd a@text",
                authorSelector: "dd.tit@text##^作者[:：]##",
                detailURLSelector: "dd a@href"
            ),
            toc: SourceTocRule(
                tocURLSelector: "a.tgcj@href",
                listSelector: "#readerlist a",
                nameSelector: "text",
                urlSelector: "href"
            ),
            content: SourceContentRule(contentSelector: "#mlfy_main_text@text"),
            explore: SourceExploreRule(
                urlTemplate: lines.joined(separator: "\n"),
                listSelector: "dl",
                nameSelector: "dd a@text",
                authorSelector: "dd.tit@text##^作者[:：]##",
                detailURLSelector: "dd a@href"
            )
        )
    }

    private static func makePreset(
        id: String,
        name: String,
        kind: BookSourceKind,
        summary: String,
        sourceURL: String,
        weight: Int,
        search: SourceSearchRule,
        toc: SourceTocRule,
        content: SourceContentRule,
        explore: SourceExploreRule
    ) -> PresetBookSourceItem {
        let source = UniversalBookSource(
            id: id,
            kind: kind,
            name: name,
            sourceURL: sourceURL,
            group: "综合精选",
            enabled: true,
            weight: weight,
            searchRule: search,
            tocRule: toc,
            contentRule: content,
            exploreRule: explore
        )
        return PresetBookSourceItem(
            id: id,
            name: name,
            kind: kind,
            group: "综合精选",
            summary: summary,
            sourceURL: sourceURL,
            source: source
        )
    }

    /// 参考香色闺阁：每个切换项绑定自己的主机和发现规则。解析不到书的站点不再放进来。
    static var screenshotSites: [SiteCatalogEntry] {
        var list: [SiteCatalogEntry] = []
        func add(
            _ id: String,
            _ name: String,
            _ host: String,
            _ group: String,
            icon: String = "",
            note: String = ""
        ) {
            list.append(SiteCatalogEntry(
                id: id,
                name: name,
                icon: icon,
                note: note,
                group: group,
                host: host,
                source: nil
            ))
        }

        add("preset-xiangshu", "香书小说", "www.ibiqugu.net", "文本/小说")
        add("preset-bijian", "笔尖中文", "www.xbiquwk.com", "文本/小说")
        add("preset-mengshu", "梦书中文", "www.mcxs.la", "文本/小说")
        add("preset-niaoshu", "鸟书网", "www.99wx.info", "文本/小说")
        add("preset-yeudu", "阅读库", "www.yeudusk.com", "文本/小说")
        add("preset-biqu365", "笔趣阁365", "www.biquge365.net", "文本/小说")
        add("preset-quanben5", "全本小说网", "quanben5.com", "文本/小说")
        add("preset-ujxsw", "悠久小说网", "www.ujxsw.org", "文本/小说")
        add("preset-b5200", "笔趣阁5200", "www.b5200.net", "文本/小说")
        add("preset-shuqu", "书趣阁", "www.xshuquge.net", "文本/小说")

        add("site-zongheng", "纵横中文网", "www.zongheng.com", "TOP", icon: "🦁", note: "(索引源,QQ频道:香色闺阁)")
        add("site-shuqi", "书旗小说", "www.shuqi.com", "文本/小说", note: "(只用于看榜单)")
        add("site-feilu", "飞卢小说网", "wap.faloo.com", "文本/小说", note: "wap(©)")
        add("preset-69shuba", "69 书吧", "www.69shuba.com", "文本/小说", icon: "❤️❤️❤️", note: "(需要翻墙)")
        add("preset-wucuo", "无错小说网", "www.wucuoxs.com", "文本/小说", icon: "☯️", note: "(电脑版)")
        add("site-penguin", "企鹅小说", "www.qiexs.com", "文本/小说", icon: "〽️")
        add("site-jiujiu", "久久小说网", "www.jjxsw.com", "文本/小说", note: "(纯情大叔)")

        return list.map { entry in
            var copy = entry
            let presetID = entry.id.hasPrefix("preset-") ? entry.id : nil
            copy.source = ownedSource(
                id: entry.id,
                name: entry.name,
                group: entry.group,
                host: entry.host,
                presetID: presetID
            )
            return copy
        }
    }


    private static func hostKey(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") {
            text = "https://" + text
        }
        let host = URL(string: text)?.host?.lowercased() ?? ""
        if host.hasPrefix("www.") {
            return String(host.dropFirst(4))
        }
        return host
    }

    /// 把搜索选择器复制到发现规则，保证分类页和搜索页用同一套解析。
    private static func exploreRule(for item: PresetBookSourceItem) -> SourceExploreRule {
        let search = item.source.searchRule
        let base = item.source.sourceURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let template = """
        热门::\(base)/
        最新::\(base)/lastupdate/{{page}}.html
        """
        return SourceExploreRule(
            urlTemplate: template,
            listSelector: search.listSelector,
            nameSelector: search.nameSelector,
            authorSelector: search.authorSelector,
            detailURLSelector: search.detailURLSelector,
            summarySelector: search.summarySelector,
            coverSelector: search.coverSelector
        )
    }

    /// 主机对得上预设源时沿用它的规则；否则按该站点自己的域名单独建源。
    private static func ownedSource(
        id: String,
        name: String,
        group: String,
        host: String,
        presetID: String?
    ) -> UniversalBookSource {
        let normalizedHost = hostKey(host)
        if let custom = customSource(id: id, name: name, group: group, host: normalizedHost) {
            return custom
        }
        if let presetID,
           let preset = all.first(where: { $0.id == presetID }),
           hostKey(preset.source.sourceURL) == normalizedHost {
            var source = preset.source
            source.id = id
            source.name = name
            source.group = group
            if source.exploreRule.urlTemplate.isEmpty {
                source.exploreRule = exploreRule(for: preset)
            }
            return source
        }

        let base = "https://\(host)"
        let searchURL = "\(base)/search?keyword={{key}}"
        let list = ".book-item, .item, .search-list li, tr"
        let nameSelector = "a@text"
        let authorSelector = ".author@text, .writer@text"
        let detailSelector = "a@href"
        let summarySelector = ".desc@text, .intro@text, p@text"
        let explore = """
        热门::\(base)/
        最新::\(base)/lastupdate/{{page}}.html
        """
        return UniversalBookSource(
            id: id,
            kind: .legado,
            name: name,
            sourceURL: base,
            group: group,
            enabled: true,
            searchRule: SourceSearchRule(
                urlTemplate: searchURL,
                listSelector: list,
                nameSelector: nameSelector,
                authorSelector: authorSelector,
                detailURLSelector: detailSelector,
                summarySelector: summarySelector
            ),
            tocRule: SourceTocRule(
                listSelector: ".chapter-list a, #list a, .catalog a, #chapters a",
                nameSelector: "text",
                urlSelector: "href"
            ),
            contentRule: SourceContentRule(
                contentSelector: "#content@text, .content@text, .chapter-content@text"
            ),
            exploreRule: SourceExploreRule(
                urlTemplate: explore,
                listSelector: list,
                nameSelector: nameSelector,
                authorSelector: authorSelector,
                detailURLSelector: detailSelector,
                summarySelector: summarySelector
            )
        )
    }

    /// 这些站点的页面结构和预设源对不上，按抓到的 HTML 单独写规则。
    private static func customSource(
        id: String,
        name: String,
        group: String,
        host: String
    ) -> UniversalBookSource? {
        if host == "qiexs.com" || host == "qiexs.cc" || host.hasSuffix(".qiexs.com") || host.hasSuffix(".qiexs.cc") {
            return qiexsSource(id: id, name: name, group: group)
        }
        if host == "faloo.com" || host.hasSuffix(".faloo.com") {
            return falooSource(id: id, name: name, group: group)
        }
        if host == "wucuoxs.com" || host.hasSuffix(".wucuoxs.com") {
            return wucuoSource(id: id, name: name, group: group)
        }
        if host == "jjxsw.com" || host == "ijjxsxzw.com" || host == "ijjxsw.com" || host.hasSuffix(".ijjxsxzw.com") {
            return jiujiuSource(id: id, name: name, group: group)
        }
        if host == "zongheng.com" || host.hasSuffix(".zongheng.com") {
            return zonghengSource(id: id, name: name, group: group)
        }
        if host == "shuqi.com" || host.hasSuffix(".shuqi.com") {
            return shuqiSource(id: id, name: name, group: group)
        }
        if host == "69shuba.com" || host.hasSuffix(".69shuba.com") {
            return shubaSource(id: id, name: name, group: group)
        }
        return nil
    }

    /// 飞卢手机站。首页书名在 `.novelName`，分类和搜索在 `.nl_r1`。链接是 `//wap.faloo.com/...`。
    private static func falooSource(id: String, name: String, group: String) -> UniversalBookSource {
        let base = "https://wap.faloo.com"
        let categories = [
            ("小说书库", "y_0_0_0_0_0_0"),
            ("都市生活", "y_4_14_0_0_0_0"),
            ("动漫同人", "y_44_69_0_0_0_0"),
            ("战争幻想", "y_3_76_0_0_0_0"),
            ("虚拟网游", "y_2_33_0_0_0_0"),
            ("传统武侠", "y_6_26_0_0_0_0"),
            ("星际科幻", "y_2_102_0_0_0_0"),
            ("影视同人", "y_44_52_0_0_0_0"),
            ("穿越时空", "y_3_71_0_0_0_0"),
            ("都市异能", "y_4_45_0_0_0_0"),
            ("架空历史", "y_3_19_0_0_0_0"),
            ("免费小说", "y_0_0_0_0_6_0")
        ]
        var lines = ["热门::\(base)/"]
        for (title, path) in categories {
            lines.append("\(title)::\(base)/\(path).html")
        }
        return UniversalBookSource(
            id: id,
            kind: .legado,
            name: name,
            sourceURL: base,
            group: group,
            enabled: true,
            searchRule: SourceSearchRule(
                urlTemplate: "\(base)/search_0_1.html?t=1&k={{key}},{\"charset\":\"gbk\"}",
                listSelector: ".nl_r1",
                nameSelector: ".bl_r1_tit a@text",
                authorSelector: ".nl_r1_author a@text",
                detailURLSelector: ".bl_r1_tit a@href",
                summarySelector: ".bl_r1_into@text"
            ),
            tocRule: SourceTocRule(
                tocURLSelector: "a.fp_btn1[1]@href",
                listSelector: "ul.v_nodeList a, .nodeList a",
                nameSelector: "@text",
                urlSelector: "@href"
            ),
            contentRule: SourceContentRule(
                contentSelector: ".nodeContent@text"
            ),
            exploreRule: SourceExploreRule(
                urlTemplate: lines.joined(separator: "\n"),
                listSelector: "div.novelName, a.novelName, .nl_r1",
                nameSelector: ".bl_r1_tit a@text, @title, @text",
                authorSelector: ".nl_r1_author a@text",
                detailURLSelector: ".bl_r1_tit a@href, @href",
                summarySelector: ".bl_r1_into@text"
            )
        )
    }

    /// 无错小说现在落在手机站。电脑域名会跳到这里，分类页和首页都是 article 卡片。
    private static func wucuoSource(id: String, name: String, group: String) -> UniversalBookSource {
        let base = "https://m.wucuoxs.com"
        let categories = [
            ("古代言情", "sort-1-1"),
            ("现代言情", "sort-2-1"),
            ("都市言情", "sort-3-1"),
            ("玄幻魔法", "sort-4-1"),
            ("仙侠武侠", "sort-5-1"),
            ("同人网游", "sort-6-1"),
            ("科幻悬疑", "sort-7-1")
        ]
        var lines = ["最新::\(base)/"]
        for (title, path) in categories {
            lines.append("\(title)::\(base)/\(path)/")
        }
        return UniversalBookSource(
            id: id,
            kind: .legado,
            name: name,
            sourceURL: base,
            group: group,
            enabled: true,
            searchRule: SourceSearchRule(
                urlTemplate: "\(base)/user/search.html?q={{key}}",
                listSelector: "div.info",
                nameSelector: "h2.title@text",
                authorSelector: "p@text##^作者：##",
                detailURLSelector: "a@href",
                summarySelector: ".intro@text"
            ),
            tocRule: SourceTocRule(
                listSelector: "ul.chapter a",
                nameSelector: "@text",
                urlSelector: "@href"
            ),
            contentRule: SourceContentRule(
                contentSelector: "#text@text"
            ),
            exploreRule: SourceExploreRule(
                urlTemplate: lines.joined(separator: "\n"),
                listSelector: "article",
                nameSelector: "h2.title@text",
                authorSelector: "p@text##^作者：##",
                detailURLSelector: "a@href",
                summarySelector: ".intro@text"
            )
        )
    }

    /// 久久小说网旧域名会跳到 ijjxsxzw.com。首页是一行一条，分类页是 listbg。
    private static func jiujiuSource(id: String, name: String, group: String) -> UniversalBookSource {
        let base = "https://www.ijjxsxzw.com"
        let categories = [
            ("穿越", "chuanyue"),
            ("重生", "chongshengxiaoshuo"),
            ("古代架空", "lsjs"),
            ("现代言情", "young"),
            ("总裁豪门", "qinggan"),
            ("仙侠幻想", "wuxia"),
            ("同人衍生", "tongrenxiaoshuo"),
            ("无限流", "wuxianliu"),
            ("耽于纯美", "dmtr"),
            ("玄幻魔法", "xuanhuan"),
            ("都市异能", "dushi"),
            ("历史军事", "tiexue"),
            ("网游小说", "juben"),
            ("惊悚悬疑", "kongbu"),
            ("文学名著", "gdmz")
        ]
        var lines = ["最新::\(base)/"]
        for (title, path) in categories {
            lines.append("\(title)::\(base)/txt/\(path)/")
        }
        return UniversalBookSource(
            id: id,
            kind: .legado,
            name: name,
            sourceURL: base,
            group: group,
            enabled: true,
            searchRule: SourceSearchRule(
                urlTemplate: "\(base)/e/search/index.php,{\"method\":\"POST\",\"body\":\"show=title,writer&tbname=download&tempid=2&orderby=newstime&myorder=0&keyboard={{key}}\"}",
                httpMethod: "POST",
                listSelector: ".searchTopic",
                nameSelector: "a.searchtitle@text",
                authorSelector: "@text##.*作者：##",
                detailURLSelector: "a.searchtitle@href",
                summarySelector: ""
            ),
            tocRule: SourceTocRule(
                tocURLSelector: "a.download-btn@href",
                listSelector: ".chapter-list a",
                nameSelector: "@text",
                urlSelector: "@href"
            ),
            contentRule: SourceContentRule(
                contentSelector: "#view_content_txt@text"
            ),
            exploreRule: SourceExploreRule(
                urlTemplate: lines.joined(separator: "\n"),
                listSelector: "span.line-main, div.listbg",
                nameSelector: "a@text",
                authorSelector: ".author@text, .mainGreen a@text",
                detailURLSelector: "a@href",
                summarySelector: ""
            )
        )
    }

    /// 纵横桌面版首页和分类页都是推荐卡片。手机站目前返回 500。
    private static func zonghengSource(id: String, name: String, group: String) -> UniversalBookSource {
        let base = "https://www.zongheng.com"
        let categories = [
            ("玄幻奇幻", "8101"),
            ("武侠仙侠", "8102"),
            ("都市", "8103"),
            ("历史", "8104"),
            ("科幻", "8105"),
            ("奇闻异事", "8106"),
            ("游戏", "8107"),
            ("N次元", "8108"),
            ("现实题材", "8109")
        ]
        var lines = ["热门::\(base)/"]
        for (title, cate) in categories {
            lines.append("\(title)::\(base)/categories?cateFineId=\(cate)&pageNum={{page}}")
        }
        return UniversalBookSource(
            id: id,
            kind: .legado,
            name: name,
            sourceURL: base,
            group: group,
            enabled: true,
            searchRule: SourceSearchRule(
                urlTemplate: "https://search.zongheng.com/s?keyword={{key}}",
                listSelector: ".search-result-list",
                nameSelector: "h2.tit a@text",
                authorSelector: ".bookinfo a@text",
                detailURLSelector: "h2.tit a@href",
                summarySelector: ".des@text"
            ),
            tocRule: SourceTocRule(
                listSelector: "a.book-info--btn-reading",
                nameSelector: "@text, @title",
                urlSelector: "@href"
            ),
            contentRule: SourceContentRule(
                contentSelector: ".reader-box .content@text"
            ),
            exploreRule: SourceExploreRule(
                urlTemplate: lines.joined(separator: "\n"),
                listSelector: ".recommend-item, .zh-modules-rank-book",
                nameSelector: "a.recommend-img--cover@title, .book-rank--title-text a@text",
                authorSelector: ".recommend-type a@text",
                detailURLSelector: "a.recommend-img--cover@href, .book-rank--title-text a@href",
                summarySelector: ""
            )
        )
    }

    /// www.shuqi.com 只返回一段跳转脚本。书单在 t.shuqi.com 的首屏 HTML 里。
    private static func shuqiSource(id: String, name: String, group: String) -> UniversalBookSource {
        let base = "https://t.shuqi.com"
        return UniversalBookSource(
            id: id,
            kind: .legado,
            name: name,
            sourceURL: base,
            group: group,
            enabled: true,
            searchRule: SourceSearchRule(
                urlTemplate: "\(base)/search?keyword={{key}}",
                listSelector: "a.item, a.book-item-a",
                nameSelector: ".book-name@text, h3@text",
                authorSelector: ".author-name@text, label@text",
                detailURLSelector: "@href",
                summarySelector: "blockquote@text"
            ),
            tocRule: SourceTocRule(
                listSelector: ".latest-chapter a",
                nameSelector: "@text",
                urlSelector: "@href"
            ),
            contentRule: SourceContentRule(
                contentSelector: ".content@text"
            ),
            exploreRule: SourceExploreRule(
                urlTemplate: "热门::\(base)/",
                listSelector: "a.item, a.book-item-a",
                nameSelector: ".book-name@text, h3@text",
                authorSelector: ".author-name@text, label@text",
                detailURLSelector: "@href",
                summarySelector: "blockquote@text"
            )
        )
    }

    /// 69书吧不在精选导入列表里，切换项仍用已经对照过的分类规则。
    private static func shubaSource(id: String, name: String, group: String) -> UniversalBookSource {
        let base = "https://www.69shuba.com"
        return UniversalBookSource(
            id: id,
            kind: .legado,
            name: name,
            sourceURL: base,
            group: group,
            enabled: true,
            searchRule: SourceSearchRule(
                urlTemplate: "\(base)/modules/article/search.php,{\"method\":\"POST\",\"body\":\"searchkey={{key}}&searchtype=all\",\"charset\":\"gbk\"}",
                httpMethod: "POST",
                listSelector: ".newbox li",
                nameSelector: "h3 a[1]@text, h3 a@text",
                authorSelector: "label@text, .author a@text",
                detailURLSelector: "h3 a[1]@href, h3 a@href",
                summarySelector: ".ellipsis_2@text, ol@text"
            ),
            tocRule: SourceTocRule(
                // 详情页 /book/123.htm 没有目录。完整目录在「完整目录」链接，或把 .htm 换成 /。
                tocURLSelector: "a.more-btn@href, .addbtn a@href, rewrite:.htm=/|/txt/=/",
                listSelector: "#catalog li a, #chapterlist li a",
                nameSelector: "text",
                urlSelector: "href"
            ),
            contentRule: SourceContentRule(
                contentSelector: ".txtnav@html, #content@text",
                replaceRules: ["##69书吧##", "##www\\.69shuba\\.com##", "##\\(本章完\\)##", "##（本章完）##"]
            ),
            exploreRule: shubaExploreRule()
        )
    }

    /// 69书吧分类页用文章列表，不再拿搜索结果的结构去套首页。
    private static func shubaExploreRule() -> SourceExploreRule {
        let base = "https://www.69shuba.com"
        let names = [
            "全部分类", "玄幻魔法", "修真武侠", "言情小说", "历史军事", "游戏竞技",
            "科幻空间", "悬疑惊悚", "同人小说", "都市小说", "官场职场", "穿越时空", "青春校园"
        ]
        var lines: [String] = []
        for (index, title) in names.enumerated() {
            lines.append("\(title)::\(base)/novels/class/\(index).htm")
        }
        for (index, title) in names.enumerated() {
            lines.append("完本-\(title)::\(base)/novels/full/\(index).htm")
        }
        return SourceExploreRule(
            urlTemplate: lines.joined(separator: "\n"),
            listSelector: "#article_list_content li, .newlistbox li",
            nameSelector: "h3 a[1]@text, h3 a@text",
            authorSelector: "label@text",
            detailURLSelector: "h3 a[1]@href, h3 a@href",
            summarySelector: ".ellipsis_2@text"
        )
    }

    /// 企鹅小说现在落在 qiexs.cc。首页是排行，分类页是表格。
    private static func qiexsSource(id: String, name: String, group: String) -> UniversalBookSource {
        let base = "https://www.qiexs.cc"
        let categories = [
            ("玄幻奇幻", "xuanhuanqihuan"),
            ("武侠仙侠", "wuxiaxianxia"),
            ("都市言情", "dushiyanqing"),
            ("历史军事", "lishijunshi"),
            ("游戏竞技", "youxijingji"),
            ("科幻传奇", "kehuanchuanqi"),
            ("恐怖灵异", "kongbulingyi"),
            ("完本小说", "quanbenxiaoshuo")
        ]
        var lines = ["热门::\(base)/"]
        for (title, path) in categories {
            lines.append("\(title)::\(base)/\(path)/?page={{page}}")
        }
        return UniversalBookSource(
            id: id,
            kind: .legado,
            name: name,
            sourceURL: base,
            group: group,
            enabled: true,
            searchRule: SourceSearchRule(
                urlTemplate: "\(base)/search?keyword={{key}}",
                listSelector: ".col-md-10",
                nameSelector: "h4.bookTitle a@text",
                authorSelector: "p.booktag a@text",
                detailURLSelector: "h4.bookTitle a@href",
                summarySelector: "p.text-muted@text"
            ),
            tocRule: SourceTocRule(
                listSelector: "#list-chapterAll a",
                nameSelector: "text",
                urlSelector: "href"
            ),
            contentRule: SourceContentRule(
                contentSelector: "#htmlContent@text"
            ),
            exploreRule: SourceExploreRule(
                urlTemplate: lines.joined(separator: "\n"),
                listSelector: "table.mytable tr, li.list-group-item",
                nameSelector: "a@title",
                authorSelector: "td.text-muted@text, small.text-muted@text##^\\s*/\\s*##",
                detailURLSelector: "td a@href, a@href",
                summarySelector: "td.text-nowrap@text"
            )
        )
    }

}

/// 站点切换模型
nonisolated struct SiteCatalogEntry: Identifiable, Sendable {
    var id: String
    var name: String
    var icon: String
    var note: String
    var group: String
    var host: String
    var source: UniversalBookSource?

    var siteTitle: String {
        var res = ""
        if !icon.isEmpty && icon != "📄" { res += "\(icon)" }
        res += name
        if !note.isEmpty { res += " \(note)" }
        return res
    }

    var displayName: String {
        siteTitle
    }
}
