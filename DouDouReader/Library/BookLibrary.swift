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

    static var supportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DouDouReader", isDirectory: true)
    }

    static var booksDirectory: URL { directory("Books") }
    static var fontsDirectory: URL { directory("Fonts") }

    static func fileURL(_ fileName: String) -> URL {
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

    static func delete(fileName: String) {
        try? FileManager.default.removeItem(at: fileURL(fileName))
    }

    private static func directory(_ name: String) -> URL {
        let url = supportRoot.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum ShelfGroups {
    static let builtins = ["默认", "养肥区", "已完本"]
    private static let customKey = "doudou.shelf.customGroups"

    static func all(bookGroups: [String] = []) -> [String] {
        let custom = UserDefaults.standard.stringArray(forKey: customKey) ?? []
        var result: [String] = []
        var seen = Set<String>()
        for name in builtins + custom + bookGroups {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    static func add(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !builtins.contains(trimmed) else { return }
        var custom = UserDefaults.standard.stringArray(forKey: customKey) ?? []
        guard !custom.contains(trimmed) else { return }
        custom.append(trimmed)
        UserDefaults.standard.set(custom, forKey: customKey)
    }
}

enum BookLibrary {
    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func importText(_ raw: String, suggestedTitle: String, context: ModelContext) throws -> ImportedBook {
        let text = TextDecoding.normalize(raw)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.empty
        }
        let digest = hash(text)
        if let existing = find(hash: digest, in: context) {
            return ImportedBook(book: existing, isNew: false)
        }
        let fileName = try BookStorage.write(text)
        let trimmed = suggestedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "未命名" : trimmed
        let book = BookRecord(
            title: title,
            author: BookMetadata.author(in: text),
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
        guard let decoded = TextDecoding.decode(data) else { throw ImportError.unreadableEncoding }
        return try importText(
            decoded,
            suggestedTitle: BookMetadata.title(from: url.lastPathComponent),
            context: context
        )
    }

    static func delete(_ book: BookRecord, context: ModelContext) throws {
        BookStorage.delete(fileName: book.fileName)
        context.delete(book)
        try context.save()
    }

    private static func find(hash: String, in context: ModelContext) -> BookRecord? {
        let books = (try? context.fetch(FetchDescriptor<BookRecord>())) ?? []
        return books.first { $0.contentHash == hash }
    }
}
