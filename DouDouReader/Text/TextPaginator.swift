import Foundation
#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

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
        return result
    }
}

final class ChapterLayout {
    let storage: NSTextStorage
    let layoutManager: NSLayoutManager
    let containers: [NSTextContainer]
    let characterRanges: [NSRange]
    let titlePrefix: Int
    let sourceBodyUTF16: Int
    let composedBodyUTF16: Int

    init(
        storage: NSTextStorage,
        layoutManager: NSLayoutManager,
        containers: [NSTextContainer],
        characterRanges: [NSRange],
        titlePrefix: Int,
        sourceBodyUTF16: Int,
        composedBodyUTF16: Int
    ) {
        self.storage = storage
        self.layoutManager = layoutManager
        self.containers = containers
        self.characterRanges = characterRanges
        self.titlePrefix = titlePrefix
        self.sourceBodyUTF16 = sourceBodyUTF16
        self.composedBodyUTF16 = composedBodyUTF16
    }

    var pageCount: Int { max(characterRanges.count, 1) }

    func plainText(page index: Int) -> String {
        guard characterRanges.indices.contains(index) else { return "" }
        return storage.attributedSubstring(from: characterRanges[index]).string
    }
}

enum ChapterLayouter {
    static func layout(
        title: String,
        body: String,
        sourceBodyUTF16: Int,
        snapshot: LayoutSnapshot,
        theme: ReadingTheme,
        pageSize: CGSize
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
        storage.addLayoutManager(layoutManager)
        var containers: [NSTextContainer] = []
        var ranges: [NSRange] = []
        let length = storage.length
        var location = 0
        while location < length && ranges.count < 100_000 {
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
            containers: containers,
            characterRanges: ranges,
            titlePrefix: built.titlePrefix,
            sourceBodyUTF16: sourceBodyUTF16,
            composedBodyUTF16: built.bodyUTF16
        )
    }
}
