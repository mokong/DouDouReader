import Foundation

/// 换源列表里的一条：某个其他书源上对得上的同一本书。
nonisolated struct SourceSwitchHit: Identifiable, Equatable, Sendable {
    var sourceID: String
    var sourceName: String
    var book: CatalogBook

    var id: String { sourceID + "\n" + book.id }
}

/// 一次搜索里某个书源的进度。书架搜索会同时问全部已启用书源，结果按源分开。
nonisolated struct SourceSearchBatch: Identifiable, Equatable, Sendable {
    var sourceID: String
    var sourceName: String
    var phase: Phase

    var id: String { sourceID }

    nonisolated enum Phase: Equatable, Sendable {
        case searching
        case books([CatalogBook])
        case failed(String)
    }

    var books: [CatalogBook] {
        if case .books(let books) = phase { return books }
        return []
    }

    var isSearching: Bool {
        if case .searching = phase { return true }
        return false
    }
}

/// 搜索历史。最近的词在最前，重复搜索会把旧词挪到前面。
nonisolated enum BookSearchHistory {
    static let key = "doudou.searchHistory"
    static let limit = 12

    static func load(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    static func remember(_ raw: String, defaults: UserDefaults = .standard) -> [String] {
        let needle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var items = load(defaults: defaults)
        guard !needle.isEmpty else { return items }
        items.removeAll { $0.caseInsensitiveCompare(needle) == .orderedSame }
        items.insert(needle, at: 0)
        if items.count > limit {
            items = Array(items.prefix(limit))
        }
        defaults.set(items, forKey: key)
        return items
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

/// 同时搜索多条书源。单个书源失败或超时不影响其他书源。
nonisolated enum BookSearch {
    static func shelfHit(title: String, author: String, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        return title.localizedStandardContains(needle) || author.localizedStandardContains(needle)
    }

    /// 换源结果：其他书源里，书名和作者对得上的那几本。当前书源和当前地址不算。
    static func switchHits(
        title: String,
        author: String,
        excludingSourceID: String,
        excludingBookID: String,
        batches: [SourceSearchBatch]
    ) -> [SourceSwitchHit] {
        let sourceID = excludingSourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookID = excludingBookID.trimmingCharacters(in: .whitespacesAndNewlines)
        var hits: [SourceSwitchHit] = []
        var seen = Set<String>()
        for batch in batches {
            if !sourceID.isEmpty, batch.sourceID == sourceID { continue }
            for book in batch.books {
                let remoteID = book.id.trimmingCharacters(in: .whitespacesAndNewlines)
                if !bookID.isEmpty, remoteID == bookID { continue }
                guard BookIdentity.same(
                    title: title,
                    author: author,
                    otherTitle: book.title,
                    otherAuthor: book.author
                ) else { continue }
                let key = batch.sourceID + "\n" + remoteID
                guard seen.insert(key).inserted else { continue }
                hits.append(
                    SourceSwitchHit(
                        sourceID: batch.sourceID,
                        sourceName: batch.sourceName,
                        book: book
                    )
                )
            }
        }
        return hits
    }

    /// 还在搜、已经有书、或者失败的源留在切换条上。搜完但一本都没有的源不占位置。
    static func listed(_ batches: [SourceSearchBatch]) -> [SourceSearchBatch] {
        batches.filter { batch in
            if batch.isSearching { return true }
            if case .failed = batch.phase { return true }
            return !batch.books.isEmpty
        }
    }

    static func updates(
        query: String,
        sources: [SwitchableSource],
        concurrency: Int = 4,
        timeout: Duration = .seconds(15),
        search: @escaping @Sendable (SwitchableSource, String) async throws -> [CatalogBook] = { source, needle in
            try await BookSourceLibrary.catalog(for: source).search(query: needle)
        }
    ) -> AsyncStream<SourceSearchBatch> {
        let (stream, continuation) = AsyncStream<SourceSearchBatch>.makeStream()
        let task = Task {
            await run(
                query: query,
                sources: sources,
                concurrency: concurrency,
                timeout: timeout,
                search: search
            ) { batch in
                continuation.yield(batch)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
        return stream
    }

    static func run(
        query: String,
        sources: [SwitchableSource],
        concurrency: Int = 4,
        timeout: Duration = .seconds(15),
        search: @escaping @Sendable (SwitchableSource, String) async throws -> [CatalogBook] = { source, needle in
            try await BookSourceLibrary.catalog(for: source).search(query: needle)
        },
        onUpdate: @escaping @Sendable (SourceSearchBatch) -> Void
    ) async {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !sources.isEmpty else { return }
        let limit = max(1, concurrency)
        await withTaskGroup(of: SourceSearchBatch?.self) { group in
            var index = 0
            func enqueue() {
                guard index < sources.count else { return }
                let source = sources[index]
                index += 1
                group.addTask {
                    await one(source: source, query: needle, timeout: timeout, search: search)
                }
            }
            for _ in 0..<min(limit, sources.count) {
                enqueue()
            }
            while !Task.isCancelled, let batch = await group.next() {
                if Task.isCancelled {
                    break
                }
                if let batch {
                    onUpdate(batch)
                }
                enqueue()
            }
            group.cancelAll()
        }
    }

    private static func one(
        source: SwitchableSource,
        query: String,
        timeout: Duration,
        search: @escaping @Sendable (SwitchableSource, String) async throws -> [CatalogBook]
    ) async -> SourceSearchBatch? {
        if Task.isCancelled { return nil }
        do {
            let books = try await withTimeout(timeout) {
                try await search(source, query)
            }
            if Task.isCancelled { return nil }
            return SourceSearchBatch(sourceID: source.id, sourceName: source.name, phase: .books(books))
        } catch is CancellationError {
            return nil
        } catch is SearchTimeout {
            if Task.isCancelled { return nil }
            return SourceSearchBatch(sourceID: source.id, sourceName: source.name, phase: .failed("超时"))
        } catch {
            if Task.isCancelled { return nil }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return SourceSearchBatch(
                sourceID: source.id,
                sourceName: source.name,
                phase: .failed(text.isEmpty ? "搜索失败" : text)
            )
        }
    }

    private static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: SearchRace<T>.self) { group in
            group.addTask {
                .value(try await operation())
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return .timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            switch first {
            case .value(let value):
                return value
            case .timedOut:
                throw SearchTimeout()
            }
        }
    }
}

private nonisolated struct SearchTimeout: Error {}

private nonisolated enum SearchRace<T: Sendable>: Sendable {
    case value(T)
    case timedOut
}
