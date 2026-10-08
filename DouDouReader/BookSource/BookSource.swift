import Foundation
import SwiftData

@Model
final class SourceRecord {
    var id: UUID = UUID()
    var name: String = ""
    var baseURL: String = ""
    var enabled: Bool = true
    var addedAt: Date = Date()

    init(name: String, baseURL: String) {
        self.id = UUID()
        self.name = name
        self.baseURL = baseURL
        self.enabled = true
        self.addedAt = Date()
    }
}

nonisolated struct CatalogBook: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var author: String
    var summary: String
}

nonisolated enum SourceError: LocalizedError {
    case badURL
    case badResponse
    case notFound
    case emptyBook
    case unreachable

    var errorDescription: String? {
        switch self {
        case .badURL: "书源地址需要是 https，或本机局域网的 http"
        case .badResponse: "书源没有返回可用的 JSON"
        case .notFound: "书源里没有这本书"
        case .emptyBook: "这本书没有正文"
        case .unreachable: "连不上这本书源"
        }
    }
}

enum SourceURL {
    static func parse(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "https://" + text
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else { return nil }
        let httpAllowed = scheme == "http" && allowsLocalHTTP(host)
        guard scheme == "https" || httpAllowed else { return nil }
        components.scheme = scheme
        components.host = host
        components.user = nil
        components.password = nil
        components.fragment = nil
        components.query = nil
        return components.url
    }

    static func allowsLocalHTTP(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local") {
            return true
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        return false
    }
}

nonisolated enum SourceEndpoint {
    static func search(_ base: URL, query: String) -> URL? {
        guard let url = joined(base, parts: ["search"]),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url
    }

    static func book(_ base: URL, id: String) -> URL? {
        guard let id = safeID(id) else { return nil }
        return joined(base, parts: ["books", id])
    }

    static func chapter(_ base: URL, bookID: String, chapterID: String) -> URL? {
        guard let bookID = safeID(bookID), let chapterID = safeID(chapterID) else { return nil }
        return joined(base, parts: ["books", bookID, "chapters", chapterID])
    }

    static func safeID(_ raw: String) -> String? {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\\"), !id.contains("?"), !id.contains("#") else {
            return nil
        }
        return id
    }

    private static func joined(_ base: URL, parts: [String]) -> URL? {
        var url = base
        for part in parts {
            url.appendPathComponent(part)
        }
        return url
    }
}

nonisolated enum CatalogParser {
    static func books(from data: Data) throws -> [CatalogBook] {
        let list = try decode(CatalogListPayload.self, from: data)
        return list.books.map {
            CatalogBook(id: $0.id, title: $0.title, author: $0.author ?? "", summary: $0.summary ?? "")
        }
    }

    static func detail(from data: Data) throws -> CatalogDetail {
        let payload = try decode(CatalogDetailPayload.self, from: data)
        return CatalogDetail(
            id: payload.id,
            title: payload.title,
            author: payload.author ?? "",
            summary: payload.summary ?? "",
            chapters: payload.chapters.map { CatalogChapterRef(id: $0.id, title: $0.title) }
        )
    }

    static func chapter(from data: Data) throws -> CatalogChapterBody {
        try decode(CatalogChapterBody.self, from: data)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw SourceError.badResponse
        }
    }
}

nonisolated struct CatalogDetail: Sendable {
    var id: String
    var title: String
    var author: String
    var summary: String
    var chapters: [CatalogChapterRef]
}

nonisolated struct CatalogChapterRef: Identifiable, Sendable {
    var id: String
    var title: String
}

nonisolated struct CatalogChapterBody: Sendable {
    var id: String
    var title: String
    var content: String
}

private nonisolated struct CatalogListPayload: Decodable {
    var books: [CatalogBookPayload]
}

private nonisolated struct CatalogBookPayload: Decodable {
    var id: String
    var title: String
    var author: String?
    var summary: String?
}

private nonisolated struct CatalogDetailPayload: Decodable {
    var id: String
    var title: String
    var author: String?
    var summary: String?
    var chapters: [CatalogChapterPayload]
}

private nonisolated struct CatalogChapterPayload: Decodable {
    var id: String
    var title: String
}

extension CatalogChapterBody: Decodable {}

