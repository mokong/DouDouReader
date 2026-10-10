import Foundation

/// 另外核对过的默认书源。规则只使用现有选择器能表达的部分，目录从第1章排起。
extension PresetBookSources {
    static func extraVerifiedPresets() -> [PresetBookSourceItem] {
        [
            biquFamily345(id: "preset-biqu345", name: "笔趣阁345", base: "https://www.biquge345.com", weight: 8800, summary: "笔趣阁345 的更新列表能列出书，书籍页的目录从第1章开始，正文在同一段里。"),
            biquFamily543(),
            classicFamily(
                id: "preset-8tsw",
                name: "八天书屋",
                base: "https://www.8tsw.com",
                weight: 8720,
                summary: "八天书屋的更新列表和章节正文都能直接解析，目录会跳过最前面的最新章节。",
                categories: eightDayCategories,
                search: articleSearch(base: "https://www.8tsw.com"),
                startsAtFirst: true
            ),
            classicFamily(
                id: "preset-biqu123",
                name: "笔趣阁123",
                base: "https://www.biquge123.com",
                weight: 8680,
                summary: "笔趣阁123 的最近更新能列出书，目录从第1章排到最新章，正文在内容区。",
                categories: [],
                search: articleSearch(base: "https://www.biquge123.com"),
                startsAtFirst: true
            ),
            classicFamily(
                id: "preset-xbiquges",
                name: "新笔趣阁",
                base: "https://www.xbiquges.com",
                weight: 8640,
                summary: "新笔趣阁分类页能列出书。书籍目录从第1章开始，章节正文在内容区。",
                categories: magicCategories,
                search: silentSearch(base: "https://www.xbiquges.com"),
                startsAtFirst: true
            ),
            classicFamily(
                id: "preset-biquicu",
                name: "绿色笔趣阁",
                base: "https://www.biquge.icu",
                weight: 8600,
                summary: "绿色笔趣阁的更新列表能列出书。完整目录在第二个章节表里，从第1章读起。",
                categories: magicCategories,
                search: silentSearch(base: "https://www.biquge.icu"),
                startsAtFirst: true
            ),
            biquPro(),
            biquSite(),
            classicFamily(
                id: "preset-xshuohu",
                name: "小说虎",
                base: "https://www.xiaoshuohu.com",
                weight: 8480,
                summary: "小说虎左栏更新列表能列出书，书籍目录从第一章开始，正文在内容区。",
                categories: [],
                search: silentSearch(base: "https://www.xiaoshuohu.com"),
                startsAtFirst: false
            ),
            gonovelFamily(id: "preset-haima", name: "海马文学", base: "https://www.haimawx.com", weight: 8440, summary: "海马文学推荐榜能列出书，目录从第1章排到最新章，正文在正文区。"),
            gonovelFamily(id: "preset-bajie", name: "八戒小说", base: "https://www.bajiewx.com", weight: 8400, summary: "八戒小说推荐榜能列出书，目录从第1章开始，章节正文在正文区。"),
            gonovelFamily(id: "preset-xunxiang", name: "寻香文学", base: "https://www.xx2.org", weight: 8360, summary: "寻香文学推荐榜能列出书，目录从第1章排到结尾，正文在正文区。"),
            shu69Family(),
            gonovelFamily(id: "preset-aisiluke", name: "思路客", base: "https://aisiluke.com", weight: 8280, summary: "思路客推荐榜能列出书，目录从第1章开始，章节正文在正文区。"),
            isilukeLegacy(),
            hetuShu(),
            bkneng(),
            sangshu()
        ]
    }

    private static let eightDayCategories = [
        ("玄幻小说", "/xuanhuanxiaoshuo/"),
        ("修真小说", "/xiuzhenxiaoshuo/"),
        ("都市小说", "/dushixiaoshuo/"),
        ("穿越小说", "/chuanyuexiaoshuo/"),
        ("网游小说", "/wangyouxiaoshuo/"),
        ("科幻小说", "/kehuanxiaoshuo/")
    ]

    private static let magicCategories = [
        ("玄幻魔法", "/category/xuanhuan"),
        ("仙侠修真", "/category/xianxia"),
        ("都市小说", "/category/dushi"),
        ("历史小说", "/category/lishi"),
        ("科幻小说", "/category/kehuan"),
        ("网游小说", "/category/wangyou"),
        ("女生小说", "/category/yanqing"),
        ("其他小说", "/category/qita")
    ]

    private static let sortCategories = [
        ("玄幻魔法", "/sort/1_1/"),
        ("仙侠修真", "/sort/2_1/"),
        ("都市言情", "/sort/3_1/"),
        ("网游动漫", "/sort/4_1/"),
        ("科幻小说", "/sort/5_1/"),
        ("恐怖灵异", "/sort/6_1/"),
        ("历史军事", "/sort/7_1/"),
        ("其他小说", "/sort/8_1/")
    ]

