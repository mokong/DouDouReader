import Foundation
import SwiftData

@Model
final class SourceRecord {
    var id: UUID = UUID()
    var name: String = ""
    var baseURL: String = ""
    var enabled: Bool = true
    var addedAt: Date = Date()
    var format: String = "doudou"
    var rawJSON: String = ""
    /// 书源订阅地址。非空时管理页可「检查更新」重拉并覆盖 rawJSON。
    var subscriptionURL: String = ""
    /// 分组名：管理页按分组展示，空串归入默认分组。
    var groupName: String = ""
    /// 权重：决定发现页切换列表里的排序，大的在前。
    var weight: Int = 100

    init(name: String, baseURL: String, format: String = "doudou", rawJSON: String = "", subscriptionURL: String = "", groupName: String = "", weight: Int = 100) {
        self.id = UUID()
        self.name = name
        self.baseURL = baseURL
        self.enabled = true
        self.addedAt = Date()
        self.format = format
        self.rawJSON = rawJSON
        self.subscriptionURL = subscriptionURL
        self.groupName = groupName
        self.weight = weight
    }
}

nonisolated struct OnlineOpening: Sendable {
    var title: String
    var author: String
    var text: String
    var chapters: [RemoteChapterRef]
    /// 打开时已经下载的第一章正文，不含书名和作者行。
    var openingBody: String = ""
}

nonisolated struct CatalogBook: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var author: String
    var summary: String
    var category: String = ""
    var status: String = ""
    /// 封面图地址（来自 coverSelector），为空时由 UI 用色块占位。
    var coverURL: String = ""
}

nonisolated enum SourceError: LocalizedError, Equatable {
    case badURL
    case badResponse
    case notFound
    case emptyBook
    case unreachable
    case detailedUnreachable(String)
    case detailedBadResponse(String)

    var errorDescription: String? {
        switch self {
        case .badURL: "书源地址需要是 https，或本机局域网的 http"
        case .badResponse: "书源没有返回可用的响应"
        case .notFound: "书源里没有这本书"
        case .emptyBook: "这本书没有正文"
        case .unreachable: "连不上这本书源"
        case .detailedUnreachable(let msg): "连不上书源：\(msg)"
        case .detailedBadResponse(let msg): "书源响应异常：\(msg)"
        }
    }
}

enum SourceURL {
    /// 默认仅放行 https 与局域网 http；`allowInsecureHTTP` 为用户显式授权后才放行公网 http。
    static func parse(_ raw: String, allowInsecureHTTP: Bool = false) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "https://" + text
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else { return nil }
        let httpAllowed = scheme == "http" && (allowsLocalHTTP(host) || allowInsecureHTTP)
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

/// 点开一本书只给第一章。后面的章节按目录地址单独取。
nonisolated protocol IncrementalBookCatalog: BookCatalog {
    func fetchOpening(bookID: String) async throws -> OnlineOpening
    func fetchChapterText(url: String) async throws -> String
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

nonisolated struct RemoteBookCatalog: IncrementalBookCatalog {
    var id: String
    var name: String
    var baseURL: URL
    /// 复用与规则书源一致的 URLCache + 共享 Cookie 会话。
    var session: URLSession = RuleBasedBookCatalog.configuredSession

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
            let body = try await loadRemoteChapter(bookID: bookID, chapter: chapter)
            total += body.content.utf8.count
            if total > BookStorage.byteLimit { throw ImportError.tooLarge }
            chapters.append((body.title, body.content))
        }
        let text = CatalogText.assemble(author: detail.author, chapters: chapters)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SourceError.emptyBook }
        let title = detail.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title.isEmpty ? "未命名" : title, text)
    }

    func fetchOpening(bookID: String) async throws -> OnlineOpening {
        guard let detailURL = SourceEndpoint.book(baseURL, id: bookID) else { throw SourceError.badURL }
        let detail = try CatalogParser.detail(from: try await load(detailURL))
        guard let first = detail.chapters.first else { throw SourceError.emptyBook }
        let body = try await loadRemoteChapter(bookID: bookID, chapter: first)
        let text = CatalogText.assemble(author: detail.author, chapters: [(body.title, body.content)])
        guard !body.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourceError.emptyBook
        }
        let refs = detail.chapters.compactMap { chapter -> RemoteChapterRef? in
            guard let url = SourceEndpoint.chapter(baseURL, bookID: bookID, chapterID: chapter.id) else { return nil }
            let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return RemoteChapterRef(title: title.isEmpty ? "章节" : title, url: url.absoluteString)
        }
        let title = detail.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return OnlineOpening(
            title: title.isEmpty ? "未命名" : title,
            author: detail.author,
            text: text,
            chapters: refs,
            openingBody: body.content
        )
    }

    func fetchChapterText(url: String) async throws -> String {
        guard let chapterURL = URL(string: url) else { throw SourceError.badURL }
        let body = try CatalogParser.chapter(from: try await load(chapterURL))
        let content = body.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw SourceError.emptyBook }
        return content
    }

    private func loadRemoteChapter(bookID: String, chapter: CatalogChapterRef) async throws -> (title: String, content: String) {
        guard let url = SourceEndpoint.chapter(baseURL, bookID: bookID, chapterID: chapter.id) else {
            throw SourceError.badURL
        }
        let body = try CatalogParser.chapter(from: try await load(url))
        let title = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title.isEmpty ? chapter.title : title, body.content)
    }

    private func load(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        if let host = url.host {
            let scheme = url.scheme ?? "https"
            request.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
        }
        let host = url.host ?? "书源服务器"
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as SourceError {
            throw error
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut:
                throw SourceError.detailedUnreachable("连接超时（\(host) 响应超时）")
            case .cannotFindHost:
                throw SourceError.detailedUnreachable("找不到主机（\(host) DNS 解析失败）")
            case .cannotConnectToHost:
                throw SourceError.detailedUnreachable("无法连接到服务器（\(host) 拒绝连接）")
            case .notConnectedToInternet:
                throw SourceError.detailedUnreachable("当前设备未连接互联网，请检查网络设置")
            default:
                throw SourceError.detailedUnreachable("网络请求失败: \(urlError.localizedDescription)")
            }
        } catch {
            throw SourceError.detailedUnreachable("连接书源失败: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { throw SourceError.badResponse }
        if http.statusCode == 404 { throw SourceError.notFound }
        if http.statusCode == 403 { throw SourceError.detailedBadResponse("HTTP 403 Forbidden（无权限或已被拦截）") }
        guard (200..<300).contains(http.statusCode) else { throw SourceError.detailedBadResponse("HTTP 状态码 \(http.statusCode)") }
        guard data.count <= BookStorage.byteLimit else { throw ImportError.tooLarge }
        return data
    }
}

enum BookCatalogs {
    static func enabled(records: [SourceRecord]) -> [BookCatalog] {
        var catalogs: [BookCatalog] = [SampleBookCatalog()]
        for record in records where record.enabled {
            if record.format == BookSourceKind.legado.rawValue || record.format == BookSourceKind.xiangse.rawValue {
                if let source = try? BookSourceParser.decodeSingleSource(json: record.rawJSON) {
                    catalogs.append(RuleBasedBookCatalog(recordID: record.id.uuidString, source: source))
                    continue
                }
            }
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