nonisolated enum CatalogText {
    static func assemble(author: String, chapters: [(title: String, content: String)]) -> String {
        var lines: [String] = []
        let name = author.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            lines.append("作者：\(name)")
        }
        for chapter in chapters {
            let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = chapter.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                lines.append(title)
            }
            if !content.isEmpty {
                lines.append(content)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

nonisolated protocol BookCatalog {
    var id: String { get }
    var name: String { get }
    func search(query: String) async throws -> [CatalogBook]
    func fetchText(bookID: String, progress: (@Sendable (Int, Int) -> Void)?) async throws -> (title: String, text: String)
}

nonisolated struct SampleBookCatalog: BookCatalog {
    static let stableID = "builtin.doudou"
    let id = SampleBookCatalog.stableID
    let name = "豆豆书库"

    func search(query: String) async throws -> [CatalogBook] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let book = CatalogBook(
            id: "lighthouse",
            title: SampleNovel.title,
            author: "豆豆",
            summary: "海岸北端的灯塔邮局，守塔人林书把地址写清楚。"
        )
        let haystack = book.title + book.author + book.summary
        guard haystack.localizedStandardContains(needle) else { return [] }
        return [book]
    }

    func fetchText(bookID: String, progress: (@Sendable (Int, Int) -> Void)?) async throws -> (title: String, text: String) {
        guard bookID == "lighthouse" else { throw SourceError.notFound }
        progress?(1, 1)
        return (SampleNovel.title, SampleNovel.text)
    }
}

nonisolated struct RemoteBookCatalog: BookCatalog {
    var id: String
    var name: String
    var baseURL: URL
    var session: URLSession = .shared

    func search(query: String) async throws -> [CatalogBook] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        guard let url = SourceEndpoint.search(baseURL, query: needle) else { throw SourceError.badURL }
        return try CatalogParser.books(from: try await load(url))
    }

    func fetchText(bookID: String, progress: (@Sendable (Int, Int) -> Void)?) async throws -> (title: String, text: String) {
        guard let detailURL = SourceEndpoint.book(baseURL, id: bookID) else { throw SourceError.badURL }
        let detail = try CatalogParser.detail(from: try await load(detailURL))
        guard !detail.chapters.isEmpty else { throw SourceError.emptyBook }
        var chapters: [(title: String, content: String)] = []
        var total = 0
        for (index, chapter) in detail.chapters.enumerated() {
            progress?(index + 1, detail.chapters.count)
            guard let url = SourceEndpoint.chapter(baseURL, bookID: bookID, chapterID: chapter.id) else {
                throw SourceError.badURL
            }
            let body = try CatalogParser.chapter(from: try await load(url))
            total += body.content.utf8.count
            if total > BookStorage.byteLimit { throw ImportError.tooLarge }
            let title = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
            chapters.append((title.isEmpty ? chapter.title : title, body.content))
        }
        let text = CatalogText.assemble(author: detail.author, chapters: chapters)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SourceError.emptyBook }
        let title = detail.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title.isEmpty ? "未命名" : title, text)
    }

    private func load(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as SourceError {
            throw error
        } catch {
            throw SourceError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw SourceError.badResponse }
        if http.statusCode == 404 { throw SourceError.notFound }
        guard (200..<300).contains(http.statusCode) else { throw SourceError.badResponse }
        guard data.count <= BookStorage.byteLimit else { throw ImportError.tooLarge }
        return data
    }
}

enum BookCatalogs {
    static func enabled(records: [SourceRecord]) -> [BookCatalog] {
        var catalogs: [BookCatalog] = [SampleBookCatalog()]
        for record in records where record.enabled {
            guard let url = SourceURL.parse(record.baseURL) else { continue }
            let name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
            catalogs.append(
                RemoteBookCatalog(
                    id: record.id.uuidString,
                    name: name.isEmpty ? (url.host ?? "书源") : name,
                    baseURL: url
                )
            )
        }
        return catalogs
    }
}

final class CatalogURLStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: (Int, Data)] = [:]

    nonisolated static func setRoutes(_ routes: [String: (Int, Data)]) {
        lock.lock()
        self.routes = routes
        lock.unlock()
    }

    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }

    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    nonisolated override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        let match = Self.routes[path]
        Self.lock.unlock()
        guard let url = request.url, let match else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: match.0, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: match.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    nonisolated override func stopLoading() {}
}
