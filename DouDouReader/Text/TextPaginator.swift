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

        let pages = ChapterLayouter.appendPages(
            layoutManager: layout,
            storageLength: length,
            pageSize: pageSize,
            from: 0,
            pageBudget: 100_000
        )
        var result = pages.ranges
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

    var pageSize: CGSize { containers.first?.size ?? .zero }

    /// 在已有的 layoutManager 上继续往后排，直到凑够 targetPages 页或整章排完。
    ///
    /// 复用首屏分页已经排出的部分，代价只与「新增的页」成正比：跨页快翻不再每翻一页
    /// 都从章首重排一遍，重排/恢复进度也不必为了后半章把整章重新构建一次。
    /// 分页循环与一次性排完共用 `ChapterLayouter.appendPages`，页边界不会分歧。
    /// TextKit 对象非线程安全，续排只允许在主线程发生。
    @MainActor
    func extended(toPageCount targetPages: Int) -> ChapterLayout {
        guard !isComplete, pageSize.width >= 20, pageSize.height >= 20 else { return self }
        // 续排会往同一个 layoutManager 上追加容器。拿到过期对象（它之后已经有人续排过）再排，
        // 新容器会接在已有的最后一个容器后面，中间的正文被整段跳过。这种情况原样退回，
        // 由调用方改用缓存里最新的那份。
        guard layoutManager.textContainers.count == containers.count else { return self }
        let budget = targetPages >= pageCount ? targetPages - pageCount : 0
        guard budget > 0 else { return self }
        let appended = ChapterLayouter.appendPages(
            layoutManager: layoutManager,
            storageLength: storage.length,
            pageSize: pageSize,
            from: coveredEnd,
            pageBudget: budget
        )
        guard let last = appended.ranges.last else { return self }
        let ranges = characterRanges + appended.ranges
        return ChapterLayout(
            storage: storage,
            layoutManager: layoutManager,
            delegate: delegate,
            containers: containers + appended.containers,
            characterRanges: ranges,
            titlePrefix: titlePrefix,
            sourceBodyUTF16: sourceBodyUTF16,
            composedBodyUTF16: composedBodyUTF16,
            isComplete: NSMaxRange(last) >= storage.length
        )
    }

    @MainActor
    func completed() -> ChapterLayout {
        extended(toPageCount: Int.max)
    }
}

nonisolated enum ChapterLayouter {
    /// 从 startLocation 起，往同一个 layoutManager 上继续追加页面容器，每页一个 container。
    /// 一次排完与增量续排都走这里，页边界因此只有一份实现。
    nonisolated static func appendPages(
        layoutManager: NSLayoutManager,
        storageLength: Int,
        pageSize: CGSize,
        from startLocation: Int,
        pageBudget: Int
    ) -> (containers: [NSTextContainer], ranges: [NSRange]) {
        var containers: [NSTextContainer] = []
        var ranges: [NSRange] = []
        let budget = min(max(pageBudget, 1), 100_000)
        var location = max(0, startLocation)
        while location < storageLength && ranges.count < budget {
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
                ranges.append(NSRange(location: location, length: storageLength - location))
                containers.append(container)
                break
            }
            ranges.append(charRange)
            containers.append(container)
            location = NSMaxRange(charRange)
        }
        return (containers, ranges)
    }

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
        let length = storage.length
        var pages = appendPages(
            layoutManager: layoutManager,
            storageLength: length,
            pageSize: pageSize,
            from: 0,
            pageBudget: maxPages
        )
        if pages.ranges.isEmpty {
            let container = NSTextContainer(size: pageSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            pages = ([container], [NSRange(location: 0, length: length)])
        }
        return ChapterLayout(
            storage: storage,
            layoutManager: layoutManager,
            delegate: delegate,
            containers: pages.containers,
            characterRanges: pages.ranges,
            titlePrefix: built.titlePrefix,
            sourceBodyUTF16: sourceBodyUTF16,
            composedBodyUTF16: built.bodyUTF16,
            isComplete: pages.ranges.last.map { NSMaxRange($0) >= length } ?? true
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
