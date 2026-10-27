import Foundation
#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

nonisolated final class ChapterLayoutManagerDelegate: NSObject, NSLayoutManagerDelegate {
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        lineSpacingAfterGlyphAt glyphIndex: Int,
        withProposedLineFragmentRect rect: CGRect
    ) -> CGFloat {
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard let storage = layoutManager.textStorage, charIndex < storage.length else {
            return 0
        }
        let style = storage.attribute(.paragraphStyle, at: charIndex, effectiveRange: nil) as? NSParagraphStyle
        return style?.lineSpacing ?? 0
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        paragraphSpacingAfterGlyphAt glyphIndex: Int,
        withProposedLineFragmentRect rect: CGRect
    ) -> CGFloat {
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard let storage = layoutManager.textStorage, charIndex < storage.length else {
            return 0
        }
        let style = storage.attribute(.paragraphStyle, at: charIndex, effectiveRange: nil) as? NSParagraphStyle
        return style?.paragraphSpacing ?? 0
    }
}

enum TextPaginator {
    /// Fills one text container per page so each range is exactly what that page draws.
    static func ranges(for text: NSAttributedString, pageSize: CGSize) -> [NSRange] {
        let length = text.length
        guard length > 0, pageSize.width >= 20, pageSize.height >= 20 else {
            return [NSRange(location: 0, length: length)]
        }

        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        let delegate = ChapterLayoutManagerDelegate()
        layout.delegate = delegate
        storage.addLayoutManager(layout)

        var result: [NSRange] = []
        var location = 0
        while location < length && result.count < 100_000 {
            let container = NSTextContainer(size: pageSize)
            container.lineFragmentPadding = 0
            container.lineBreakMode = .byCharWrapping
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            let glyphRange = layout.glyphRange(for: container)
            var charRange = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            if charRange.location < location {
                let end = NSMaxRange(charRange)
                charRange = NSRange(location: location, length: max(0, end - location))
            }
            if charRange.length == 0 || NSMaxRange(charRange) <= location {
                result.append(NSRange(location: location, length: length - location))
                break
            }
            result.append(charRange)
            location = NSMaxRange(charRange)
        }
        if result.isEmpty {
            return [NSRange(location: 0, length: length)]
        }
        if let last = result.last, NSMaxRange(last) < length {
            result.append(NSRange(location: NSMaxRange(last), length: length - NSMaxRange(last)))
        }
        _ = delegate
        return result
    }
}

/// TextKit 对象不是线程安全的：本类在单一线程上构造完成后，只交给主线程读取绘制，
/// 不做跨线程可变访问，因此可以按「线程限定」而非「线程安全」对外承诺 Sendable。
nonisolated final class ChapterLayout: @unchecked Sendable {
    let storage: NSTextStorage
    let layoutManager: NSLayoutManager
    let delegate: ChapterLayoutManagerDelegate
    let containers: [NSTextContainer]
    let characterRanges: [NSRange]
    let titlePrefix: Int
    let sourceBodyUTF16: Int
    let composedBodyUTF16: Int
    /// false 表示只排了开头几页（首屏分页），剩下的页仍需在后台补完。
    let isComplete: Bool

    init(
        storage: NSTextStorage,
        layoutManager: NSLayoutManager,
        delegate: ChapterLayoutManagerDelegate,
        containers: [NSTextContainer],
        characterRanges: [NSRange],
        titlePrefix: Int,
        sourceBodyUTF16: Int,
        composedBodyUTF16: Int,
        isComplete: Bool
    ) {
        self.storage = storage
        self.layoutManager = layoutManager
        self.delegate = delegate
        self.containers = containers
        self.characterRanges = characterRanges
        self.titlePrefix = titlePrefix
        self.sourceBodyUTF16 = sourceBodyUTF16
        self.composedBodyUTF16 = composedBodyUTF16
        self.isComplete = isComplete
    }

    /// 已排出的页数。首屏分页时它只是「已知页数」，不代表整章页数。
    var pageCount: Int { max(characterRanges.count, 1) }

    /// 排到的最后一个字符位置。
    var coveredEnd: Int { characterRanges.last.map(NSMaxRange) ?? 0 }

    /// 整章是否都已排出页边界。翻到章末的判定只能信这个，不能信 pageCount。
    var coversWholeChapter: Bool {
        isComplete || coveredEnd >= storage.length
    }

    var mayHaveMoreContent: Bool { !coversWholeChapter }

    /// 页码分母：完整排版用真实页数，否则按已排页面的平均字数估算。
    var estimatedPageCount: Int {
        if coversWholeChapter { return pageCount }
        let known = characterRanges.count
        guard known > 0, coveredEnd > 0 else { return pageCount + 1 }
        let remaining = max(0, storage.length - coveredEnd)
        let perPage = max(1, coveredEnd / known)
        return pageCount + max(1, (remaining + perPage - 1) / perPage)
    }

    /// 目标页是否已在已知页范围内。
    func covers(page index: Int) -> Bool {
        characterRanges.indices.contains(index)
    }

    func plainText(page index: Int) -> String {
        guard characterRanges.indices.contains(index) else { return "" }
        return storage.attributedSubstring(from: characterRanges[index]).string
    }
}

