import Foundation

/// 全本缓存的待下载下标计算（纯逻辑，LogicChecks 回归）。
nonisolated enum BookCachePlan {
    /// 返回 0..<total 中未落盘（不在 downloaded 集合）的章节下标，保持顺序。
    static func pendingIndices(total: Int, downloaded: Set<Int>) -> [Int] {
        guard total > 0 else { return [] }
        return (0..<total).filter { !downloaded.contains($0) }
    }
}

/// 字节数格式化：1024 进位，B/KB/MB/GB。
nonisolated enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        let gb = mb / 1024
        return String(format: "%.2f GB", gb)
    }
}