    private static let txtWatermark = [
        "##一秒记住【[^】\\n]{0,30}】[^\\n]*##",
        "##(?m)^(?:（本章未完，请点击下一页继续阅读）)?第[0-9０-９零〇一二三四五六七八九十百千万两][^\\n]{0,80}(?:\\(第\\d+/\\d+页\\)|（第\\d+/\\d+页）)\\s*$##",
        "##（本章未完，请点击下一页继续阅读）##"
    ]

    private static let lineWatermark = [
        "##(?m)^[^\\n]{0,40}(?:笔趣阁|一秒记住|本章未完|最新网址：)[^\\n]*$##"
    ]

    private static func biquFamily345(id: String, name: String, base: String, weight: Int, summary: String) -> PresetBookSourceItem {
        makePreset(
            id: id,
            name: name,
            kind: .legado,
            summary: summary,
            sourceURL: base,
            weight: weight,
            search: SourceSearchRule(
                urlTemplate: "\(base)/s.php,{\"method\":\"POST\",\"body\":\"type=articlename&s={{key}}\"}",
                httpMethod: "POST",
                listSelector: "ul.gengxin li, ul.search li",
                nameSelector: "span.name a@text",
                detailURLSelector: "span.name a@href"
            ),
            toc: SourceTocRule(
                listSelector: "ul.info li a",
                nameSelector: "text",
                urlSelector: "href"
            ),
            content: SourceContentRule(contentSelector: "#txt@text", replaceRules: txtWatermark),
            explore: nameListExplore(base: base, categories: sortCategories)
        )
    }

    /// 书籍页的目录是脚本生成的。完整目录在「全部章节」打开的 ul.info，并且从第1章开始。
    private static func biquFamily543() -> PresetBookSourceItem {
        let base = "https://www.biquge543.com"
        return makePreset(
            id: "preset-biqu543",
            name: "笔趣阁543",
            kind: .legado,
            summary: "笔趣阁543 的更新列表能列出书。完整目录在「全部章节」，从第1章排到结尾。",
            sourceURL: base,
            weight: 8760,
            search: SourceSearchRule(
                urlTemplate: "\(base)/s.php,{\"method\":\"POST\",\"body\":\"type=articlename&s={{key}}\"}",
                httpMethod: "POST",
                listSelector: "ul.search li",
                nameSelector: "span.name a@text",
                detailURLSelector: "span.name a@href"
            ),
            toc: SourceTocRule(
                tocURLSelector: "div.gongneng a@href",
                listSelector: "ul.info li a",
                nameSelector: "text",
                urlSelector: "href"
            ),
            content: SourceContentRule(contentSelector: "#txt@text", replaceRules: txtWatermark),
            explore: nameListExplore(base: base, categories: sortCategories)
        )
    }

    private static func classicFamily(
        id: String,
        name: String,
        base: String,
        weight: Int,
        summary: String,
        categories: [(String, String)],
        search: SourceSearchRule,
        startsAtFirst: Bool
    ) -> PresetBookSourceItem {
        makePreset(
            id: id,
            name: name,
            kind: .legado,
            summary: summary,
            sourceURL: base,
            weight: weight,
            search: search,
            toc: SourceTocRule(
                listSelector: "#list dd a",
                nameSelector: "text",
                urlSelector: "href",
                startAtFirstChapter: startsAtFirst
            ),
            content: SourceContentRule(contentSelector: "#content@text", replaceRules: lineWatermark),
            explore: SourceExploreRule(
                urlTemplate: channelLines(base: base, categories: categories),
                listSelector: "div.l li",
                nameSelector: ".s2 a@text",
                authorSelector: ".s4@text, .s5@text",
                detailURLSelector: ".s2 a@href"
            )
        )
    }

    /// 页面上有两段章节表。第一段是最新几章，第二段从第1章排到结尾。
    private static func biquPro() -> PresetBookSourceItem {
        let base = "https://www.biquge.pro"
        return makePreset(
            id: "preset-biqupro",
            name: "笔趣阁Pro",
            kind: .legado,
            summary: "笔趣阁Pro 的更新列表和搜索都能列出书。目录从第1章开始，正文在章节内容区。",
            sourceURL: base,
            weight: 8560,
            search: SourceSearchRule(
                urlTemplate: "\(base)/search.html?keyword={{key}}",
                listSelector: "li",
                nameSelector: ".s2 a@text",
                detailURLSelector: ".s2 a@href"
            ),
            toc: SourceTocRule(
                listSelector: "ul.section-list li a",
                nameSelector: "text",
                urlSelector: "href",
                startAtFirstChapter: true
            ),
            content: SourceContentRule(contentSelector: "#chapterContent@text"),
            explore: SourceExploreRule(
                urlTemplate: "最新::\(base)/",
                listSelector: "li",
                nameSelector: ".s2 a@text",
                authorSelector: ".s5@text, .s4@text",
                detailURLSelector: ".s2 a@href"
            )
        )
    }

