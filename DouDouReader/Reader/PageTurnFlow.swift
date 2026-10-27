import Foundation

/// 翻页转场调度（纯逻辑，不依赖 UIKit，可在 `-selfTest` 里回归）。
///
/// 不变式：只要还有一段转场在飞（手指跟手 / 动画播放中），就绝不再次改写
/// UIPageViewController 的页面集合。两者并行时 UIKit 不会撤下前一段转场的半页
/// 图层，屏幕上就留下两张停在中间的页面。占用期间到达的新目标合并成一个，
/// 等转场全部落定后一次性落位。
nonisolated struct PageTurnFlow {
    enum Action: Equatable {
        /// 立刻应用；是否带动画由调用方按翻页模式决定
        case apply(animated: Bool)
        /// 有转场在飞，目标已合并进排队
        case queued
    }

    struct Request: Equatable {
        var position: ReaderPosition
        var revision: Int
        var animated: Bool
    }

    /// 手指跟手中（UIKit 自己发起的转场）
    private(set) var interactive = false
    /// 我们发起的 setViewControllers(animated: true) 播放中
    private(set) var animated = false
    private(set) var pending: Request?

    var isBusy: Bool { interactive || animated }

    mutating func beginInteractive() { interactive = true }
    mutating func endInteractive() { interactive = false }
    mutating func beginAnimated() { animated = true }
    mutating func endAnimated() { animated = false }

    /// UIKit 的收尾回调不保证一定到达，兜底解除占用，避免翻页永久卡在半空。
    mutating func forceIdle() {
        interactive = false
        animated = false
    }

    /// 翻页控制器被重建（切换翻页模式）后，旧的占用与排队都已失效。
    mutating func reset() {
        forceIdle()
        pending = nil
    }

    /// 请求切到 position。转场占用中只排队，并且只保留最终落点。
    mutating func request(_ position: ReaderPosition, revision: Int, animated: Bool) -> Action {
        guard isBusy else { return .apply(animated: animated) }
        // 连点/连翻合并到最后一页；动画意图取并集，不丢用户已经按下的那一次。
        pending = Request(
            position: position,
            revision: revision,
            animated: animated || pending?.animated == true
        )
        return .queued
    }

    mutating func takePending() -> Request? {
        defer { pending = nil }
        return pending
    }

    /// 程序化翻页（点按、自动翻页、朗读推进）是否允许播转场动画。
    /// 仿真模式把 curl 只留给手指跟手：点按再起一段 curl，会和跟手那段叠成两张半页停在中间。
    /// 「无」模式的语义则是任何场合都不出动画。
    nonisolated static func programmaticAnimationAllowed(for mode: PageTurnMode) -> Bool {
        mode != .none && mode != .curl
    }
}
