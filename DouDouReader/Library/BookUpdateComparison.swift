import Foundation

/// 书架检查更新的纯比较逻辑：本地已存目录 vs 远端最新目录。
/// 独立成 enum 方便 LogicChecks 回归，不碰网络、不碰 SwiftData。
nonisolated enum BookUpdateComparison {
    struct Outcome: Equatable, Sendable {
        /// 远端比本地多出的章节数（远端更少时按 0 计）。
        var newChapterCount: Int
        /// 目录有变化：多出章节，或最新一章的章名/地址变了。
        var hasUpdate: Bool
        /// 远端最新一章的章名。
        var latestTitle: String
    }

    static func compare(local: [RemoteChapterRef], remote: [RemoteChapterRef]) -> Outcome {
        guard let remoteLast = remote.last else {
            return Outcome(newChapterCount: 0, hasUpdate: false, latestTitle: local.last?.title ?? "")
        }
        let newCount = max(0, remote.count - local.count)
        let localLast = local.last
        let differs = localLast?.url != remoteLast.url || localLast?.title != remoteLast.title
        return Outcome(
            newChapterCount: newCount,
            hasUpdate: newCount > 0 || differs,
            latestTitle: remoteLast.title
        )
    }
}

/// 跨书源章节名称模糊匹配引擎（智能容错中文字号、阿拉伯数字、括号废话、副标题差异）
nonisolated enum ChapterMatching {
    /// 提取章节序号（如 "第一千二百三十四章" -> 1234, "第 1234 章" -> 1234, "1234." -> 1234）
    static func extractChapterNumber(_ title: String) -> Int? {
        let pattern = #"第\s*([0-9零一二两三四五六七八九十百千万]+)\s*[章回节卷部集]|(?:^|\s)([0-9]+)[\s.、:：]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) else {
            return nil
        }
        if match.range(at: 1).location != NSNotFound {
            let numStr = (title as NSString).substring(with: match.range(at: 1))
            return parseChineseOrArabicNumber(numStr)
        }
        if match.range(at: 2).location != NSNotFound {
            let numStr = (title as NSString).substring(with: match.range(at: 2))
            return Int(numStr)
        }
        return nil
    }

    /// 清理章节标题核心内容（剔除第X章前缀、括号废话、标点符号）
    static func cleanCore(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // 剔除括号及其内部内容（如（求月票）、(第一更)等）
        text = text.replacingOccurrences(of: #"[（\(].*?[）\)]"#, with: "", options: .regularExpression)
        // 剔除前导 "第...章/回/节" 或 "Chapter N"
        text = text.replacingOccurrences(of: #"^第\s*[0-9零一二两三四五六七八九十百千万]+\s*[章回节卷部集][:：\s]*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^(?:chapter|ep|vol)\.?\s*[0-9]+[:：\s]*"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"^[0-9]+[\s.、:：-]+"#, with: "", options: .regularExpression)
        // 剔除所有空白与标点
        text = text.components(separatedBy: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)).joined()
        return text.lowercased()
    }

    /// 中文/阿拉伯数字混合解析
    static func parseChineseOrArabicNumber(_ raw: String) -> Int? {
        if let arabic = Int(raw) { return arabic }
        let map: [Character: Int] = [
            "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
            "六": 6, "七": 7, "八": 8, "九": 9
        ]
        var total = 0
        var current = 0
        for char in raw {
            if let val = map[char] {
                current = val
            } else if char == "十" {
                current = current == 0 ? 1 : current
                total += current * 10
                current = 0
            } else if char == "百" {
                current = current == 0 ? 1 : current
                total += current * 100
                current = 0
            } else if char == "千" {
                current = current == 0 ? 1 : current
                total += current * 1000
                current = 0
            } else if char == "万" {
                total = (total + current) * 10000
                current = 0
            }
        }
        total += current
        return total > 0 ? total : nil
    }

    /// 在候选章节列表中寻找最佳匹配下标
    static func bestMatch(wantedTitle: String, in candidates: [String]) -> Int? {
        guard !candidates.isEmpty else { return nil }
        let wantedNorm = BookIdentity.normalize(wantedTitle)
        // 1. 完全精确一致
        if let exact = candidates.firstIndex(where: { BookIdentity.normalize($0) == wantedNorm }) {
            return exact
        }

        let wantedNum = extractChapterNumber(wantedTitle)
        let wantedCore = cleanCore(wantedTitle)

        // 2. 章节序号完全一致，且核心标题相似或不冲突
        if let wantedNum {
            for (idx, candidate) in candidates.enumerated() {
                if let num = extractChapterNumber(candidate), num == wantedNum {
                    return idx
                }
            }
        }

        // 3. 核心文本完全一致（非空）
        if !wantedCore.isEmpty && wantedCore.count >= 2 {
            for (idx, candidate) in candidates.enumerated() {
                let candidateCore = cleanCore(candidate)
                if candidateCore == wantedCore {
                    return idx
                }
            }
            // 4. 包含匹配
            for (idx, candidate) in candidates.enumerated() {
                let candidateCore = cleanCore(candidate)
                if !candidateCore.isEmpty && (candidateCore.contains(wantedCore) || wantedCore.contains(candidateCore)) {
                    return idx
                }
            }
        }

        return nil
    }
}
