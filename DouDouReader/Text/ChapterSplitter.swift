import Foundation

nonisolated struct ChapterSlice: Equatable, Sendable {
    var index: Int
    var title: String
    var lineStart: Int
    var bodyStart: Int
    var bodyEnd: Int
    /// 在线目录里的下标。本地书与 index 相同。
    var remoteIndex: Int

    init(index: Int, title: String, lineStart: Int, bodyStart: Int, bodyEnd: Int, remoteIndex: Int? = nil) {
        self.index = index
        self.title = title
        self.lineStart = lineStart
        self.bodyStart = bodyStart
        self.bodyEnd = bodyEnd
        self.remoteIndex = remoteIndex ?? index
    }
}

nonisolated enum ChapterSplitter {
    /// EPUB 标题常常带标点，也不一定写成「第…章」。这一行以不可见分隔符开头时，整行就是章节标题。
    static let forcedHeadingPrefix = "\u{2063}"

    private static let pattern = #"^(第[0-9０-９零〇一二三四五六七八九十百千万两]{1,12}[章回节卷部集].*|序\s*章.*|楔\s*子.*|前\s*言.*|引\s*子.*|尾\s*声.*|后\s*记.*|番外.*|[Cc]hapter\s+\d+.*)$"#
    private static let punctuation = CharacterSet(charactersIn: "，。！？；：、,.!?;:")

    private static let regex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: pattern)
    }()

    static func split(_ text: String, fallbackTitle: String) -> [ChapterSlice] {
        let ns = text as NSString
        var location = 0
        var marks: [(title: String, lineStart: Int, bodyStart: Int)] = []
        let forcedChar = forcedHeadingPrefix.utf16.first!

        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            let len = lineRange.length
            if len > 0 {
                let firstChar = ns.character(at: lineRange.location)
                if firstChar == forcedChar || len <= 120 {
                    let trimmed = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
                    if isHeading(trimmed) {
                        marks.append((displayTitle(trimmed), lineRange.location, NSMaxRange(lineRange)))
                    }
                }
            }
            let next = NSMaxRange(lineRange)
            if next <= location { break }
            location = next
        }

        var slices: [ChapterSlice] = []
        if marks.isEmpty {
            slices.append(
                ChapterSlice(
                    index: 0,
                    title: fallbackTitle.isEmpty ? "正文" : fallbackTitle,
                    lineStart: 0,
                    bodyStart: 0,
                    bodyEnd: ns.length
                )
            )
            return slices
        }

        if let first = marks.first, first.lineStart > 0 {
            let preface = ns.substring(with: NSRange(location: 0, length: first.lineStart))
            if !preface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                slices.append(
                    ChapterSlice(
                        index: slices.count,
                        title: "开头",
                        lineStart: 0,
                        bodyStart: 0,
                        bodyEnd: first.lineStart
                    )
                )
            }
        }

        for (offset, mark) in marks.enumerated() {
            let end = offset + 1 < marks.count ? marks[offset + 1].lineStart : ns.length
            slices.append(
                ChapterSlice(
                    index: slices.count,
                    title: mark.title,
                    lineStart: mark.lineStart,
                    bodyStart: min(mark.bodyStart, end),
                    bodyEnd: max(end, mark.bodyStart)
                )
            )
        }
        return slices
    }

    static func substring(_ text: String, start: Int, end: Int) -> String {
        let ns = text as NSString
        let lower = min(max(0, start), ns.length)
        let upper = min(max(lower, end), ns.length)
        return ns.substring(with: NSRange(location: lower, length: upper - lower))
    }

    static func isHeading(_ line: String) -> Bool {
        if line.hasPrefix(forcedHeadingPrefix) {
            return !displayTitle(line).isEmpty
        }
        guard !line.isEmpty, line.count <= 40 else { return false }
        guard line.rangeOfCharacter(from: punctuation) == nil else { return false }
        guard let regex else { return false }
        let range = NSRange(location: 0, length: (line as NSString).length)
        return regex.firstMatch(in: line, options: [], range: range) != nil
    }

    static func displayTitle(_ line: String) -> String {
        var title = line
        if title.hasPrefix(forcedHeadingPrefix) {
            title.removeFirst()
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
