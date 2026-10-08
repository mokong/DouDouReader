import Foundation
#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum ChapterTextBuilder {
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

    private static func filteredParagraphs(_ body: String, blockWords: String) -> [String] {
        let words = blockWords
            .split { " ,，;；\n".contains($0) }
            .map(String.init)
            .filter { !$0.isEmpty }
        return body
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { paragraph in
                guard !paragraph.isEmpty else { return false }
                return !words.contains { paragraph.contains($0) }
            }
    }

    private static func nsAlignment(_ choice: TextAlignmentChoice) -> NSTextAlignment {
        switch choice {
        case .left: .left
        case .center: .center
        case .right: .right
        }
    }
}
