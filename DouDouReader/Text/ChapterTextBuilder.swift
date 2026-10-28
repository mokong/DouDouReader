import Foundation
#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

nonisolated enum ChapterTextBuilder {
    static func make(
        title: String,
        body: String,
        fontName: String,
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat,
        indentChars: Int,
        kern: CGFloat,
        alignment: TextAlignmentChoice,
        color: AppColor,
        blockWords: String
    ) -> (text: NSAttributedString, titlePrefix: Int, bodyUTF16: Int) {
        let result = NSMutableAttributedString()
        let textAlignment = nsAlignment(alignment)
        if !title.isEmpty {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineSpacing = lineSpacing
            style.paragraphSpacing = paragraphSpacing + 6
            style.lineBreakMode = .byCharWrapping
            let titleFont = PlatformFont.make(name: fontName, size: fontSize + 4, bold: true)
            result.append(
                NSAttributedString(
                    string: title + "\n",
                    attributes: [
                        .font: titleFont,
                        .foregroundColor: color,
                        .paragraphStyle: style,
                    ]
                )
            )
        }
        let titlePrefix = result.length
        let paragraphs = filteredParagraphs(body, blockWords: blockWords)
        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.alignment = textAlignment
        bodyStyle.lineSpacing = lineSpacing
        bodyStyle.paragraphSpacing = paragraphSpacing
        bodyStyle.lineBreakMode = .byCharWrapping
        bodyStyle.allowsDefaultTighteningForTruncation = true
        bodyStyle.hyphenationFactor = 0.8
        bodyStyle.firstLineHeadIndent = fontSize * CGFloat(indentChars)
        let font = PlatformFont.make(name: fontName, size: fontSize)
        for (index, paragraph) in paragraphs.enumerated() {
            let suffix = index == paragraphs.count - 1 ? "" : "\n"
            result.append(
                NSAttributedString(
                    string: paragraph + suffix,
                    attributes: [
                        .font: font,
                        .foregroundColor: color,
                        .paragraphStyle: bodyStyle,
                        .kern: kern,
                    ]
                )
            )
        }
        if result.length == 0 {
            let font = PlatformFont.make(name: fontName, size: fontSize)
            result.append(NSAttributedString(string: "本章没有正文", attributes: [
                .font: font,
                .foregroundColor: color,
            ]))
        }
        let bodyUTF16 = result.length - titlePrefix
        return (result, titlePrefix, bodyUTF16)
    }

    static func plainParagraphs(_ body: String, blockWords: String) -> String {
        filteredParagraphs(body, blockWords: blockWords).joined(separator: "\n")
    }

    private nonisolated enum purifyRule {
        case replace(pattern: String, replacement: String, isRegex: Bool)
        case block(word: String)
    }

    private static func parsePurifyRules(_ raw: String) -> [purifyRule] {
        // 先按换行、分号、逗号切分，支持 `广告词=>替换词`、`re:正则=>替换` 以及普通关键词
        let tokens = raw
            .split { "\n;；,，".contains($0) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var rules: [purifyRule] = []
        for token in tokens {
            if let arrowRange = token.range(of: "=>") {
                var lhs = String(token[..<arrowRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let rhs = String(token[arrowRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                var isRegex = false
                if lhs.hasPrefix("re:") {
                    lhs = String(lhs.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    isRegex = true
                }
                if !lhs.isEmpty {
                    rules.append(.replace(pattern: lhs, replacement: rhs, isRegex: isRegex))
                }
            } else {
                // 普通词内部若用空格分隔了多个短词，也拆开
                let subWords = token.split(separator: " ").map(String.init).filter { !$0.isEmpty }
                for word in subWords {
                    rules.append(.block(word: word))
                }
            }
        }
        return rules
    }

    private static func filteredParagraphs(_ body: String, blockWords: String) -> [String] {
        let rules = parsePurifyRules(blockWords)
        let lines = body
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !rules.isEmpty else { return lines }

        var result: [String] = []
        result.reserveCapacity(lines.count)
        for line in lines {
            var current = line
            var dropEntireLine = false
            for rule in rules {
                switch rule {
                case .replace(let pattern, let replacement, let isRegex):
                    if isRegex {
                        current = current.replacingOccurrences(
                            of: pattern,
                            with: replacement,
                            options: .regularExpression
                        )
                    } else {
                        current = current.replacingOccurrences(of: pattern, with: replacement)
                    }
                case .block(let word):
                    guard current.contains(word) else { continue }
                    // 独立短句广告行（<= 35 字）直接整段剔除；长正文段内嵌的水印则只抹除该词本身，保留段落正文
                    if current.count <= 35 {
                        dropEntireLine = true
                        break
                    } else {
                        current = current.replacingOccurrences(of: word, with: "")
                    }
                }
            }
            if dropEntireLine { continue }
            // 清理因抹除内嵌广告词留下的空括号
            for emptyPair in ["()", "（）", "【】", "[]"] {
                if current.contains(emptyPair) {
                    current = current.replacingOccurrences(of: emptyPair, with: "")
                }
            }
            let cleaned = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                result.append(cleaned)
            }
        }
        return result
    }

    private static func nsAlignment(_ choice: TextAlignmentChoice) -> NSTextAlignment {
        switch choice {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justified: .justified
        }
    }
}
