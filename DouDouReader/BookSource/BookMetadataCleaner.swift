import Foundation

/// 书源抓出的分类与连载状态常是复合文本（`"[玄幻奇幻]"`、`"分类：仙侠 | 连载中"`），统一清洗并拆出状态。
nonisolated enum BookMetadataCleaner {
    private static let decoratorSet = CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: "[]【】「」『』\"'“”‘’")
    )
    private static let segmentSet = CharacterSet(charactersIn: "·|｜/、,，;；")
    private static let statusTokens = ["已完结", "连载中", "完本", "完结", "连载", "更新中", "已完成", "ongoing", "serial", "completed"]

    private nonisolated static let wordCountRegex = try? NSRegularExpression(pattern: #"^[\d.,]+\s*(?:万字|万|字)?$"#)

    /// 先从复合分类文本里拆出连载状态，剩下的首个非空段才是分类。
    static func clean(category rawCategory: String, status rawStatus: String) -> (category: String, status: String) {
        let stripped = stripDecorators(rawCategory, labels: ["分类", "类型", "类别", "栏目"])
        let cleanedStatus = cleanStatus(rawStatus)
        guard cleanedStatus.isEmpty else {
            return (firstCategoryWord(stripped), cleanedStatus)
        }
        let segments = splitSegments(stripped)
        if let index = segments.firstIndex(where: { isStatusText($0) }) {
            var rest = segments
            let statusSegment = rest.remove(at: index)
            let category = rest.first(where: { !isWordCountText($0) }) ?? ""
            return (category, normalizeStatus(statusSegment))
        }
        return (firstCategoryWord(stripped), "")
    }

    /// 去掉「分类：」等前缀与 `[]【】` 外层修饰符，复合文本取首个非空分类词。
    static func cleanCategory(_ raw: String) -> String {
        firstCategoryWord(stripDecorators(raw, labels: ["分类", "类型", "类别", "栏目"]))
    }

    /// 去掉「状态：」前缀并归一常见状态词；不是状态词的内容（如字数）返回空串。
    static func cleanStatus(_ raw: String) -> String {
        let text = stripDecorators(raw, labels: ["状态", "连载状态", "更新状态"])
        guard isStatusText(text) else { return "" }
        return normalizeStatus(text)
    }

    private static func stripDecorators(_ raw: String, labels: [String]) -> String {
        var text = raw.trimmingCharacters(in: decoratorSet)
        for label in labels {
            for separator in ["：", ":"] where text.hasPrefix(label + separator) {
                text = String(text.dropFirst(label.count + separator.count))
                break
            }
        }
        return text.trimmingCharacters(in: decoratorSet)
    }

    private static func splitSegments(_ text: String) -> [String] {
        text.components(separatedBy: segmentSet)
            .map { $0.trimmingCharacters(in: decoratorSet) }
            .filter { !$0.isEmpty }
    }

    private static func firstCategoryWord(_ text: String) -> String {
        splitSegments(text).first(where: { !isWordCountText($0) && !isStatusText($0) }) ?? stripDecorators(text, labels: [])
    }

    private static func isStatusText(_ text: String) -> Bool {
        let lower = text.lowercased()
        return statusTokens.contains { lower.contains($0) }
    }

    private static func normalizeStatus(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("完结") || lower.contains("完本") || lower.contains("已完成") || lower.contains("completed") {
            return "完结"
        }
        if lower.contains("连载") || lower.contains("更新中") || lower.contains("ongoing") || lower.contains("serial") {
            return "连载中"
        }
        return ""
    }

    private static func isWordCountText(_ text: String) -> Bool {
        guard let regex = wordCountRegex else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}
