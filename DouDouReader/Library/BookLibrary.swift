import CryptoKit
import Foundation
import SwiftData

nonisolated enum ImportError: LocalizedError {
    case unreadableEncoding
    case empty
    case tooLarge
    case fontUnreadable

    var errorDescription: String? {
        switch self {
        case .unreadableEncoding: "无法识别文本编码"
        case .empty: "文件是空的"
        case .tooLarge: "文件超过 40MB"
        case .fontUnreadable: "无法读取字体文件"
        }
    }
}

struct ImportedBook {
    var book: BookRecord
    var isNew: Bool
}

enum BookMetadata {
    static func author(in text: String) -> String {
        let ns = text as NSString
        var location = 0
        var lines = 0
        while location < ns.length && lines < 30 {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("作者") {
                let rest = line.dropFirst(2)
                let pieces = rest.split(whereSeparator: { $0 == ":" || $0 == "：" })
                let name = pieces.last.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                if !name.isEmpty, name.count <= 20 {
                    return name
                }
            }
            lines += 1
            let next = NSMaxRange(lineRange)
            if next <= location { break }
            location = next
        }
        return ""
    }

    static func title(from filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名" : trimmed
    }

    static func coverHue(for title: String) -> Double {
        var hash = 0
        for unit in title.utf8 {
            hash = (hash &* 31 &+ Int(unit)) % 360
        }
        return Double(abs(hash) % 360) / 360.0
    }
}

enum BookStorage {
    nonisolated static let byteLimit = 40 * 1024 * 1024

    nonisolated static var supportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DouDouReader", isDirectory: true)
    }

    nonisolated static var booksDirectory: URL { directory("Books") }
    static var fontsDirectory: URL { directory("Fonts") }

    nonisolated static func fileURL(_ fileName: String) -> URL {
        booksDirectory.appendingPathComponent(fileName)
    }

    static func write(_ text: String) throws -> String {
        let fileName = UUID().uuidString + ".txt"
        try Data(text.utf8).write(to: fileURL(fileName), options: .atomic)
        return fileName
    }

    static func read(fileName: String) throws -> String {
        let data = try Data(contentsOf: fileURL(fileName))
        guard let text = TextDecoding.decode(data) else { throw ImportError.unreadableEncoding }
        return TextDecoding.normalize(text)
    }

    static func overwrite(fileName: String, text: String) throws {
        guard text.utf8.count <= byteLimit else { throw ImportError.tooLarge }
        try Data(text.utf8).write(to: fileURL(fileName), options: .atomic)
    }

    static func delete(fileName: String) {
        try? FileManager.default.removeItem(at: fileURL(fileName))
        StoredChapters.delete(fileName: fileName)
    }

    nonisolated private static func directory(_ name: String) -> URL {
        let url = supportRoot.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// 书架上认作同一本书：书名相同，作者都有时也要相同。缺作者时只看书名。
nonisolated enum BookIdentity {
    static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "《", with: "")
        text = text.replacingOccurrences(of: "》", with: "")
        let parts = text.split { $0.isWhitespace }.map(String.init)
        return parts.joined().folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "zh_Hans"))
    }

    static func same(title: String, author: String, otherTitle: String, otherAuthor: String) -> Bool {
        let left = normalize(title)
        let right = normalize(otherTitle)
        guard !left.isEmpty, left == right else { return false }
        let leftAuthor = normalize(author)
        let rightAuthor = normalize(otherAuthor)
        if leftAuthor.isEmpty || rightAuthor.isEmpty { return true }
        return leftAuthor == rightAuthor
    }
}

/// 在线书已下载的章节。按目录下标保存，中间可以有空档。
nonisolated struct StoredChapter: Codable, Equatable, Sendable {
    var index: Int
    var title: String
    var body: String
}