    private static func biquSite() -> PresetBookSourceItem {
        let base = "https://www.biquge.site"
        let categories = [
            ("玄幻", "/category/xuanhuan.html"),
            ("修真", "/category/xiuzhen.html"),
            ("都市", "/category/dushi.html"),
            ("历史", "/category/lishi.html")
        ]
        return makePreset(
            id: "preset-biqugesite",
            name: "笔趣阁站",
            kind: .legado,
            summary: "笔趣阁站的书单和搜索都能列出书。目录从第1章开始，正文里的网址行会被去掉。",
            sourceURL: base,
            weight: 8520,
            search: SourceSearchRule(
                urlTemplate: "\(base)/search/result.html?searchkey={{key}}",
                listSelector: "div.pt-ll-l",
                nameSelector: "a@title",
                detailURLSelector: "a@href"
            ),
            toc: SourceTocRule(
                listSelector: "ul.dirlist li a",
                nameSelector: "text",
                urlSelector: "href"
            ),
            content: SourceContentRule(
                contentSelector: "#chaptercontent@text",
                replaceRules: ["##(?m)^最新网址：[^\\n]*$##"]
            ),
            explore: SourceExploreRule(
                urlTemplate: channelLines(base: base, categories: categories),
                listSelector: ".novellist .item",
                nameSelector: "a@title",
                detailURLSelector: "a@href"
            )
        )
    }

    private static func gonovelFamily(id: String, name: String, base: String, weight: Int, summary: String) -> PresetBookSourceItem {
        makePreset(
            id: id,
            name: name,
            kind: .legado,
            summary: summary,
            sourceURL: base,
            weight: weight,
            search: SourceSearchRule(
                urlTemplate: "\(base)/search,{\"method\":\"POST\",\"body\":\"s={{key}}\"}",
                httpMethod: "POST",
                listSelector: "li",
                nameSelector: "a.blue@text",
                detailURLSelector: "a.blue@href"
            ),
            toc: SourceTocRule(
                listSelector: "#directoryList a",
                nameSelector: "text",
                urlSelector: "href"
            ),
            content: SourceContentRule(contentSelector: "#txt@text"),
            explore: SourceExploreRule(
                urlTemplate: "最新::\(base)/",
                listSelector: "section#tj li",
                nameSelector: "img@alt",
                detailURLSelector: "a@href"
            )
        )
    }

    private static func shu69Family() -> PresetBookSourceItem {
        let base = "https://www.69shu.icu"
        return makePreset(
            id: "preset-69shuicu",
            name: "69中文",
            kind: .legado,
            summary: "69中文的推荐书单和搜索都能列出书。目录从第1章开始，正文在正文区。",
            sourceURL: base,
            weight: 8320,
            search: SourceSearchRule(
                urlTemplate: "\(base)/search,{\"method\":\"POST\",\"body\":\"s={{key}}\"}",
                httpMethod: "POST",
                listSelector: "h3",
                nameSelector: "a[1]@text",
                detailURLSelector: "a[1]@href"
            ),
            toc: SourceTocRule(
                listSelector: "#directoryPanel .chapter-list a",
                nameSelector: "text",
                urlSelector: "href"
            ),
            content: SourceContentRule(contentSelector: "#txt@text"),
            explore: SourceExploreRule(
                urlTemplate: channelLines(base: base, categories: magicCategories),
                listSelector: "a.book-grid-item",
                nameSelector: ".title@text",
                detailURLSelector: "@href"
            )
        )
    }

    private static func nameListExplore(base: String, categories: [(String, String)]) -> SourceExploreRule {
        SourceExploreRule(
            urlTemplate: channelLines(base: base, categories: categories),
            listSelector: "ul.gengxin li, ul.search li",
            nameSelector: "span.name a@text",
            detailURLSelector: "span.name a@href"
        )
    }

    private static func channelLines(base: String, categories: [(String, String)]) -> String {
        var lines = ["最新::\(base)/"]
        for (title, path) in categories {
            lines.append("\(title)::\(base)\(path)")
        }
        return lines.joined(separator: "\n")
    }

