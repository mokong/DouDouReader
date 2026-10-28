import Foundation

nonisolated struct ParsedEpub: Sendable {
    var title: String
    var author: String
    var text: String
    var coverData: Data? = nil
}

nonisolated enum EpubParseError: LocalizedError {
    case damaged
    case encrypted
    case empty
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .damaged: "这本 EPUB 打不开"
        case .encrypted: "这本 EPUB 加了密，打不开"
        case .empty: "这本 EPUB 没有正文"
        case .tooLarge: "文件超过 40MB"
        }
    }
}

nonisolated enum EpubParser {
    private static let byteLimit = 40 * 1024 * 1024

    static func isEpub(_ data: Data, filename: String) -> Bool {
        if (filename as NSString).pathExtension.lowercased() == "epub" { return true }
        guard data.count >= 4 else { return false }
        let prefix = [UInt8](data.prefix(2))
        guard prefix == [0x50, 0x4B] else { return false }
        guard let archive = try? ZipArchive.open(data) else { return false }
        return (try? archive.file("META-INF/container.xml")) != nil
    }

    static func parse(_ data: Data) throws -> ParsedEpub {
        let archive: ZipArchive
        do {
            archive = try ZipArchive.open(data)
        } catch ZipError.tooLarge {
            throw EpubParseError.tooLarge
        } catch {
            throw EpubParseError.damaged
        }
        guard let container = try load(archive, "META-INF/container.xml") else { throw EpubParseError.damaged }
        let rootfile = Markup.parse(container)
            .elements(named: "rootfile")
            .compactMap { $0.attribute("full-path") }
            .first { !$0.isEmpty }
        guard let rootfile else { throw EpubParseError.damaged }
        let opfPath = ZipArchive.normalize(rootfile)
        guard let opf = try load(archive, opfPath) else { throw EpubParseError.damaged }
        let package = Markup.parse(opf)
        let book = try readBook(package, opfPath: opfPath, archive: archive)
        guard !book.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EpubParseError.empty
        }
        return book
    }

    private static func readBook(_ package: Markup.Node, opfPath: String, archive: ZipArchive) throws -> ParsedEpub {
        let title = package.elements(named: "title").map(\.text).first { !$0.isEmpty } ?? ""
        let creators = package.elements(named: "creator").filter { !$0.text.isEmpty }
        let author = creators.first {
            ($0.attribute("role") ?? "").caseInsensitiveCompare("aut") == .orderedSame
        }?.text ?? creators.first?.text ?? ""

        var manifest: [String: ManifestItem] = [:]
        for item in package.elements(named: "item") {
            guard let id = item.attribute("id"), !id.isEmpty else { continue }
            let href = item.attribute("href") ?? ""
            let located = locate(href, relativeTo: opfPath)
            guard !located.path.isEmpty else { continue }
            manifest[id] = ManifestItem(
                path: located.path,
                mediaType: (item.attribute("media-type") ?? "").lowercased(),
                properties: item.attribute("properties") ?? ""
            )
        }

        let encrypted = try encryptedPaths(archive)
        var spine: [ManifestItem] = []
        var readable: [ManifestItem] = []
        for itemref in package.elements(named: "itemref") {
            guard let id = itemref.attribute("idref"), let item = manifest[id] else { continue }
            guard isDocument(item), !isNavigation(item) else { continue }
            readable.append(item)
            let linear = (itemref.attribute("linear") ?? "yes").caseInsensitiveCompare("no") != .orderedSame
            if linear { spine.append(item) }
        }
        if spine.isEmpty { spine = readable }

        var toc = tableOfContents(manifest, opfPath: opfPath, archive: archive)
        if toc.isEmpty {
            toc = try navigationControl(manifest, archive: archive)
        }

        var chapters: [ChapterDraft] = []
        var ordinal = 1
        for item in spine {
            if encrypted.contains(item.path) { throw EpubParseError.encrypted }
            guard let html = try load(archive, item.path) else { continue }
            let slices = HTMLText.slices(Markup.parse(html), splitIDs: fragmentIDs(toc, path: item.path))
            let related = toc.filter { $0.path == item.path }
            ordinal = appendChapters(
                slices,
                toc: related,
                into: &chapters,
                ordinal: ordinal
            )
        }
        let text = render(chapters)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EpubParseError.empty }
        guard text.utf8.count <= byteLimit else { throw EpubParseError.tooLarge }
        let coverData = extractCoverData(package, manifest: manifest, encrypted: encrypted, archive: archive)
        return ParsedEpub(title: title, author: author, text: text, coverData: coverData)
    }

    private static func extractCoverData(
        _ package: Markup.Node,
        manifest: [String: ManifestItem],
        encrypted: Set<String>,
        archive: ZipArchive
    ) -> Data? {
        let coverLimit = 8 * 1024 * 1024
        var candidates: [ManifestItem] = []

        // 1. EPUB 3 标准：properties="cover-image"
        for item in manifest.values where isImageItem(item) && isCoverProperty(item) {
            candidates.append(item)
        }

        // 2. EPUB 2 标准：<meta name="cover" content="cover-id"/>
        for meta in package.elements(named: "meta") {
            guard (meta.attribute("name") ?? "").caseInsensitiveCompare("cover") == .orderedSame,
                  let content = meta.attribute("content")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else { continue }
            if let item = manifest[content], isImageItem(item) {
                candidates.append(item)
            } else if let byPath = manifest.values.first(where: { isImageItem($0) && $0.path.hasSuffix(content) }) {
                candidates.append(byPath)
            }
        }

        // 3. 常见 ID 或文件名回退（cover / cover-image / cover.jpg / cover.png）
        for key in ["cover", "cover-image", "cover_img", "coverimage"] {
            if let item = manifest[key], isImageItem(item) {
                candidates.append(item)
            }
        }
        for item in manifest.values where isImageItem(item) {
            let filename = (item.path as NSString).lastPathComponent.lowercased()
            if filename.hasPrefix("cover.") || filename.contains("cover") {
                candidates.append(item)
            }
        }

        var tried = Set<String>()
        for item in candidates {
            guard tried.insert(item.path).inserted, !encrypted.contains(item.path) else { continue }
            if let data = try? archive.file(item.path), !data.isEmpty, data.count <= coverLimit {
                return data
            }
        }
        return nil
    }

    private static func isImageItem(_ item: ManifestItem) -> Bool {
        if item.mediaType.hasPrefix("image/") && !item.mediaType.contains("svg") {
            return true
        }
        let ext = (item.path as NSString).pathExtension.lowercased()
        return ext == "jpg" || ext == "jpeg" || ext == "png" || ext == "webp" || ext == "gif"
    }

    private static func isCoverProperty(_ item: ManifestItem) -> Bool {
        item.properties.split(whereSeparator: \.isWhitespace).contains {
            $0.caseInsensitiveCompare("cover-image") == .orderedSame
        }
    }

    private static func appendChapters(
        _ slices: [HTMLSlice],
        toc: [TocEntry],
        into chapters: inout [ChapterDraft],
        ordinal: Int
    ) -> Int {
        var next = ordinal
        let content = slices.filter(\.hasText)
        guard !content.isEmpty else { return next }
        let fragments = toc.filter { !$0.fragment.isEmpty }
        if fragments.isEmpty {
            if content.count == 1 {
                let heading = content[0].heading
                let title = toc.first?.title ?? heading
                _ = append(title: title, paragraphs: content[0].paragraphs, into: &chapters, ordinal: &next)
            } else {
                for slice in content {
                    _ = append(title: slice.heading, paragraphs: slice.paragraphs, into: &chapters, ordinal: &next)
                }
            }
            return next
        }

        if let preface = content.first(where: { $0.anchor == nil }) {
            _ = append(title: preface.heading.isEmpty ? "开头" : preface.heading, paragraphs: preface.paragraphs, into: &chapters, ordinal: &next)
        }
        var matched = Set<String>()
        for entry in fragments {
            guard let slice = content.first(where: { $0.anchor == entry.fragment }) else { continue }
            matched.insert(entry.fragment)
            _ = append(title: entry.title.isEmpty ? slice.heading : entry.title, paragraphs: slice.paragraphs, into: &chapters, ordinal: &next)
        }
        for slice in content where slice.anchor != nil && !matched.contains(slice.anchor ?? "") {
            _ = append(title: slice.heading, paragraphs: slice.paragraphs, into: &chapters, ordinal: &next)
        }
        return next
    }

    @discardableResult
    private static func append(
        title: String,
        paragraphs: [String],
        into chapters: inout [ChapterDraft],
        ordinal: inout Int
    ) -> Bool {
        var body = paragraphs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let cleaned = squash(title)
        let shown = cleaned.isEmpty ? "第\(ordinal)章" : cleaned
        if let first = body.first, first == shown || first == cleaned {
            body.removeFirst()
        }
        guard !body.isEmpty else { return false }
        chapters.append(ChapterDraft(title: shown, paragraphs: body))
        ordinal += 1
        return true
    }

    private static func render(_ chapters: [ChapterDraft]) -> String {
        var lines: [String] = []
        for chapter in chapters {
            lines.append(ChapterSplitter.forcedHeadingPrefix + chapter.title)
            lines.append(contentsOf: chapter.paragraphs)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func tableOfContents(_ manifest: [String: ManifestItem], opfPath: String, archive: ZipArchive) -> [TocEntry] {
        guard let nav = manifest.values.first(where: isNavigation),
              let html = try? load(archive, nav.path) else { return [] }
        let document = Markup.parse(html)
        let navs = document.elements(named: "nav")
        let chosen = navs.filter { tocType($0.attribute("type") ?? "") }
        let roots = chosen.isEmpty ? (navs.isEmpty ? [document] : navs) : chosen
        var entries: [TocEntry] = []
        for root in roots {
            for node in root.elements(named: "a") {
                guard let href = node.attribute("href"), !href.isEmpty else { continue }
                let title = squash(node.text)
                guard !title.isEmpty else { continue }
                let located = locate(href, relativeTo: nav.path)
                guard !located.path.isEmpty else { continue }
                entries.append(TocEntry(path: located.path, fragment: located.fragment, title: title))
            }
        }
        return entries
    }

    private static func navigationControl(_ manifest: [String: ManifestItem], archive: ZipArchive) throws -> [TocEntry] {
        guard let ncx = manifest.values.first(where: { $0.mediaType.contains("ncx") || $0.path.lowercased().hasSuffix(".ncx") }),
              let xml = try load(archive, ncx.path) else { return [] }
        var entries: [TocEntry] = []
        for point in Markup.parse(xml).elements(named: "navpoint") {
            let label = point.children.first { $0.name == "navlabel" }?.elements(named: "text").first?.text ?? ""
            let src = point.children.first { $0.name == "content" }?.attribute("src") ?? ""
            let title = squash(label)
            guard !title.isEmpty, !src.isEmpty else { continue }
            let located = locate(src, relativeTo: ncx.path)
            guard !located.path.isEmpty else { continue }
            entries.append(TocEntry(path: located.path, fragment: located.fragment, title: title))
        }
        return entries
    }

    private static func encryptedPaths(_ archive: ZipArchive) throws -> Set<String> {
        guard let xml = try load(archive, "META-INF/encryption.xml") else { return [] }
        var paths = Set<String>()
        for node in Markup.parse(xml).elements(named: "cipherreference") {
            guard let uri = node.attribute("uri"), !uri.isEmpty else { continue }
            paths.insert(locate(uri, relativeTo: "").path)
        }
        return paths
    }

    private static func fragmentIDs(_ toc: [TocEntry], path: String) -> Set<String> {
        Set(toc.filter { $0.path == path && !$0.fragment.isEmpty }.map(\.fragment))
    }

    private static func isDocument(_ item: ManifestItem) -> Bool {
        let type = item.mediaType
        if type.contains("ncx") || type.contains("svg") || type.contains("image") || type.contains("css") || type.contains("font") {
            return false
        }
        if type.contains("html") { return true }
        let ext = (item.path as NSString).pathExtension.lowercased()
        return ext == "xhtml" || ext == "html" || ext == "htm"
    }

    private static func isNavigation(_ item: ManifestItem) -> Bool {
        item.properties.split(whereSeparator: \.isWhitespace).contains { $0.caseInsensitiveCompare("nav") == .orderedSame }
    }

    private static func tocType(_ raw: String) -> Bool {
        raw.split(whereSeparator: \.isWhitespace).contains { $0.caseInsensitiveCompare("toc") == .orderedSame }
    }

    private static func locate(_ href: String, relativeTo baseFile: String) -> (path: String, fragment: String) {
        var text = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if let query = text.firstIndex(of: "?") { text = String(text[..<query]) }
        text = text.removingPercentEncoding ?? text
        let hash = text.firstIndex(of: "#")
        let relative = hash.map { String(text[..<$0]) } ?? text
        let fragment = hash.map { String(text[text.index(after: $0)...]) } ?? ""
        if relative.isEmpty {
            return (ZipArchive.normalize(baseFile), fragment)
        }
        let combined: String
        if relative.hasPrefix("/") {
            combined = String(relative.dropFirst())
        } else {
            let directory = (baseFile as NSString).deletingLastPathComponent
            combined = directory.isEmpty || directory == "." ? relative : directory + "/" + relative
        }
        return (ZipArchive.normalize(combined), fragment)
    }

    private static func load(_ archive: ZipArchive, _ path: String) throws -> String? {
        do {
            guard let data = try archive.file(path) else { return nil }
            return decode(data)
        } catch ZipError.encrypted {
            throw EpubParseError.encrypted
        } catch ZipError.tooLarge {
            throw EpubParseError.tooLarge
        } catch {
            throw EpubParseError.damaged
        }
    }

    private static func decode(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let text = String(data: data.dropFirst(3), encoding: .utf8) {
            return text
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: TextDecoding.gb18030) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    private static func squash(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private nonisolated struct ManifestItem {
    var path: String
    var mediaType: String
    var properties: String
}

private nonisolated struct TocEntry {
    var path: String
    var fragment: String
    var title: String
}

private nonisolated struct ChapterDraft {
    var title: String
    var paragraphs: [String]
}

private nonisolated struct HTMLSlice {
    var anchor: String?
    var heading = ""
    var paragraphs: [String] = []

    var hasText: Bool { !paragraphs.isEmpty }
}

private nonisolated enum HTMLText {
    private static let skipped: Set<String> = ["script", "style", "head", "svg", "math", "template", "iframe", "noscript"]
    private static let blocks: Set<String> = [
        "address", "article", "aside", "blockquote", "br", "caption", "dd", "div", "dl", "dt", "figcaption",
        "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "ol", "p", "pre",
        "section", "table", "td", "th", "tr", "ul", "body",
    ]
    private static let headings: Set<String> = ["h1", "h2", "h3"]

    static func slices(_ root: Markup.Node, splitIDs: Set<String>) -> [HTMLSlice] {
        var builder = Builder(splitIDs: splitIDs, splitTags: splitIDs.isEmpty ? headingTags(in: root) : [])
        builder.walk(root)
        builder.flush()
        return builder.slices
    }

    /// 没有目录锚点时，重复出现的标题自己成章。优先用 h1，没有再用 h2、h3。
    private static func headingTags(in root: Markup.Node) -> Set<String> {
        var counts: [String: Int] = [:]
        func walk(_ node: Markup.Node) {
            if skipped.contains(node.name) { return }
            if headings.contains(node.name) {
                counts[node.name, default: 0] += 1
            }
            for child in node.children { walk(child) }
        }
        walk(root)
        for tag in ["h1", "h2", "h3"] where (counts[tag] ?? 0) >= 2 {
            return [tag]
        }
        return []
    }

    private nonisolated struct Builder {
        var splitIDs: Set<String>
        var splitTags: Set<String>
        var slices = [HTMLSlice()]
        var buffer = ""
        var heading = ""
        var headingDepth = 0
        var headingSpace = false
        var pendingSpace = false

        mutating func walk(_ node: Markup.Node) {
            if skipped.contains(node.name) { return }
            if let anchor = node.attribute("id"), splitIDs.contains(anchor) {
                startSlice(anchor: anchor)
            } else if splitTags.contains(node.name) {
                startSlice(anchor: nil)
            }
            let block = blocks.contains(node.name)
            if block { flush() }
            let capture = headings.contains(node.name)
            if capture { headingDepth += 1 }
            for piece in node.pieces {
                switch piece {
                case .text(let text):
                    append(text)
                case .node(let child):
                    walk(child)
                }
            }
            if capture {
                headingDepth -= 1
                if headingDepth == 0 {
                    let cleaned = heading.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    if slices[slices.count - 1].heading.isEmpty, !cleaned.isEmpty {
                        slices[slices.count - 1].heading = cleaned
                    }
                    heading = ""
                    headingSpace = false
                }
            }
            if block { flush() }
        }

        mutating func append(_ raw: String) {
            let decoded = HTMLMiniParser.decodeHTMLEntities(raw)
            for character in decoded {
                if character.isWhitespace {
                    if !buffer.isEmpty { pendingSpace = true }
                    if headingDepth > 0, !heading.isEmpty { headingSpace = true }
                    continue
                }
                if pendingSpace {
                    buffer.append(" ")
                    pendingSpace = false
                }
                buffer.append(character)
                if headingDepth > 0 {
                    if headingSpace {
                        heading.append(" ")
                        headingSpace = false
                    }
                    heading.append(character)
                }
            }
        }

        mutating func startSlice(anchor: String?) {
            flush()
            let current = slices[slices.count - 1]
            if slices.count == 1, current.anchor == nil, current.paragraphs.isEmpty, current.heading.isEmpty, buffer.isEmpty {
                slices[0].anchor = anchor
                return
            }
            slices.append(HTMLSlice(anchor: anchor))
        }

        mutating func flush() {
            let paragraph = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = ""
            pendingSpace = false
            guard !paragraph.isEmpty else { return }
            slices[slices.count - 1].paragraphs.append(paragraph)
        }
    }
}

nonisolated enum Markup {
    nonisolated final class Node {
        var name: String
        var attributes: [String: String]
        var pieces: [Piece] = []

        init(name: String, attributes: [String: String] = [:]) {
            self.name = name
            self.attributes = attributes
        }

        var children: [Node] {
            pieces.compactMap { piece in
                if case .node(let node) = piece { return node }
                return nil
            }
        }

        func attribute(_ name: String) -> String? {
            attributes[name.lowercased()]
        }

        func elements(named local: String) -> [Node] {
            let wanted = local.lowercased()
            var found: [Node] = []
            func walk(_ node: Node) {
                if node.name == wanted { found.append(node) }
                for child in node.children { walk(child) }
            }
            walk(self)
            return found
        }

        var text: String {
            var raw = ""
            for piece in pieces {
                switch piece {
                case .text(let value):
                    raw += value
                case .node(let child):
                    raw += child.text
                }
            }
            return raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }

    nonisolated enum Piece {
        case text(String)
        case node(Node)
    }

    static func parse(_ source: String) -> Node {
        let root = Node(name: "document")
        var stack = [root]
        var index = source.startIndex
        if source.hasPrefix("\u{FEFF}") {
            index = source.index(after: index)
        }
        while index < source.endIndex {
            if source[index] == "<" {
                let next = source.index(after: index)
                if next >= source.endIndex {
                    break
                }
                let mark = source[next]
                if mark == "!" {
                    index = skipDeclaration(source, next)
                } else if mark == "?" {
                    index = skipUntil(source, next, marker: "?>")
                } else if mark == "/" {
                    index = closeTag(source, next, stack: &stack)
                } else {
                    index = openTag(source, index, stack: &stack)
                }
            } else {
                guard let end = source[index...].firstIndex(of: "<") else {
                    appendText(String(source[index...]), to: stack[stack.count - 1])
                    break
                }
                appendText(String(source[index..<end]), to: stack[stack.count - 1])
                index = end
            }
        }
        return root
    }

    private static func openTag(_ source: String, _ start: String.Index, stack: inout [Node]) -> String.Index {
        var index = source.index(after: start)
        let nameStart = index
        while index < source.endIndex, !isTagBoundary(source[index]) {
            index = source.index(after: index)
        }
        let rawName = String(source[nameStart..<index])
        let name = localName(rawName)
        let attributes = readAttributes(source, index: &index)
        var closing = false
        if index < source.endIndex, source[index] == "/" {
            closing = true
            index = source.index(after: index)
        }
        if index < source.endIndex, source[index] == ">" {
            index = source.index(after: index)
        }
        guard !name.isEmpty else { return index }
        let node = Node(name: name, attributes: attributes)
        stack[stack.count - 1].pieces.append(.node(node))
        let void = closing || voidTags.contains(name)
        if !void {
            stack.append(node)
            if name == "script" || name == "style" {
                index = skipRaw(source, index, name: name)
                if stack.count > 1 { stack.removeLast() }
            }
        }
        return index
    }

    private static func closeTag(_ source: String, _ slash: String.Index, stack: inout [Node]) -> String.Index {
        var index = source.index(after: slash)
        let nameStart = index
        while index < source.endIndex, !isTagBoundary(source[index]) {
            index = source.index(after: index)
        }
        let name = localName(String(source[nameStart..<index]))
        if let end = source[index...].firstIndex(of: ">") {
            index = source.index(after: end)
        }
        if let found = stack.lastIndex(where: { $0.name == name }), found > 0 {
            stack.removeSubrange(found..<stack.count)
        }
        return index
    }

    private static func readAttributes(_ source: String, index: inout String.Index) -> [String: String] {
        var attributes: [String: String] = [:]
        while index < source.endIndex {
            while index < source.endIndex, source[index].isWhitespace {
                index = source.index(after: index)
            }
            if index >= source.endIndex || source[index] == ">" || source[index] == "/" { break }
            let nameStart = index
            while index < source.endIndex, !isTagBoundary(source[index]), source[index] != "=" {
                index = source.index(after: index)
            }
            let name = localName(String(source[nameStart..<index]))
            while index < source.endIndex, source[index].isWhitespace {
                index = source.index(after: index)
            }
            var value = ""
            if index < source.endIndex, source[index] == "=" {
                index = source.index(after: index)
                while index < source.endIndex, source[index].isWhitespace {
                    index = source.index(after: index)
                }
                if index < source.endIndex, source[index] == "\"" || source[index] == "'" {
                    let quote = source[index]
                    index = source.index(after: index)
                    let valueStart = index
                    while index < source.endIndex, source[index] != quote {
                        index = source.index(after: index)
                    }
                    value = String(source[valueStart..<index])
                    if index < source.endIndex { index = source.index(after: index) }
                } else {
                    let valueStart = index
                    while index < source.endIndex, !source[index].isWhitespace, source[index] != ">", source[index] != "/" {
                        index = source.index(after: index)
                    }
                    value = String(source[valueStart..<index])
                }
            }
            if !name.isEmpty {
                attributes[name] = HTMLMiniParser.decodeHTMLEntities(value)
            }
        }
        return attributes
    }

    private static func skipDeclaration(_ source: String, _ bang: String.Index) -> String.Index {
        let tail = source[bang...]
        if tail.hasPrefix("!--") {
            return skipUntil(source, bang, marker: "-->")
        }
        if tail.hasPrefix("![CDATA[") {
            let start = source.index(bang, offsetBy: 8, limitedBy: source.endIndex) ?? source.endIndex
            guard let range = source.range(of: "]]>", range: start..<source.endIndex) else { return source.endIndex }
            return range.upperBound
        }
        var index = bang
        var depth = 0
        while index < source.endIndex {
            let character = source[index]
            if character == "[" { depth += 1 }
            if character == "]" && depth > 0 { depth -= 1 }
            if character == ">" && depth == 0 {
                return source.index(after: index)
            }
            index = source.index(after: index)
        }
        return source.endIndex
    }

    private static func skipUntil(_ source: String, _ start: String.Index, marker: String) -> String.Index {
        guard let range = source.range(of: marker, range: start..<source.endIndex) else { return source.endIndex }
        return range.upperBound
    }

    private static func skipRaw(_ source: String, _ start: String.Index, name: String) -> String.Index {
        let endTag = Array("</" + name)
        var index = start
        while index < source.endIndex {
            if source[index] == "<", matches(endTag, in: source, at: index) {
                var cursor = source.index(index, offsetBy: endTag.count, limitedBy: source.endIndex) ?? source.endIndex
                if cursor == source.endIndex || source[cursor].isWhitespace || source[cursor] == ">" {
                    if let close = source[cursor...].firstIndex(of: ">") {
                        return source.index(after: close)
                    }
                    return source.endIndex
                }
            }
            index = source.index(after: index)
        }
        return source.endIndex
    }

    private static func matches(_ needle: [Character], in source: String, at index: String.Index) -> Bool {
        var cursor = index
        for character in needle {
            if cursor >= source.endIndex { return false }
            if String(source[cursor]).lowercased() != String(character) { return false }
            cursor = source.index(after: cursor)
        }
        return true
    }

    private static func appendText(_ raw: String, to node: Node) {
        let decoded = HTMLMiniParser.decodeHTMLEntities(raw)
        guard !decoded.isEmpty else { return }
        node.pieces.append(.text(decoded))
    }

    private static func localName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let colon = trimmed.lastIndex(of: ":") else { return trimmed }
        return String(trimmed[trimmed.index(after: colon)...])
    }

    private static func isTagBoundary(_ character: Character) -> Bool {
        character.isWhitespace || character == ">" || character == "/"
    }

    private static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
    ]
}
