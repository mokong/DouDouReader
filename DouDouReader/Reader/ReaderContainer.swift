#if os(iOS) || os(visionOS)
import CoreGraphics
import SwiftUI
import UIKit

struct ReaderContainer: UIViewControllerRepresentable {
    var engine: ReaderEngine
    var settings: ReaderSettingsStore
    var theme: ReadingTheme
    var safeTop: CGFloat
    var safeBottom: CGFloat
    var onSearchSelectedText: ((String) -> Void)? = nil

    func makeUIViewController(context: Context) -> ReaderPagesController {
        let controller = ReaderPagesController(engine: engine, settings: settings)
        controller.onSearchSelectedText = onSearchSelectedText
        return controller
    }

    func updateUIViewController(_ controller: ReaderPagesController, context: Context) {
        controller.engine = engine
        controller.settings = settings
        controller.theme = theme
        controller.safeTop = safeTop
        controller.safeBottom = safeBottom
        controller.onSearchSelectedText = onSearchSelectedText
        controller.sync()
    }
}

final class ReaderPagesController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    var engine: ReaderEngine
    var settings: ReaderSettingsStore
    var theme: ReadingTheme = ReadingThemes.paper
    var safeTop: CGFloat = 0
    var safeBottom: CGFloat = 0
    var onSearchSelectedText: ((String) -> Void)?

    private var pageController: UIPageViewController?
    private var textRect: CGRect = .zero
    private var displayed = ReaderPosition(chapterIndex: -1, pageIndex: 0)
    private var appliedRevision = -1
    private var appliedMode: PageTurnMode?
    private var linkedGestureCount = -1
    private var syncing = false
    private var flow = PageTurnFlow()
    private var settleWork: DispatchWorkItem?

    init(engine: ReaderEngine, settings: ReaderSettingsStore) {
        self.engine = engine
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        pageController?.view.frame = view.bounds
        sync()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let count = pageController?.gestureRecognizers.count ?? 0
        if count != linkedGestureCount {
            installTap()
        }
        updatePop()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        cancelSettleWatchdog()
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
    }

    func sync() {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        view.backgroundColor = theme.background.platform
        let mode = effectiveMode
        if appliedMode != mode {
            installPageController(mode)
            appliedMode = mode
            displayed = ReaderPosition(chapterIndex: -1, pageIndex: 0)
            appliedRevision = -1
        }
        updatePageSize()
        guard let pageController else { return }
        pageController.view.backgroundColor = theme.background.platform
        let revision = engine.layoutRevision
        let target = engine.position
        if displayed != target || appliedRevision != revision {
            // 程序化翻页（点按、自动翻页、朗读推进）的动画意图在这里收口：
            // 仿真模式只让手指跟手播 curl，点按再起一段动画会和跟手那段叠成两张半页停在中间；
            // 「无」模式的语义则是任何场合都不出动画。
            // displayed.chapterIndex < 0 是首屏落位，同样不播动画，否则一打开书就先翻一页。
            let wantsAnimation = engine.animateNextTurn
                && PageTurnFlow.programmaticAnimationAllowed(for: mode)
                && displayed.chapterIndex >= 0
            engine.animateNextTurn = false
            if case .apply(let animated) = flow.request(target, revision: revision, animated: wantsAnimation) {
                apply(target, revision: revision, animated: animated, in: pageController)
            }
        } else if let visible = pageController.viewControllers?.first as? PageContentController {
            visible.apply(textRect: textRect, theme: theme, fontName: settings.fontName)
            if visible.position == engine.position {
                visible.setHighlight(engine.highlightRange, color: highlightColor)
            }
        }
        updateForeignGestures()
        updatePop()
        engine.onHighlight = { [weak self] range in
            guard let self,
                  let visible = self.pageController?.viewControllers?.first as? PageContentController,
                  visible.position == self.engine.position else { return }
            visible.setHighlight(range, color: self.highlightColor)
        }
    }

    private func apply(
        _ target: ReaderPosition,
        revision: Int,
        animated: Bool,
        force: Bool = false,
        in pageController: UIPageViewController
    ) {
        // 只是排版版本变了、页没变（在线书预取成功、后台排完整章都会这样）：
        // 不换视图控制器，就地按新排版重画。否则一次点按会连着落 3~4 次页，
        // 排队滚动有机会多走一页，读者看到的就是点一下翻两张。
        if target == displayed,
           let visible = pageController.viewControllers?.first as? PageContentController {
            appliedRevision = revision
            let laid = engine.layout(forChapter: target.chapterIndex, coveringPage: target.pageIndex)
            visible.refresh(layout: laid, textRect: textRect, theme: theme, fontName: settings.fontName)
            if visible.position == engine.position {
                visible.setHighlight(engine.highlightRange, color: highlightColor)
            }
            return
        }
        // 转场收尾时内部排队滚动会先停在 0 / 两页宽，再异步回中到一页宽。
        // 这个窗口里 setViewControllers 会让它按 direction 再走一页，屏幕上就多翻一张。
        guard force || pagerAtRest else {
            deferApply(target, revision: revision, animated: animated)
            return
        }
        cancelDeferredApply()
        let direction = direction(from: displayed, to: target)
        displayed = target
        appliedRevision = revision
        let targetVC = makePage(target)
        guard animated else {
            pageController.setViewControllers([targetVC], direction: direction, animated: false, completion: nil)
            return
        }
        flow.beginAnimated()
        armSettleWatchdog()
        if effectiveMode == .cover {
            performCoverTransition(to: targetVC, direction: direction, in: pageController)
            return
        }
        pageController.setViewControllers([targetVC], direction: direction, animated: true) { [weak self] _ in
            DispatchQueue.main.async { self?.finishAnimated() }
        }
    }

    /// 香色闺阁同款「覆盖翻页」：前进时旧页带右侧立体阴影向左滑走、露出底下静止的新页；
    /// 后退时上一页带阴影从左边缘滑入覆盖当前页。
    private func performCoverTransition(
        to targetVC: PageContentController,
        direction: UIPageViewController.NavigationDirection,
        in pageController: UIPageViewController
    ) {
        let host = pageController.view!
        let width = max(host.bounds.width, 1)
        let oldSnapshot = host.snapshotView(afterScreenUpdates: false)
        pageController.setViewControllers([targetVC], direction: direction, animated: false, completion: nil)

        guard let oldSnapshot else {
            finishAnimated()
            return
        }

        let shadowOverlay = UIView(frame: host.bounds)
        shadowOverlay.isUserInteractionEnabled = false
        oldSnapshot.frame = shadowOverlay.bounds
        shadowOverlay.addSubview(oldSnapshot)
        shadowOverlay.layer.shadowColor = UIColor.black.cgColor
        shadowOverlay.layer.shadowOpacity = theme.isDark ? 0.48 : 0.22
        shadowOverlay.layer.shadowRadius = 10
        shadowOverlay.layer.shadowOffset = CGSize(width: 4, height: 0)
        shadowOverlay.layer.shadowPath = UIBezierPath(rect: shadowOverlay.bounds).cgPath

        if direction == .forward {
            host.addSubview(shadowOverlay)
            UIView.animate(
                withDuration: 0.22,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState]
            ) {
                shadowOverlay.transform = CGAffineTransform(translationX: -width, y: 0)
            } completion: { [weak self] _ in
                shadowOverlay.removeFromSuperview()
                self?.finishAnimated()
            }
        } else {
            // 反向覆盖：新页从左侧滑入，底下垫旧页快照
            guard let newSnapshot = host.snapshotView(afterScreenUpdates: true) else {
                finishAnimated()
                return
            }
            oldSnapshot.removeFromSuperview()
            oldSnapshot.frame = host.bounds
            host.addSubview(oldSnapshot)

            shadowOverlay.addSubview(newSnapshot)
            newSnapshot.frame = shadowOverlay.bounds
            shadowOverlay.transform = CGAffineTransform(translationX: -width, y: 0)
            host.addSubview(shadowOverlay)

            UIView.animate(
                withDuration: 0.22,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState]
            ) {
                shadowOverlay.transform = .identity
            } completion: { [weak self] _ in
                oldSnapshot.removeFromSuperview()
                shadowOverlay.removeFromSuperview()
                self?.finishAnimated()
            }
        }
    }

    /// 程序化转场播完。这里刻意不再「补落一次同页」：`.scroll` 样式下收尾时内部滚动
    /// 还停在两页宽，按 direction 重设同页会把它记成前进一页，下一次翻页就是两张。
    private func finishAnimated() {
        flow.endAnimated()
        settle()
    }

    /// 内部排队滚动视图是否停在静止位（一页宽/高）。取不到时按静止处理，不阻塞翻页。
    private var pagerAtRest: Bool {
        guard let scroll = internalScroll(),
              scroll.bounds.width > 1, scroll.bounds.height > 1,
              scroll.contentSize.width > 1, scroll.contentSize.height > 1 else { return true }
        if scroll.contentSize.width > scroll.contentSize.height {
            return abs(scroll.contentOffset.x - scroll.bounds.width) <= 1
        }
        return abs(scroll.contentOffset.y - scroll.bounds.height) <= 1
    }

    /// `.scroll` 样式的 UIPageViewController 把拖拽与排队滚动都放在内部 UIScrollView 上。
    private func internalScroll() -> UIScrollView? {
        var stack: [UIView] = pageController.map { [$0.view] } ?? []
        while let view = stack.popLast() {
            if let scroll = view as? UIScrollView { return scroll }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    private var deferredApply: (position: ReaderPosition, revision: Int, animated: Bool)?
    private var deferredWork: DispatchWorkItem?
    private var deferredTries = 0

    private func deferApply(_ target: ReaderPosition, revision: Int, animated: Bool) {
        deferredApply = (target, revision, animated)
        guard deferredWork == nil else { return }
        deferredTries = 0
        scheduleDeferredApply()
    }

    private func scheduleDeferredApply() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.deferredWork = nil
            guard let pageController = self.pageController, let deferred = self.deferredApply else { return }
            self.deferredTries += 1
            // 回中通常一两个周期就结束；兜底 0.6 秒后仍不停就强行落页，避免翻页卡住。
            if !self.pagerAtRest, self.deferredTries < 40 {
                self.scheduleDeferredApply()
                return
            }
            let forced = !self.pagerAtRest
            self.deferredApply = nil
            if self.displayed != deferred.position || self.appliedRevision != deferred.revision {
                self.apply(
                    deferred.position,
                    revision: deferred.revision,
                    animated: deferred.animated,
                    force: forced,
                    in: pageController
                )
            }
        }
        deferredWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: work)
    }

    private func cancelDeferredApply() {
        deferredApply = nil
        deferredWork?.cancel()
        deferredWork = nil
    }

    /// 占用全部解除后收敛：把排队期间的目标页补上。
    private func settle() {
        guard !flow.isBusy, let pageController else { return }
        guard !isFingerDown else {
            // 占用已解除但手指还按着：这一轮不落页，等看门狗在手指抬起后补落。
            armSettleWatchdog()
            return
        }
        cancelSettleWatchdog()
        if let request = flow.takePending() {
            // 排队期间手指跟手或后台排版回写都可能又推动过引擎，快照里的 position/revision
            // 已经过期；按当前引擎状态落位，只沿用当初那一次的动画意图。
            // 跟手那一下已经落到位的不用再补一遍，否则同页会再翻一次。
            let target = engine.position
            let revision = engine.layoutRevision
            if displayed != target || appliedRevision != revision {
                apply(target, revision: revision, animated: request.animated, in: pageController)
            }
        }
        sync()
    }

    private func armSettleWatchdog() {
        cancelSettleWatchdog()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.flow.isBusy || self.flow.pending != nil else { return }
            guard !self.isFingerDown else {
                self.armSettleWatchdog()
                return
            }
            // 系统弹窗、sheet、手势取消都可能让 UIKit 不再回调收尾；
            // 这里强制解除占用并落位，避免翻页永远卡在半空、也避免排队的目标页被吞掉。
            self.flow.forceIdle()
            self.settle()
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func cancelSettleWatchdog() {
        settleWork?.cancel()
        settleWork = nil
    }

    /// 手指是否还按在页面上。
    ///
    /// `.scroll` 样式下 UIPageViewController 的拖拽手势挂在内部 UIScrollView 上，既不在
    /// `pageController.gestureRecognizers`（实测为空），也不在 `pageController.view.gestureRecognizers`
    /// （那里只有我们自己的 readerTap）。只查这两处会永远得到 false，跟手保护形同虚设，
    /// 于是看门狗会在拖拽途中强制落页、收尾回调也会和手指那一段转场叠在一起。
    private var isFingerDown: Bool {
        guard let root = pageController?.view else { return false }
        var stack = [root]
        while let view = stack.popLast() {
            if view.gestureRecognizers?.contains(where: { $0.state == .began || $0.state == .changed }) == true {
                return true
            }
            stack.append(contentsOf: view.subviews)
        }
        return false
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        willTransitionTo pendingViewControllers: [UIViewController]
    ) {
        // 我们自己发起的动画转场也会回调这里，那种情况不能按跟手处理：
        // 跟手的收尾只靠 delegate，一旦不回调就会把后续翻页全堵在排队里。
        guard !flow.animated else { return }
        flow.beginInteractive()
        armSettleWatchdog()
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        let visible = pageViewController.viewControllers?.first as? PageContentController
        if let visible {
            // 屏幕上的这一页是唯一事实：不管翻成还是回弹，displayed 都对齐它。
            displayed = visible.position
        }
        if completed, let visible {
            let startedFrom = previousViewControllers.first as? PageContentController
            // 跟手期间引擎已被点按/自动朗读推进过，以引擎为准，不把位置回退到本次拖起的页。
            if startedFrom == nil || engine.position == startedFrom!.position {
                engine.adopt(position: visible.position)
            }
        }
        // appliedRevision 故意不动：它还停在可见页真正用的那一版，
        // 排队里的新排版（后台整章排完）才不会被误当成「已经应用过」。
        flow.endInteractive()
        settle()
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
        guard let page = viewController as? PageContentController,
              let previous = engine.neighbor(before: page.position) else { return nil }
        return makePage(previous)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        guard let page = viewController as? PageContentController else { return nil }
        if let next = engine.neighbor(after: page.position) {
            return makePage(next)
        }
        // 还停在章节交界时，不能再翻出“全书完”。
        if page.position.boundaryRemote != nil { return nil }
        guard page.position.chapterIndex < engine.chapters.count else { return nil }
        return makePage(ReaderPosition(chapterIndex: engine.chapters.count, pageIndex: 0))
    }

    private var effectiveMode: PageTurnMode {
        #if os(visionOS)
        if settings.pageMode == .curl { return .horizontal }
        #endif
        return settings.pageMode
    }

    private var highlightColor: UIColor {
        theme.isDark
            ? UIColor(red: 0.95, green: 0.78, blue: 0.35, alpha: 0.28)
            : UIColor(red: 0.92, green: 0.72, blue: 0.20, alpha: 0.35)
    }

    private func installPageController(_ mode: PageTurnMode) {
        if let pageController {
            pageController.willMove(toParent: nil)
            pageController.view.removeFromSuperview()
            pageController.removeFromParent()
        }
        // 旧控制器的转场随它一起没了，占用与排队都不能留到新控制器上。
        flow.reset()
        cancelSettleWatchdog()
        cancelDeferredApply()
        let style: UIPageViewController.TransitionStyle = mode == .curl ? .pageCurl : .scroll
        let orientation: UIPageViewController.NavigationOrientation = mode == .vertical ? .vertical : .horizontal
        var options: [UIPageViewController.OptionsKey: Any]?
        if style == .pageCurl {
            options = [.spineLocation: NSNumber(value: UIPageViewController.SpineLocation.min.rawValue)]
        }
        let controller = UIPageViewController(transitionStyle: style, navigationOrientation: orientation, options: options)
        controller.dataSource = self
        controller.delegate = self
        controller.isDoubleSided = false
        controller.view.backgroundColor = theme.background.platform
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controller.view)
        controller.didMove(toParent: self)
        pageController = controller
        installTap()
        updateForeignGestures()
    }

    private func updatePageSize() {
        let insets = measuredInsets(proposedTop: safeTop, proposedBottom: safeBottom)
        let placement = PageMetrics.placement(
            bounds: view.bounds.size,
            safeTop: insets.top,
            safeBottom: insets.bottom,
            marginX: CGFloat(settings.horizontalMargin),
            marginTop: CGFloat(settings.topMargin),
            marginBottom: CGFloat(settings.bottomMargin),
            showsHeader: settings.showsHeader,
            showsFooter: settings.showsFooter
        )
        textRect = placement.textRect
        engine.setPageSize(placement.pageSize)
    }

    private func measuredInsets(proposedTop: CGFloat, proposedBottom: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        guard let window = view.window else { return (proposedTop, proposedBottom) }
        let topY = view.convert(CGPoint.zero, to: window).y
        let bottomY = view.convert(CGPoint(x: 0, y: view.bounds.height), to: window).y
        let extraTop = window.safeAreaInsets.top - topY
        let extraBottom = bottomY - (window.bounds.height - window.safeAreaInsets.bottom)
        return (max(proposedTop, extraTop, 0), max(proposedBottom, extraBottom, 0))
    }

    private func makePage(_ position: ReaderPosition) -> PageContentController {
        let terminal = engine.isTerminal(position)
        // 按页取排版：首屏分页可能还没排到这一页，续排也比画空白页好。
        let laid = terminal ? nil : engine.layout(forChapter: position.chapterIndex, coveringPage: position.pageIndex)
        let page = PageContentController(
            position: position,
            chapterLayout: laid,
            theme: theme,
            textRect: textRect,
            terminal: terminal,
            terminalTitle: engine.terminalTitle(for: position),
            terminalDetail: engine.terminalDetail(for: position),
            fontName: settings.fontName
        )
        if position == engine.position {
            page.setHighlight(engine.highlightRange, color: highlightColor)
        }
        return page
    }

    private func direction(from: ReaderPosition, to: ReaderPosition) -> UIPageViewController.NavigationDirection {
        if to.chapterIndex != from.chapterIndex {
            return to.chapterIndex >= from.chapterIndex ? .forward : .reverse
        }
        return to.pageIndex >= from.pageIndex ? .forward : .reverse
    }

    private func installTap() {
        guard let host = pageController?.view else { return }
        host.gestureRecognizers?
            .filter { $0.name == "readerTap" || $0.name == "readerLongPress" }
            .forEach { host.removeGestureRecognizer($0) }
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.name = "readerTap"
        tap.cancelsTouchesInView = false
        tap.delegate = self
        // 不再让 tap 等待 UIPageViewController 的滑动/拖拽手势失败。
        // 手指抬起即可 0 延迟响应翻页或唤出菜单；若手指产生位移滑动，系统会自动将 Tap 判定为失效。
        host.addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.name = "readerLongPress"
        longPress.minimumPressDuration = 0.45
        longPress.cancelsTouchesInView = true
        host.addGestureRecognizer(longPress)
        tap.require(toFail: longPress)

        linkedGestureCount = pageController?.gestureRecognizers.count ?? 0
    }

    private func updateForeignGestures() {
        let paging = effectiveMode != .none
        pageController?.gestureRecognizers.forEach { gesture in
            if gesture is UITapGestureRecognizer {
                gesture.isEnabled = false
            } else if gesture.name != "readerTap" && gesture.name != "readerLongPress" {
                gesture.isEnabled = paging
            }
        }
    }

    private func updatePop() {
        let enabled: Bool
        switch settings.popGesture {
        case .disabled:
            enabled = false
        case .always:
            enabled = true
        case .antiMistouch:
            enabled = engine.showsChrome
        }
        navigationController?.interactivePopGestureRecognizer?.isEnabled = enabled
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // 手指还在跟手翻页：UIKit 自己会把这一页落完，这里再点一次会起第二段转场，
        // 两段半页叠在半空就是「两页卡在中间」。
        guard !isFingerDown else { return }
        let width = max(view.bounds.width, 1)
        engine.handleTap(xFraction: gesture.location(in: view).x / width)
        sync()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        guard let visible = pageController?.viewControllers?.first as? PageContentController else { return }
        let pointInPage = gesture.location(in: visible.view)
        guard let hit = visible.sentenceAt(pointInPage: pointInPage) else { return }
        visible.setHighlight(hit.range, color: highlightColor)
        let preview = hit.text.count > 26 ? String(hit.text.prefix(26)) + "…" : hit.text
        let sheet = UIAlertController(title: "选中句子", message: "「\(preview)」", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "复制句子", style: .default) { [weak visible, weak self] _ in
            UIPasteboard.general.string = hit.text
            visible?.setHighlight(self?.engine.highlightRange, color: self?.highlightColor ?? .clear)
        })
        sheet.addAction(UIAlertAction(title: "在书中搜索", style: .default) { [weak visible, weak self] _ in
            visible?.setHighlight(self?.engine.highlightRange, color: self?.highlightColor ?? .clear)
            self?.onSearchSelectedText?(hit.text)
        })
        sheet.addAction(UIAlertAction(title: "净化此句广告词", style: .destructive) { [weak visible, weak self] _ in
            visible?.setHighlight(self?.engine.highlightRange, color: self?.highlightColor ?? .clear)
            self?.settings.appendBlockWord(hit.text)
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak visible, weak self] _ in
            visible?.setHighlight(self?.engine.highlightRange, color: self?.highlightColor ?? .clear)
        })
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = visible.view
            popover.sourceRect = CGRect(origin: pointInPage, size: CGSize(width: 2, height: 2))
        }
        present(sheet, animated: true)
    }
}

