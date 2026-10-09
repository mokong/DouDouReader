import Foundation

/// 发现页里的一个可选项，例如「玄幻 -> 21」。
nonisolated struct ExploreOption: Identifiable, Equatable, Sendable {
    var label: String
    var value: String

    var id: String { label + "\u{1f}" + value }
}

/// 发现页的一行筛选。key 对应 URL 里的 `{{key}}`。
nonisolated struct ExploreFilter: Identifiable, Equatable, Sendable {
    var key: String
    var title: String
    var options: [ExploreOption]

    var id: String { key }
}

/// 发现页的一个频道。香色闺阁把每一行 `标题::地址&&筛选` 渲染成顶部频道。
nonisolated struct ExploreChannel: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var urlTemplate: String
    var filters: [ExploreFilter]

    func defaultSelections() -> [String: String] {
        var map: [String: String] = [:]
        for filter in filters {
            map[filter.key] = filter.options.first?.value ?? ""
        }
        return map
    }
}

/// 解析阅读 3.0 / 香色闺阁共用的发现地址。
///
/// 支持多行 `标题::地址&&筛选键&&选项名::提交值`，以及 JSON 数组 `[{title,url}]`。
nonisolated enum ExploreURLParser {
    static func channels(from raw: String) -> [ExploreChannel] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.hasPrefix("[") {
            return channels(fromJSON: trimmed)
        }
        let lines = trimmed.split(whereSeparator: \.isNewline).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var result: [ExploreChannel] = []
        for (index, line) in lines.enumerated() where !line.isEmpty {
            result.append(parseLine(line, index: index))
        }
        return result
    }

    /// 把 `{{page}}` 和筛选占位符替换成当前选择。
    static func resolve(template: String, selections: [String: String], page: Int) -> String {
        var text = template
        let pageText = String(max(page, 1))
        for token in ["{{page}}", "{{pageIndex}}", "%@pageIndex", "%@page"] {
            text = text.replacingOccurrences(of: token, with: pageText)
        }
        for (key, value) in selections {
            let encoded = encode(value)
            text = text.replacingOccurrences(of: "{{\(key)}}", with: encoded)
            text = text.replacingOccurrences(of: "%@\(key)", with: encoded)
        }
        guard let regex = try? NSRegularExpression(pattern: "\\{\\{[^{}]+\\}\\}") else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private static func channels(fromJSON raw: String) -> [ExploreChannel] {
        guard let data = raw.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        var result: [ExploreChannel] = []
        for (index, item) in array.enumerated() {
            let title = (item["title"] as? String) ?? (item["name"] as? String) ?? "全部"
            let url = (item["url"] as? String) ?? ""
            guard !url.isEmpty else { continue }
            result.append(parseBody(url, title: title, index: index))
        }
        return result
    }

    private static func parseLine(_ line: String, index: Int) -> ExploreChannel {
        guard let range = line.range(of: "::") else {
            return parseBody(line, title: "全部", index: index)
        }
        let left = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let right = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty || left.contains("://") || left.contains("/") || left.contains("{{") {
            return parseBody(line, title: "全部", index: index)
        }
        return parseBody(right, title: left, index: index)
    }

    private static func parseBody(_ body: String, title: String, index: Int) -> ExploreChannel {
        let parts = body.components(separatedBy: "&&")
        let url = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var filters: [ExploreFilter] = []
        var cursor = 1
        while cursor < parts.count {
            let key = parts[cursor].trimmingCharacters(in: .whitespacesAndNewlines)
            cursor += 1
            guard !key.isEmpty, !key.contains("::"), !filters.contains(where: { $0.key == key }) else { continue }
            var options: [ExploreOption] = []
            while cursor < parts.count, parts[cursor].contains("::") {
                let piece = parts[cursor].trimmingCharacters(in: .whitespacesAndNewlines)
                if let separator = piece.range(of: "::") {
                    let label = String(piece[..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = String(piece[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !label.isEmpty {
                        options.append(ExploreOption(label: label, value: value))
                    }
                }
                cursor += 1
            }
            if !options.isEmpty {
                filters.append(ExploreFilter(key: key, title: key, options: options))
            }
        }
        let shown = title.isEmpty ? "全部" : title
        return ExploreChannel(id: "\(index)-\(shown)", title: shown, urlTemplate: url, filters: filters)
    }

    private static func encode(_ value: String) -> String {
        guard value.unicodeScalars.contains(where: { !$0.isASCII }) else { return value }
        return value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}