nonisolated enum StoredChapters {
    static func block(title: String, body: String) -> String {
        let cleaned = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(title)\n\(cleaned)\n"
    }

    static func assemble(_ items: [StoredChapter]) -> String {
        items.sorted { $0.index < $1.index }.map { block(title: $0.title, body: $0.body) }.joined()
    }

    static func layout(_ items: [StoredChapter]) -> (text: String, slices: [ChapterSlice]) {
        let ordered = items.sorted { $0.index < $1.index }
        var text = ""
        var slices: [ChapterSlice] = []
        for (engineIndex, item) in ordered.enumerated() {
            let piece = block(title: item.title, body: item.body)
            let start = (text as NSString).length
            text += piece
            let titleLength = (item.title as NSString).length
            let end = (text as NSString).length
            slices.append(
                ChapterSlice(
                    index: engineIndex,
                    title: item.title,
                    lineStart: start,
                    bodyStart: min(start + titleLength + 1, end),
                    bodyEnd: end,
                    remoteIndex: item.index
                )
            )
        }
        return (text, slices)
    }

    static func offset(of remoteIndex: Int, in items: [StoredChapter]) -> Int {
        let ordered = items.sorted { $0.index < $1.index }
        var cursor = 0
        for item in ordered {
            if item.index == remoteIndex { return cursor }
            cursor += (block(title: item.title, body: item.body) as NSString).length
        }
        return 0
    }

    static func load(fileName: String) -> [StoredChapter] {
        let url = sidecarURL(fileName)
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([StoredChapter].self, from: data) else { return [] }
        return items.sorted { $0.index < $1.index }
    }

    static func save(fileName: String, chapters: [StoredChapter]) throws {
        let ordered = chapters.sorted { $0.index < $1.index }
        let data = try JSONEncoder().encode(ordered)
        try data.write(to: sidecarURL(fileName), options: .atomic)
    }

    static func delete(fileName: String) {
        try? FileManager.default.removeItem(at: sidecarURL(fileName))
    }

    /// 旧书只有连续的前几章正文，没有分章记录。按拆出来的章节当成 0、1、2… 记下。
    static func migrated(from text: String, fallbackTitle: String) -> [StoredChapter] {
        let slices = ChapterSplitter.split(text, fallbackTitle: fallbackTitle)
        return slices.map { slice in
            let body = ChapterSplitter.substring(text, start: slice.bodyStart, end: slice.bodyEnd)
            return StoredChapter(index: slice.index, title: slice.title, body: body)
        }
    }

    /// 换书源后目录下标会变。能对上标题的正文留在新目录里，对不上的丢掉。
    static func remap(_ items: [StoredChapter], onto chapters: [RemoteChapterRef]) -> [StoredChapter] {
        var used = Set<Int>()
        var result: [StoredChapter] = []
        for item in items {
            let key = BookIdentity.normalize(item.title)
            guard !key.isEmpty else { continue }
            guard let index = chapters.indices.first(where: { candidate in
                !used.contains(candidate) && BookIdentity.normalize(chapters[candidate].title) == key
            }) else { continue }
            used.insert(index)
            result.append(StoredChapter(index: index, title: chapters[index].title, body: item.body))
        }
        return result.sorted { $0.index < $1.index }
    }

    private static func sidecarURL(_ fileName: String) -> URL {
        BookStorage.fileURL(fileName).appendingPathExtension("chapters.json")
    }
}

enum RemoteChapterList {
    static func encode(_ chapters: [RemoteChapterRef]) -> String {
        guard let data = try? JSONEncoder().encode(chapters) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ raw: String) -> [RemoteChapterRef] {
        guard let data = raw.data(using: .utf8),
              let chapters = try? JSONDecoder().decode([RemoteChapterRef].self, from: data) else {
            return []
        }
        return chapters
    }
}