final class PageContentController: UIViewController {
    let position: ReaderPosition
    private let canvas = PageCanvas()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let terminal: Bool
    private var textRect: CGRect

    init(
        position: ReaderPosition,
        chapterLayout: ChapterLayout?,
        theme: ReadingTheme,
        textRect: CGRect,
        terminal: Bool,
        terminalTitle: String,
        terminalDetail: String,
        fontName: String
    ) {
        self.position = position
        self.terminal = terminal
        self.textRect = textRect
        super.init(nibName: nil, bundle: nil)
        canvas.chapterLayout = chapterLayout
        canvas.pageIndex = position.pageIndex
        canvas.isHidden = terminal
        titleLabel.text = terminalTitle
        titleLabel.textAlignment = .center
        titleLabel.font = PlatformFont.make(name: fontName, size: 22, bold: true)
        detailLabel.text = terminalDetail
        detailLabel.textAlignment = .center
        detailLabel.font = PlatformFont.make(name: fontName, size: 15)
        titleLabel.isHidden = !terminal
        detailLabel.isHidden = !terminal || terminalDetail.isEmpty
        apply(textRect: textRect, theme: theme, fontName: fontName)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(canvas)
        view.addSubview(titleLabel)
        view.addSubview(detailLabel)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        canvas.frame = textRect
        titleLabel.frame = CGRect(x: 24, y: view.bounds.midY - 36, width: view.bounds.width - 48, height: 32)
        detailLabel.frame = CGRect(x: 24, y: view.bounds.midY + 4, width: view.bounds.width - 48, height: 24)
    }