    private static func articleSearch(base: String) -> SourceSearchRule {
        SourceSearchRule(
            urlTemplate: "\(base)/modules/article/search.php,{\"method\":\"POST\",\"body\":\"searchkey={{key}}&searchtype=articlename\",\"charset\":\"gbk\"}",
            httpMethod: "POST",
            listSelector: "tr#nr",
            nameSelector: "td.odd a@text",
            detailURLSelector: "td.odd a@href"
        )
    }

    /// 老思路客。更新行是封面和书名，目录最前面几章是最新章，正文在内容区。
    private static func isilukeLegacy() -> PresetBookSourceItem {
        let base = "http://www.isiluke.la"
        return makePreset(
            id: "preset-isiluke",
            name: "思路客文",
            kind: .legado,
            summary: "思路客文的更新列表和搜索都能列出书。目录会跳过开头的最新章，从第1章读到结尾。",
            sourceURL: base,
            weight: 8240,
            search: SourceSearchRule(
                urlTemplate: "\(base)/search.html?name={{key}}",
                listSelector: "li",
                nameSelector: ".s2 a@text",
                authorSelector: ".s4 a@text",
                detailURLSelector: ".s2 a@href"
            ),
            toc: SourceTocRule(
                listSelector: "#list dd a",
                nameSelector: "text",
                urlSelector: "href",
                startAtFirstChapter: true
            ),
            content: SourceContentRule(contentSelector: "#content@text", replaceRules: lineWatermark),
            explore: SourceExploreRule(
                urlTemplate: "最新::\(base)/",
                listSelector: "div.l div.item",
                nameSelector: "img@alt",
                authorSelector: "dt span@text",
                detailURLSelector: "a@href"
            )
        )
    }

    /// 和图书。推荐位用书名标题，目录在 #dir，正文按段写在内容区。
    private static func hetuShu() -> PresetBookSourceItem {
        let base = "https://hetushu.com"
        return makePreset(
            id: "preset-hetushu",
            name: "和图书",
            kind: .legado,
            summary: "和图书推荐位能列出书。目录从第一章排到全书末尾，正文在内容区。",
            sourceURL: base,
            weight: 8200,
            search: silentSearch(base: base),
            toc: SourceTocRule(
                listSelector: "#dir dd a",
                nameSelector: "text",
                urlSelector: "href"
            ),
            content: SourceContentRule(contentSelector: "#content div@text"),
            explore: SourceExploreRule(
                urlTemplate: "最新::\(base)/",
                listSelector: "dl.recommand li",
                nameSelector: "a@title",
                detailURLSelector: "a@href"
            )
        )
    }

    /// 不可能的世界。热门榜的书名链接能打开书，目录行和正文段落都在页面里。
    private static func bkneng() -> PresetBookSourceItem {
        let base = "https://wenxue.bkneng.com"
        return makePreset(
            id: "preset-bkneng",
            name: "不可能的世界",
            kind: .legado,
            summary: "不可能的世界热门榜能列出书。目录从第1章排到结尾，正文按段落读取。",
            sourceURL: base,
            weight: 8160,
            search: silentSearch(base: base),
            toc: SourceTocRule(
                listSelector: "li.lookingHot a",
                nameSelector: "text",
                urlSelector: "href"
            ),
            content: SourceContentRule(contentSelector: ".myContent p@text"),
            explore: SourceExploreRule(
                urlTemplate: "最新::\(base)/",
                listSelector: "div.hotBooks a",
                nameSelector: "text",
                detailURLSelector: "href"
            )
        )
    }

    /// 九九藏书。首页表格是书，书籍页的章节表从第1章开始，正文在内容区。
    private static func sangshu() -> PresetBookSourceItem {
        let base = "https://www.sangshixs.com"
        return makePreset(
            id: "preset-sangshu",
            name: "九九藏书",
            kind: .legado,
            summary: "九九藏书首页表格能列出书。目录从第1章开始，正文在内容区。",
            sourceURL: base,
            weight: 8120,
            search: silentSearch(base: base),
            toc: SourceTocRule(
                listSelector: "#booklist a",
                nameSelector: "text",
                urlSelector: "href"
            ),
            content: SourceContentRule(contentSelector: "#content@text"),
            explore: SourceExploreRule(
                urlTemplate: "最新::\(base)/",
                listSelector: "td.col-sm-5",
                nameSelector: "a@title",
                detailURLSelector: "a@href"
            )
        )
    }

    /// 站点没有可用搜索页。这个选择器不会匹配首页，所以搜索会空着，而不是把首页书单当成结果。
    private static func silentSearch(base: String) -> SourceSearchRule {
        SourceSearchRule(
            urlTemplate: "\(base)/?keyword={{key}}",
            listSelector: "#missing-search li",
            nameSelector: "a@text",
            detailURLSelector: "a@href"
        )
    }
}
