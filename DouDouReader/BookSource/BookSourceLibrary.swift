import Foundation

/// 切换列表里的一条书源。发现页只用当前勾选的一条。书架上的搜索会把已启用的源一起查。
nonisolated struct SwitchableSource: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var icon: String
    var note: String
    var group: String
    var host: String
    var source: UniversalBookSource

    var siteTitle: String {
        var text = ""
        if !icon.isEmpty && icon != "📄" {
            text += icon
        }
        text += name
        if !note.isEmpty {
            text += " \(note)"
        }
        return text
    }
}

/// 把内置站点和用户导入的书源合成「当前真正生效」的切换列表。
enum BookSourceLibrary {
    static let selectionKey = "doudou.selectedBookSourceID"

    static func switchable(records: [SourceRecord]) -> [SwitchableSource] {
        let disabledHosts = Set(records.filter { !$0.enabled }.map { hostKey($0.baseURL) }.filter { !$0.isEmpty })
        let disabledNames = Set(records.filter { !$0.enabled }.map(\.name))
        let enabledRecords = records.filter(\.enabled)

        var items: [SwitchableSource] = []
        var usedRecordIDs = Set<String>()

        for site in PresetBookSources.screenshotSites {
            guard let builtIn = site.source else { continue }
            let host = hostKey(builtIn.sourceURL).isEmpty ? hostKey(site.host) : hostKey(builtIn.sourceURL)
            if disabledHosts.contains(host) || disabledNames.contains(site.name) || disabledNames.contains(builtIn.name) {
                continue
            }
            if let record = enabledRecords.first(where: { hostKey($0.baseURL) == host || $0.name == site.name }) {
                items.append(item(from: record, fallback: builtIn, icon: site.icon, note: site.note, group: site.group))
                usedRecordIDs.insert(record.id.uuidString)
                continue
            }
            items.append(
                SwitchableSource(
                    id: site.id,
                    name: site.name,
                    icon: site.icon,
                    note: site.note,
                    group: site.group,
                    host: site.host,
                    source: builtIn
                )
            )
        }

        for record in enabledRecords where !usedRecordIDs.contains(record.id.uuidString) {
            let fallback = UniversalBookSource(
                id: record.id.uuidString,
                kind: .doudou,
                name: record.name,
                sourceURL: record.baseURL,
                group: "文本/小说"
            )
            items.append(item(from: record, fallback: fallback, icon: "📄", note: "", group: ""))
        }
        // 按书源自带 weight 降序排列，权重高的排前面；等权重保持原有顺序。
        let indexed = items.enumerated()
        return indexed.sorted { a, b in
            if a.element.source.weight != b.element.source.weight {
                return a.element.source.weight > b.element.source.weight
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    static func resolve(id: String, records: [SourceRecord]) -> SwitchableSource? {
        let items = switchable(records: records)
        return items.first { $0.id == id } ?? items.first
    }

    nonisolated static func catalog(for item: SwitchableSource) -> any BookCatalog {
        if item.source.kind == .doudou, let url = SourceURL.parse(item.source.sourceURL) {
            return RemoteBookCatalog(id: item.id, name: item.name, baseURL: url)
        }
        return RuleBasedBookCatalog(recordID: item.id, source: item.source)
    }

    static func hostKey(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if !text.contains("://") {
            text = "https://" + text
        }
        let host = URL(string: text)?.host?.lowercased() ?? ""
        if host.hasPrefix("www.") {
            return String(host.dropFirst(4))
        }
        return host
    }

    private static func item(
        from record: SourceRecord,
        fallback: UniversalBookSource,
        icon: String,
        note: String,
        group: String
    ) -> SwitchableSource {
        var source = fallback
        if let decoded = try? BookSourceParser.decodeSingleSource(json: record.rawJSON),
           decoded.kind == .legado || decoded.kind == .xiangse {
            source = decoded
            source.id = record.id.uuidString
            if source.exploreRule.urlTemplate.isEmpty {
                source.exploreRule = fallback.exploreRule
            }
            if source.name.isEmpty {
                source.name = record.name
            }
        } else {
            source.id = record.id.uuidString
            source.kind = .doudou
            source.name = record.name.isEmpty ? fallback.name : record.name
            source.sourceURL = record.baseURL.isEmpty ? fallback.sourceURL : record.baseURL
            source.exploreRule = SourceExploreRule()
        }
        let resolvedGroup = group.isEmpty ? (source.group.isEmpty ? "文本/小说" : source.group) : group
        return SwitchableSource(
            id: record.id.uuidString,
            name: source.name,
            icon: icon,
            note: note,
            group: resolvedGroup,
            host: hostKey(source.sourceURL),
            source: source
        )
    }
}
