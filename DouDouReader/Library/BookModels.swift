import Foundation
import SwiftData

@Model
final class BookRecord {
    var id: UUID = UUID()
    var title: String = ""
    var author: String = ""
    var fileName: String = ""
    var contentHash: String = ""
    var addedAt: Date = Date()
    var lastReadAt: Date = Date()
    var isPinned: Bool = false
    var groupName: String = "默认"
    var coverHue: Double = 0.08
    /// 封面图片地址（可为远端 http/https 地址，若本地已缓存或 EPUB 提取则优先读 Covers 目录）。
    var coverURL: String = ""
    var chapterIndex: Int = 0
    var utf16Offset: Int = 0
    var totalUTF16: Int = 0
    var currentChapterTitle: String = ""
    /// 在线书的章节目录。空字符串表示本地整本，不需要再向书源要下一章。
    var remoteChapterList: String = ""
    var remoteBookID: String = ""
    var remoteSourceID: String = ""
    var loadedChapterCount: Int = 0
    /// 检查更新状态：是否有新章节、新章节数量、远端最新章名、上次检查反馈。
    var updateAvailable: Bool = false
    var newChapterCount: Int = 0
    var latestRemoteChapterTitle: String = ""
    var lastCheckMessage: String = ""

    @Relationship(deleteRule: .cascade, inverse: \BookmarkRecord.book)
    var bookmarks: [BookmarkRecord] = []

    init(
        title: String,
        author: String,
        fileName: String,
        contentHash: String,
        coverHue: Double,
        totalUTF16: Int
    ) {
        self.id = UUID()
        self.title = title
        self.author = author
        self.fileName = fileName
        self.contentHash = contentHash
        self.addedAt = Date()
        self.lastReadAt = Date()
        self.isPinned = false
        self.groupName = "默认"
        self.coverHue = coverHue
        self.chapterIndex = 0
        self.utf16Offset = 0
        self.totalUTF16 = totalUTF16
        self.currentChapterTitle = ""
        self.bookmarks = []
    }
}

@Model
final class BookmarkRecord {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var chapterIndex: Int = 0
    var chapterTitle: String = ""
    var utf16Offset: Int = 0
    var excerpt: String = ""
    var book: BookRecord?

    init(chapterIndex: Int, chapterTitle: String, utf16Offset: Int, excerpt: String) {
        self.id = UUID()
        self.createdAt = Date()
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.utf16Offset = utf16Offset
        self.excerpt = excerpt
    }
}