    func apply(textRect: CGRect, theme: ReadingTheme, fontName: String) {
        self.textRect = textRect
        view.backgroundColor = theme.background.platform
        titleLabel.textColor = theme.text.platform
        detailLabel.textColor = theme.secondary.platform
        titleLabel.font = PlatformFont.make(name: fontName, size: 22, bold: true)
        detailLabel.font = PlatformFont.make(name: fontName, size: 15)
        view.setNeedsLayout()
        canvas.setNeedsDisplay()
    }

    func setHighlight(_ range: NSRange?, color: UIColor) {
        canvas.highlight = range
        canvas.highlightColor = color
        canvas.setNeedsDisplay()
    }

    /// 页没变、排版被换了一版：就地换掉画布上的排版，不重建视图控制器。
    func refresh(layout: ChapterLayout?, textRect: CGRect, theme: ReadingTheme, fontName: String) {
        canvas.chapterLayout = layout
        canvas.pageIndex = position.pageIndex
        apply(textRect: textRect, theme: theme, fontName: fontName)
    }

    /// 根据长按坐标定位所在句子范围与纯文本。
    func sentenceAt(pointInPage: CGPoint) -> (range: NSRange, text: String)? {
        guard !terminal,
              textRect.contains(pointInPage),
              let chapterLayout = canvas.chapterLayout,
              chapterLayout.containers.indices.contains(position.pageIndex),
              chapterLayout.characterRanges.indices.contains(position.pageIndex) else { return nil }
        let container = chapterLayout.containers[position.pageIndex]
        let pageRange = chapterLayout.characterRanges[position.pageIndex]
        let glyphs = chapterLayout.layoutManager.glyphRange(for: container)
        guard glyphs.length > 0 else { return nil }
        let firstFragment = chapterLayout.layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let localPoint = CGPoint(
            x: pointInPage.x - textRect.minX,
            y: pointInPage.y - textRect.minY + (abs(firstFragment.minY) > 0.5 ? firstFragment.minY : 0)
        )
        let charIdx = chapterLayout.layoutManager.characterIndex(
            for: localPoint,
            in: container,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        guard NSLocationInRange(charIdx, pageRange) else { return nil }
        let ns = chapterLayout.storage.string as NSString
        let delimiters = CharacterSet(charactersIn: "。！？；\n.!?;")
        var start = charIdx
        while start > pageRange.location {
            let prev = ns.character(at: start - 1)
            if let scalar = UnicodeScalar(prev), delimiters.contains(scalar) {
                break
            }
            start -= 1
        }
        var end = charIdx
        let maxEnd = NSMaxRange(pageRange)
        while end < maxEnd {
            let curr = ns.character(at: end)
            if let scalar = UnicodeScalar(curr), delimiters.contains(scalar) {
                if curr != 10 { end += 1 } // 包含句末标点，不包含换行
                break
            }
            end += 1
        }
        guard end > start else { return nil }
        let range = NSRange(location: start, length: end - start)
        let text = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return (range, text)
    }
}

final class PageCanvas: UIView {
    var chapterLayout: ChapterLayout?
    var pageIndex = 0
    var highlight: NSRange?
    var highlightColor = UIColor.systemYellow.withAlphaComponent(0.35)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ rect: CGRect) {
        guard let chapterLayout, chapterLayout.containers.indices.contains(pageIndex) else { return }
        let container = chapterLayout.containers[pageIndex]
        let glyphs = chapterLayout.layoutManager.glyphRange(for: container)
        guard glyphs.length > 0 else { return }
        let fragment = chapterLayout.layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        var origin = CGPoint.zero
        if abs(fragment.minY) > 0.5 {
            origin.y = -fragment.minY
        }
        if let highlight, highlight.length > 0, chapterLayout.characterRanges.indices.contains(pageIndex) {
            let intersection = NSIntersectionRange(highlight, chapterLayout.characterRanges[pageIndex])
            if intersection.length > 0 {
                let highlightGlyphs = chapterLayout.layoutManager.glyphRange(
                    forCharacterRange: intersection,
                    actualCharacterRange: nil
                )
                chapterLayout.layoutManager.enumerateEnclosingRects(
                    forGlyphRange: highlightGlyphs,
                    withinSelectedGlyphRange: highlightGlyphs,
                    in: container
                ) { glyphRect, _ in
                    self.highlightColor.setFill()
                    let drawRect = glyphRect.offsetBy(dx: origin.x, dy: origin.y)
                    UIBezierPath(roundedRect: drawRect, cornerRadius: 2).fill()
                }
            }
        }
        chapterLayout.layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }
}
#endif
