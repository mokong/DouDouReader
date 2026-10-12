import Foundation

/// 书架检查更新的纯比较逻辑：本地已存目录 vs 远端最新目录。
/// 独立成 enum 方便 LogicChecks 回归，不碰网络、不碰 SwiftData。
nonisolated enum BookUpdateComparison {
    struct Outcome: Equatable, Sendable {
        /// 远端比本地多出的章节数（远端更少时按 0 计）。
        var newChapterCount: Int
        /// 目录有变化：多出章节，或最新一章的章名/地址变了。
        var hasUpdate: Bool
        /// 远端最新一章的章名。
        var latestTitle: String
    }

    static func compare(local: [RemoteChapterRef], remote: [RemoteChapterRef]) -> Outcome {
        guard let remoteLast = remote.last else {
            return Outcome(newChapterCount: 0, hasUpdate: false, latestTitle: local.last?.title ?? "")
        }
        let newCount = max(0, remote.count - local.count)
        let localLast = local.last
        let differs = localLast?.url != remoteLast.url || localLast?.title != remoteLast.title
        return Outcome(
            newChapterCount: newCount,
            hasUpdate: newCount > 0 || differs,
            latestTitle: remoteLast.title
        )
    }
}
