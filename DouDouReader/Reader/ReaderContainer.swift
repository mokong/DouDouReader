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

    func makeUIViewController(context: Context) -> ReaderPagesController {
        ReaderPagesController(engine: engine, settings: settings)
    }

    func updateUIViewController(_ controller: ReaderPagesController, context: Context) {
        controller.engine = engine
        controller.settings = settings
        controller.theme = theme
        controller.safeTop = safeTop
        controller.safeBottom = safeBottom
        controller.sync()
    }
}

final class ReaderPagesController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    var engine: ReaderEngine
    var settings: ReaderSettingsStore
    var theme: ReadingTheme = ReadingThemes.paper
    var safeTop: CGFloat = 0
    var safeBottom: CGFloat = 0

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
            // 「无」模式的语义就是不出动画：引擎给点按/自动朗读设的 animateNextTurn 在这里收口。
            // displayed.chapterIndex < 0 是首屏落位，同样不播动画，否则一打开书就先翻一页。
            let wantsAnimation = engine.animateNextTurn && mode != .none && displayed.chapterIndex >= 0
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
        in pageController: UIPageViewController
    ) {
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
        pageController.setViewControllers([targetVC], direction: direction, animated: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.finishAnimated(targetVC: targetVC, in: pageController)
            }
        }
    }

    private func finishAnimated(targetVC: PageContentController, in pageController: UIPageViewController) {
        // 只在「这一页仍然是屏幕上那一页」时补落：这次强落是为了压掉转场残留的半页图层，
        // 若期间手指已经拖到别的页，再落 targetVC 就是把读者往回拽。
        if !flow.interactive, !isFingerDown, pageController.viewControllers?.first === targetVC {
            // 方向不参与动画：非动画再落一次，只把 presentation layer 压回终态。
            pageController.setViewControllers([targetVC], direction: .forward, animated: false, completion: nil)
        }
        flow.endAnimated()
        settle()
    }

    /// 占用全部解除后收敛：先按非动画落一次终态，再把排队期间的目标页补上。
    private func settle() {
        guard !flow.isBusy, let pageController else { return }
        guard !isFingerDown else {
            // 占用已解除但手指还按着：这一轮不落页，等看门狗在手指抬起后补落。
            armSettleWatchdog()
            return
        }
        cancelSettleWatchdog()
        if let visible = pageController.viewControllers, !visible.isEmpty {
            pageController.setViewControllers(visible, direction: .forward, animated: false, completion: nil)
        }
        if let request = flow.takePending(),
           // 跟手那一下已经落到位的请求不用再补一遍，否则同页会再翻一次。
           displayed != request.position || appliedRevision != request.revision {
            apply(request.position, revision: request.revision, animated: request.animated, in: pageController)
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

    private var isFingerDown: Bool {
        let recognizers = (pageController?.gestureRecognizers ?? []) + (pageController?.view.gestureRecognizers ?? [])
        return recognizers.contains { $0.state == .began || $0.state == .changed }
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
            .filter { $0.name == "readerTap" }
            .forEach { host.removeGestureRecognizer($0) }
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.name = "readerTap"
        tap.cancelsTouchesInView = false
        tap.delegate = self
        // 不再让 tap 等待 UIPageViewController 的滑动/拖拽手势失败。
        // 手指抬起即可 0 延迟响应翻页或唤出菜单；若手指产生位移滑动，系统会自动将 Tap 判定为失效。
        host.addGestureRecognizer(tap)
        linkedGestureCount = pageController?.gestureRecognizers.count ?? 0
    }

    private func updateForeignGestures() {
        let paging = effectiveMode != .none
        pageController?.gestureRecognizers.forEach { gesture in
            if gesture is UITapGestureRecognizer {
                gesture.isEnabled = false
            } else if gesture.name != "readerTap" {
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
