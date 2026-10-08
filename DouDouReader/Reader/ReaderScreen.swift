import SwiftData
import SwiftUI
#if os(iOS) || os(visionOS)
import UIKit
#endif

struct ReaderScreen: View {
    var book: BookRecord
    @Environment(ReaderSettingsStore.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.deviceColorScheme) private var deviceColorScheme
    @State private var engine: ReaderEngine?
    @State private var loadError: String?
    @State private var showCatalog = false
    @State private var showSearch = false
    @State private var showBookmarks = false
    @State private var showSettings = false
    @State private var padTop = ScreenSafeArea.windowInsets.top
    @State private var padBottom = ScreenSafeArea.windowInsets.bottom

    var body: some View {
        Group {
            if let engine {
                reader(engine)
            } else if let loadError {
                missing(loadError)
            } else {
                ProgressView("正在打开")
            }
        }
        .task { openBook() }
        .onDisappear { engine?.stopActivities() }
    }

    @ViewBuilder
    private func reader(_ engine: ReaderEngine) -> some View {
        let theme = settings.theme(interfaceDark: deviceColorScheme == .dark)
        GeometryReader { proxy in
            let safeTop = max(proxy.safeAreaInsets.top, padTop)
            let safeBottom = max(proxy.safeAreaInsets.bottom, padBottom)
            let placement = PageMetrics.placement(
                bounds: proxy.size,
                safeTop: safeTop,
                safeBottom: safeBottom,
                marginX: CGFloat(settings.horizontalMargin),
                marginTop: CGFloat(settings.topMargin),
                marginBottom: CGFloat(settings.bottomMargin),
                showsHeader: settings.showsHeader,
                showsFooter: settings.showsFooter
            )
            ZStack {
                theme.background.color
                pageBody(engine, theme: theme, safeTop: safeTop, safeBottom: safeBottom)
                pageWidgets(engine, theme: theme, placement: placement, safeTop: safeTop, safeBottom: safeBottom)
                    .allowsHitTesting(false)
                Color.black.opacity(1 - settings.brightness)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                if engine.showsChrome {
                    topBar(engine, theme: theme)
                        .padding(.top, safeTop)
                }
            }
            .overlay(alignment: .bottom) {
                if engine.showsChrome {
                    bottomBar(engine, theme: theme)
                        .padding(.bottom, safeBottom)
                }
            }
            #if os(iOS) || os(visionOS)
            .background {
                SafeAreaProbe { top, bottom in
                    if abs(top - padTop) > 0.5 { padTop = top }
                    if abs(bottom - padBottom) > 0.5 { padBottom = bottom }
                }
            }
            #endif
        }
        .ignoresSafeArea()
        .background(theme.background.color.ignoresSafeArea())
        #if os(iOS) || os(visionOS)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear { sync(engine) }
        .onChange(of: settings.revision) { _, _ in sync(engine) }
        .onChange(of: deviceColorScheme) { _, _ in sync(engine) }
        .onChange(of: settings.keepScreenOn) { _, _ in updateIdleTimer() }
        .sheet(isPresented: $showCatalog) {
            CatalogSheet(engine: engine) { index in
                engine.jump(to: index)
                showCatalog = false
                engine.showsChrome = false
            }
        }
        .sheet(isPresented: $showSearch) {
            SearchSheet(engine: engine) { offset in
                engine.seek(to: offset)
                showSearch = false
                engine.showsChrome = false
            }
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarkSheet(book: book, engine: engine) { offset in
                engine.seek(to: offset)
                showBookmarks = false
                engine.showsChrome = false
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsPanel(settings: settings)
        }
        #if os(iOS)
        .onAppear { updateIdleTimer() }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
    }

    @ViewBuilder
    private func pageBody(_ engine: ReaderEngine, theme: ReadingTheme, safeTop: CGFloat, safeBottom: CGFloat) -> some View {
        #if os(iOS) || os(visionOS)
        ReaderContainer(engine: engine, settings: settings, theme: theme, safeTop: safeTop, safeBottom: safeBottom)
        #else
        MacPageView(engine: engine, settings: settings, theme: theme, safeTop: safeTop, safeBottom: safeBottom)
        #endif
    }

    private func pageWidgets(
        _ engine: ReaderEngine,
        theme: ReadingTheme,
        placement: (textRect: CGRect, pageSize: CGSize),
        safeTop: CGFloat,
        safeBottom: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            if settings.showsHeader {
                HStack(spacing: 8) {
                    if settings.showTime {
                        TimelineView(.periodic(from: .now, by: 30)) { timeline in
                            Text(ReaderClock.text(timeline.date))
                        }
                    }
                    Spacer(minLength: 8)
                    if settings.showChapterTitle {
                        Text(engine.currentTitle)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if settings.showBattery {
                        Text(batteryText())
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(theme.secondary.color)
                .padding(.horizontal, placement.textRect.minX)
                .padding(.top, safeTop + 8)
            }
            Spacer()
            if settings.showsFooter {
                HStack {
                    if settings.showPageProgress {
                        Text(engine.pageLabel)
                    }
                    Spacer()
                    if settings.showBookPercent {
                        Text(engine.percentLabel)
                    }
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(theme.secondary.color)
                .padding(.horizontal, placement.textRect.minX)
                .padding(.bottom, safeBottom + 6)
            }
        }
    }

    private func topBar(_ engine: ReaderEngine, theme: ReadingTheme) -> some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("返回")
            Text(book.title)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Text(engine.currentTitle)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .foregroundStyle(theme.text.color)
    }

    private func bottomBar(_ engine: ReaderEngine, theme: ReadingTheme) -> some View {
        HStack(spacing: 0) {
            barButton("目录", systemImage: "list.bullet") { showCatalog = true }
            barButton("搜索", systemImage: "magnifyingglass") { showSearch = true }
            barButton("书签", systemImage: "bookmark") { showBookmarks = true }
            barButton(engine.speech.isActive ? "停止" : "朗读", systemImage: engine.speech.isActive ? "speaker.slash" : "speaker.wave.2") {
                engine.toggleSpeech()
            }
            if engine.speech.isActive {
                barButton(engine.speech.isPaused ? "继续" : "暂停", systemImage: engine.speech.isPaused ? "play" : "pause") {
                    engine.speech.togglePause()
                }
            }
            barButton(engine.isAutoReading ? "停止翻" : "自动", systemImage: "timer") {
                if engine.isAutoReading {
                    engine.stopAuto()
                } else {
                    engine.startAuto()
                }
            }
            barButton("排版", systemImage: "textformat.size") { showSettings = true }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .foregroundStyle(theme.text.color)
    }

    private func barButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func missing(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
            Button("返回", action: { dismiss() })
        }
    }

    private func openBook() {
        guard engine == nil else { return }
        do {
            let text = try BookStorage.read(fileName: book.fileName)
            let created = ReaderEngine(
                text: text,
                fallbackTitle: book.title,
                startOffset: book.utf16Offset,
                settings: settings
            )
            created.onProgress = { chapter, offset, title in
                book.chapterIndex = chapter
                book.utf16Offset = offset
                book.currentChapterTitle = title
                book.lastReadAt = Date()
                try? modelContext.save()
            }
            created.applySettings(settings, interfaceDark: deviceColorScheme == .dark)
            engine = created
            updateIdleTimer()
        } catch {
            loadError = "这本书的文件打不开"
        }
    }

    private func sync(_ engine: ReaderEngine) {
        engine.applySettings(settings, interfaceDark: deviceColorScheme == .dark)
        updateIdleTimer()
    }

    private func updateIdleTimer() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        #endif
    }

    private func batteryText() -> String {
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return "—" }
        return "\(Int((level * 100).rounded()))%"
        #else
        return "—"
        #endif
    }
}

enum ReaderClock {
    static func text(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

#if os(iOS) || os(visionOS)
private struct SafeAreaProbe: UIViewRepresentable {
    var onChange: (_ top: CGFloat, _ bottom: CGFloat) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.onChange = onChange
    }

    final class ProbeView: UIView {
        var onChange: ((_ top: CGFloat, _ bottom: CGFloat) -> Void)?
        private var lastTop = CGFloat(-1)
        private var lastBottom = CGFloat(-1)

        override func didMoveToWindow() {
            super.didMoveToWindow()
            publish()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            publish()
        }

        private func publish() {
            guard let window, bounds.height > 1 else { return }
            let topY = convert(CGPoint.zero, to: window).y
            let bottomY = convert(CGPoint(x: 0, y: bounds.height), to: window).y
            let extraTop = max(0, window.safeAreaInsets.top - topY)
            let extraBottom = max(0, bottomY - (window.bounds.height - window.safeAreaInsets.bottom))
            guard abs(extraTop - lastTop) > 0.5 || abs(extraBottom - lastBottom) > 0.5 else { return }
            lastTop = extraTop
            lastBottom = extraBottom
            let callback = onChange
            Task { @MainActor in
                callback?(extraTop, extraBottom)
            }
        }
    }
}
#endif

#if os(macOS)
import AppKit

struct MacPageView: View {
    var engine: ReaderEngine
    var settings: ReaderSettingsStore
    var theme: ReadingTheme
    var safeTop: CGFloat
    var safeBottom: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let placement = PageMetrics.placement(
                bounds: proxy.size,
                safeTop: safeTop,
                safeBottom: safeBottom,
                marginX: CGFloat(settings.horizontalMargin),
                marginTop: CGFloat(settings.topMargin),
                marginBottom: CGFloat(settings.bottomMargin),
                showsHeader: settings.showsHeader,
                showsFooter: settings.showsFooter
            )
            ZStack {
                Color.clear
                page(engine)
                    .frame(width: placement.pageSize.width, height: placement.pageSize.height, alignment: .topLeading)
                    .position(x: placement.textRect.midX, y: placement.textRect.midY)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                engine.handleTap(xFraction: location.x / max(proxy.size.width, 1))
            }
            .onAppear { engine.setPageSize(placement.pageSize) }
            .onChange(of: placement.pageSize) { _, newSize in
                engine.setPageSize(newSize)
            }
        }
        .focusable()
        .onKeyPress(.leftArrow) {
            engine.go(delta: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            engine.go(delta: 1)
            return .handled
        }
    }

    @ViewBuilder
    private func page(_ engine: ReaderEngine) -> some View {
        if engine.isEnd {
            VStack(spacing: 8) {
                Text("全书完")
                    .font(.title2.bold())
                Text("这本读完了")
                    .foregroundStyle(theme.secondary.color)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(theme.text.color)
        } else if let layout = engine.layout(for: engine.position.chapterIndex),
                  layout.characterRanges.indices.contains(engine.position.pageIndex) {
            Text(attributedPage(layout, page: engine.position.pageIndex))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Color.clear
        }
    }

    private func attributedPage(_ layout: ChapterLayout, page: Int) -> AttributedString {
        let pageRange = layout.characterRanges[page]
        let mutable = NSMutableAttributedString(attributedString: layout.storage.attributedSubstring(from: pageRange))
        if let highlight = engine.highlightRange {
            let local = NSIntersectionRange(highlight, pageRange)
            if local.length > 0 {
                mutable.addAttribute(
                    .backgroundColor,
                    value: NSColor.systemYellow.withAlphaComponent(0.45),
                    range: NSRange(location: local.location - pageRange.location, length: local.length)
                )
            }
        }
        return AttributedString(mutable)
    }
}
#endif