nonisolated enum ChapterLayouter {
    static func layout(
        title: String,
        body: String,
        sourceBodyUTF16: Int,
        snapshot: LayoutSnapshot,
        theme: ReadingTheme,
        pageSize: CGSize,
        maxPages: Int = .max
    ) -> ChapterLayout {
        let built = ChapterTextBuilder.make(
            title: title,
            body: body,
            fontName: snapshot.fontName,
            fontSize: CGFloat(snapshot.fontSize),
            lineSpacing: CGFloat(snapshot.lineSpacing),
            paragraphSpacing: CGFloat(snapshot.paragraphSpacing),
            indentChars: snapshot.indentChars,
            kern: CGFloat(snapshot.kern),
            alignment: TextAlignmentChoice(rawValue: snapshot.alignment) ?? .left,
            color: theme.text.platform,
            blockWords: snapshot.blockWords
        )
        let storage = NSTextStorage(attributedString: built.text)
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = false
        let delegate = ChapterLayoutManagerDelegate()
        layoutManager.delegate = delegate
        storage.addLayoutManager(layoutManager)
        var containers: [NSTextContainer] = []
        var ranges: [NSRange] = []
        let length = storage.length
        let pageBudget = min(max(maxPages, 1), 100_000)
        var location = 0
        while location < length && ranges.count < pageBudget {
            let container = NSTextContainer(size: pageSize)
            container.lineFragmentPadding = 0
            container.lineBreakMode = .byCharWrapping
            layoutManager.addTextContainer(container)
            layoutManager.ensureLayout(for: container)
            let glyphRange = layoutManager.glyphRange(for: container)
            var charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            if charRange.location < location {
                let end = NSMaxRange(charRange)
                charRange = NSRange(location: location, length: max(0, end - location))
            }
            if charRange.length == 0 || NSMaxRange(charRange) <= location {
                ranges.append(NSRange(location: location, length: length - location))
                containers.append(container)
                break
            }
            ranges.append(charRange)
            containers.append(container)
            location = NSMaxRange(charRange)
        }
        if ranges.isEmpty {
            let container = NSTextContainer(size: pageSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            containers = [container]
            ranges = [NSRange(location: 0, length: length)]
        }
        return ChapterLayout(
            storage: storage,
            layoutManager: layoutManager,
            delegate: delegate,
            containers: containers,
            characterRanges: ranges,
            titlePrefix: built.titlePrefix,
            sourceBodyUTF16: sourceBodyUTF16,
            composedBodyUTF16: built.bodyUTF16,
            isComplete: ranges.last.map { NSMaxRange($0) >= length } ?? true
        )
    }
}

/// 一次排版所需的全部输入。字段都是值类型，因此可以整体带到后台线程执行，
/// 简繁转换与屏蔽词过滤也一并离开主线程。
nonisolated struct ChapterLayoutJob: Sendable {
    var title: String
    var body: String
    var script: ChineseScript
    var snapshot: LayoutSnapshot
    var theme: ReadingTheme
    var pageSize: CGSize
    var maxPages: Int

    func run() -> ChapterLayout {
        ChapterLayouter.layout(
            title: ChineseConverter.convert(title, to: script),
            body: ChineseConverter.convert(body, to: script),
            sourceBodyUTF16: (body as NSString).length,
            snapshot: snapshot,
            theme: theme,
            pageSize: pageSize,
            maxPages: maxPages
        )
    }
}
