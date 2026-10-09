import Foundation

nonisolated struct RemoteChapterRef: Codable, Equatable, Sendable {
    var title: String
    var url: String
}