enum BookLibrary {
    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func importText(
        _ raw: String,
        suggestedTitle: String,
        author: String = "",
        context: ModelContext
    ) throws -> ImportedBook {
        let text = TextDecoding.normalize(raw)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.empty
        }
        guard text.utf8.count <= BookStorage.byteLimit else { throw ImportError.tooLarge }
        let digest = hash(text)
        if let existing = find(hash: digest, in: context) {
            return ImportedBook(book: existing, isNew: false)
        }
        let fileName = try BookStorage.write(text)
        let trimmed = suggestedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "未命名" : trimmed
        let namedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        let book = BookRecord(
            title: title,
            author: namedAuthor.isEmpty ? BookMetadata.author(in: text) : namedAuthor,
            fileName: fileName,
            contentHash: digest,
            coverHue: BookMetadata.coverHue(for: title),
            totalUTF16: (text as NSString).length
        )
        context.insert(book)
        try context.save()
        return ImportedBook(book: book, isNew: true)
    }

    static func importFile(url: URL, context: ModelContext) throws -> ImportedBook {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize, size > BookStorage.byteLimit {
            throw ImportError.tooLarge
        }
        let data = try Data(contentsOf: url)
        guard data.count <= BookStorage.byteLimit else { throw ImportError.tooLarge }
        if EpubParser.isEpub(data, filename: url.lastPathComponent) {
            let book = try EpubParser.parse(data)
            let trimmed = book.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let suggested = trimmed.isEmpty ? BookMetadata.title(from: url.lastPathComponent) : trimmed
            return try importText(book.text, suggestedTitle: suggested, author: book.author, context: context)
        }
        guard let decoded = TextDecoding.decode(data) else { throw ImportError.unreadableEncoding }
        return try importText(
            decoded,
            suggestedTitle: BookMetadata.title(from: url.lastPathComponent),
            context: context
        )
    }

    static func existingRemote(bookID: String, context: ModelContext) -> BookRecord? {
        let needle = bookID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        let books = (try? context.fetch(FetchDescriptor<BookRecord>())) ?? []
        return books.first { $0.remoteBookID == needle }
    }

    /// 不同书源上的同一本书。只认已经从书源加进书架的。
    static func existingOnline(title: String, author: String, context: ModelContext) -> BookRecord? {
        let books = (try? context.fetch(FetchDescriptor<BookRecord>())) ?? []
        return books
            .filter { !$0.remoteBookID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { BookIdentity.same(title: title, author: author, otherTitle: $0.title, otherAuthor: $0.author) }
            .max { $0.lastReadAt < $1.lastReadAt }
    }

    static func importOnline(
        text raw: String,
        suggestedTitle: String,
        author listedAuthor: String = "",
        remoteBookID: String,
        remoteSourceID: String,
        chapters: [RemoteChapterRef],
        openingBody: String = "",
        context: ModelContext
    ) throws -> ImportedBook {
        if let existing = existingRemote(bookID: remoteBookID, context: context) {
            return ImportedBook(book: existing, isNew: false)
        }
        let text = TextDecoding.normalize(raw)
        let body = openingBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = suggestedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "未命名" : trimmed
        let metaAuthor = BookMetadata.author(in: text)
        let author = listedAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedAuthor = author.isEmpty || author == "未知作者" ? metaAuthor : author
        if let existing = existingOnline(title: title, author: resolvedAuthor, context: context) {
            try adoptSource(
                existing,
                author: resolvedAuthor,
                remoteBookID: remoteBookID,
                remoteSourceID: remoteSourceID,
                chapters: chapters,
                openingBody: body,
                context: context
            )
            return ImportedBook(book: existing, isNew: false)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !body.isEmpty else {
            throw ImportError.empty
        }
        let openingTitle = chapters.first?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored: [StoredChapter]
        let fileText: String
        if !body.isEmpty {
            let chapterTitle = (openingTitle?.isEmpty == false) ? openingTitle! : title
            stored = [StoredChapter(index: 0, title: chapterTitle, body: body)]
            fileText = StoredChapters.assemble(stored)
        } else {
            stored = []
            fileText = text
        }
        let fileName = try BookStorage.write(fileText)
        if !stored.isEmpty {
            try StoredChapters.save(fileName: fileName, chapters: stored)
        }
        let book = BookRecord(
            title: title,
            author: resolvedAuthor,
            fileName: fileName,
            contentHash: hash(fileText),
            coverHue: BookMetadata.coverHue(for: title),
            totalUTF16: (fileText as NSString).length
        )
        book.remoteBookID = remoteBookID
        book.remoteSourceID = remoteSourceID
        book.remoteChapterList = RemoteChapterList.encode(chapters)
        book.loadedChapterCount = stored.isEmpty ? min(1, chapters.count) : stored.count
        context.insert(book)
        try context.save()
        return ImportedBook(book: book, isNew: true)
    }

    /// 同一本书换了书源：目录和之后的下载改用这次的书源，对得上标题的正文留下来。
    static func adoptSource(
        _ book: BookRecord,
        author: String,
        remoteBookID: String,
        remoteSourceID: String,
        chapters: [RemoteChapterRef],
        openingBody: String,
        context: ModelContext
    ) throws {
        let previousTitle = book.currentChapterTitle
        var items = StoredChapters.load(fileName: book.fileName)
        if items.isEmpty {
            let text = (try? BookStorage.read(fileName: book.fileName)) ?? ""
            items = StoredChapters.migrated(from: text, fallbackTitle: book.title)
        }
        var merged = StoredChapters.remap(items, onto: chapters)
        let body = openingBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty, let first = chapters.first {
            let key = BookIdentity.normalize(first.title)
            let index = chapters.indices.first(where: { BookIdentity.normalize(chapters[$0].title) == key }) ?? 0
            if !merged.contains(where: { $0.index == index }) {
                let title = chapters[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
                merged.append(StoredChapter(index: index, title: title.isEmpty ? first.title : title, body: body))
                merged.sort { $0.index < $1.index }
            }
        }
        let assembled = StoredChapters.assemble(merged)
        guard !assembled.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportError.empty }
        try BookStorage.overwrite(fileName: book.fileName, text: assembled)
        try StoredChapters.save(fileName: book.fileName, chapters: merged)
        book.remoteBookID = remoteBookID
        book.remoteSourceID = remoteSourceID
        book.remoteChapterList = RemoteChapterList.encode(chapters)
        book.loadedChapterCount = merged.count
        book.totalUTF16 = (assembled as NSString).length
        book.contentHash = hash(assembled)
        let named = author.trimmingCharacters(in: .whitespacesAndNewlines)
        if book.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !named.isEmpty, named != "未知作者" {
            book.author = named
        }
        if let match = merged.first(where: { BookIdentity.normalize($0.title) == BookIdentity.normalize(previousTitle) }) {
            book.chapterIndex = match.index
            book.currentChapterTitle = match.title
            book.utf16Offset = StoredChapters.offset(of: match.index, in: merged)
        } else if let first = merged.first {
            book.chapterIndex = first.index
            book.currentChapterTitle = first.title
            book.utf16Offset = StoredChapters.offset(of: first.index, in: merged)
        } else {
            book.chapterIndex = 0
            book.utf16Offset = 0
            book.currentChapterTitle = ""
        }
        book.lastReadAt = Date()
        try context.save()
    }

    /// 书架上已经重复的在线书并成一本，留下最近读过的那本和它当时的书源。
    static func collapseOnlineDuplicates(context: ModelContext) throws {
        let books = ((try? context.fetch(FetchDescriptor<BookRecord>())) ?? [])
            .filter { !$0.remoteBookID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let byTitle = Dictionary(grouping: books) { BookIdentity.normalize($0.title) }
        for (_, sameTitle) in byTitle {
            let authors = Set(sameTitle.map { BookIdentity.normalize($0.author) }.filter { !$0.isEmpty })
            if authors.count <= 1 {
                try keepLatest(sameTitle, context: context)
            } else {
                for author in authors {
                    let group = sameTitle.filter { BookIdentity.normalize($0.author) == author }
                    try keepLatest(group, context: context)
                }
                let unnamed = sameTitle.filter { BookIdentity.normalize($0.author).isEmpty }
                try keepLatest(unnamed, context: context)
            }
        }
    }

    static func delete(_ book: BookRecord, context: ModelContext) throws {
        BookStorage.delete(fileName: book.fileName)
        context.delete(book)
        try context.save()
    }

    private static func keepLatest(_ group: [BookRecord], context: ModelContext) throws {
        guard group.count > 1 else { return }
        let kept = group.max { $0.lastReadAt < $1.lastReadAt }
        for book in group where book.id != kept?.id {
            try delete(book, context: context)
        }
    }

    private static func find(hash: String, in context: ModelContext) -> BookRecord? {
        let books = (try? context.fetch(FetchDescriptor<BookRecord>())) ?? []
        return books.first { $0.contentHash == hash }
    }
}
