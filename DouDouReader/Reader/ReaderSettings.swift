import Foundation
import Observation

enum PageTurnMode: String, Codable, CaseIterable, Identifiable {
    case curl
    case horizontal
    case vertical
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .curl: "仿真"
        case .horizontal: "左右"
        case .vertical: "上下"
        case .none: "无"
        }
    }
}

enum ChineseScript: Int, Codable, CaseIterable, Identifiable {
    case original = 0
    case simplified = 1
    case traditional = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .original: "原文"
        case .simplified: "简体"
        case .traditional: "繁体"
        }
    }
}

enum TextAlignmentChoice: Int, Codable, CaseIterable, Identifiable {
    case left = 0
    case center = 1
    case right = 2

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .left: "左"
        case .center: "中"
        case .right: "右"
        }
    }
}

enum PopGestureMode: Int, Codable, CaseIterable, Identifiable {
    case disabled = 0
    case antiMistouch = 1
    case always = 2

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .disabled: "禁用"
        case .antiMistouch: "防误触"
        case .always: "总是"
        }
    }
}

enum SpeechReadMode: Int, Codable, CaseIterable, Identifiable {
    case page = 0
    case chapter = 1

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .page: "按页"
        case .chapter: "按章"
        }
    }
}

struct LayoutSnapshot: Equatable, Hashable {
    var fontName: String
    var fontSize: Double
    var lineSpacing: Double
    var paragraphSpacing: Double
    var indentChars: Int
    var kern: Double
    var alignment: Int
    var script: Int
    var themeID: String
    var blockWords: String
    var interfaceDark: Bool
}

struct ChromeSnapshot: Equatable {
    var showsHeader: Bool
    var showsFooter: Bool
    var marginX: Double
    var marginTop: Double
    var marginBottom: Double
    var pageMode: String
}

@Observable
final class ReaderSettingsStore {
    var fontSize: Double = 20 { didSet { persist() } }
    var fontName: String = "" { didSet { persist() } }
    var lineSpacing: Double = 8 { didSet { persist() } }
    var paragraphSpacing: Double = 14 { didSet { persist() } }
    var indentChars: Int = 2 { didSet { persist() } }
    var horizontalMargin: Double = 22 { didSet { persist() } }
    var topMargin: Double = 4 { didSet { persist() } }
    var bottomMargin: Double = 4 { didSet { persist() } }
    var kern: Double = 0 { didSet { persist() } }
    var alignment: Int = 0 { didSet { persist() } }
    var themeID: String = "auto" { didSet { persist() } }
    /// 点「夜间」之前的主题，再点一次就回到这里。
    var dayThemeID: String = "paper" { didSet { persist() } }
    var pageModeRaw: String = PageTurnMode.curl.rawValue { didSet { persist() } }
    var scriptRaw: Int = 0 { didSet { persist() } }
    var brightness: Double = 1 { didSet { persist() } }
    var keepScreenOn: Bool = false { didSet { persist() } }
    var showTime: Bool = true { didSet { persist() } }
    var showBattery: Bool = true { didSet { persist() } }
    var showChapterTitle: Bool = true { didSet { persist() } }
    var showPageProgress: Bool = true { didSet { persist() } }
    var showBookPercent: Bool = true { didSet { persist() } }
    var popGestureRaw: Int = PopGestureMode.antiMistouch.rawValue { didSet { persist() } }
    var autoInterval: Double = 8 { didSet { persist() } }
    var speechRate: Double = 0.48 { didSet { persist() } }
    var speechModeRaw: Int = 0 { didSet { persist() } }
    /// 用户选择的朗读音色 identifier；空字符串表示系统默认 zh-CN。
    var speechVoiceID: String = "" { didSet { persist() } }
    var sleepMinutes: Int = 0 { didSet { persist() } }
    var blockWords: String = "" { didSet { persist() } }
    /// 极简模式：沉浸阅读态，隐藏页眉页脚与工具栏，点按中间唤出。
    var simpleMode: Bool = false { didSet { persist() } }

    private(set) var revision = 0
    private var ready = false

    var pageMode: PageTurnMode {
        get { PageTurnMode(rawValue: pageModeRaw) ?? .curl }
        set { pageModeRaw = newValue.rawValue }
    }

    var script: ChineseScript {
        get { ChineseScript(rawValue: scriptRaw) ?? .original }
        set { scriptRaw = newValue.rawValue }
    }

    var alignmentChoice: TextAlignmentChoice {
        get { TextAlignmentChoice(rawValue: alignment) ?? .left }
        set { alignment = newValue.rawValue }
    }

    var popGesture: PopGestureMode {
        get { PopGestureMode(rawValue: popGestureRaw) ?? .antiMistouch }
        set { popGestureRaw = newValue.rawValue }
    }

    var speechMode: SpeechReadMode {
        get { SpeechReadMode(rawValue: speechModeRaw) ?? .page }
        set { speechModeRaw = newValue.rawValue }
    }

    var showsHeader: Bool { showTime || showBattery || showChapterTitle }
    var showsFooter: Bool { showPageProgress || showBookPercent }

    convenience init() {
        self.init(loadSaved: true)
    }

    /// `loadSaved == false` keeps the in-memory defaults and never writes UserDefaults.
    /// Logic checks use it so a test run cannot replace the reader's saved settings.
    init(loadSaved: Bool) {
        if loadSaved,
           let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            fontSize = stored.fontSize
            fontName = stored.fontName
            lineSpacing = stored.lineSpacing
            paragraphSpacing = stored.paragraphSpacing
            indentChars = stored.indentChars
            horizontalMargin = stored.horizontalMargin
            topMargin = stored.topMargin
            bottomMargin = stored.bottomMargin
            kern = stored.kern
            alignment = stored.alignment
            themeID = stored.themeID
            dayThemeID = stored.dayThemeID
            pageModeRaw = stored.pageModeRaw
            scriptRaw = stored.scriptRaw
            brightness = stored.brightness
            keepScreenOn = stored.keepScreenOn
            showTime = stored.showTime
            showBattery = stored.showBattery
            showChapterTitle = stored.showChapterTitle
            showPageProgress = stored.showPageProgress
            showBookPercent = stored.showBookPercent
            popGestureRaw = stored.popGestureRaw
            autoInterval = stored.autoInterval
            speechRate = stored.speechRate
            speechModeRaw = stored.speechModeRaw
            speechVoiceID = stored.speechVoiceID
            sleepMinutes = stored.sleepMinutes
            blockWords = stored.blockWords
            simpleMode = stored.simpleMode ?? false
        }
        clamp()
        ready = loadSaved
    }

    func layoutSnapshot(interfaceDark: Bool) -> LayoutSnapshot {
        LayoutSnapshot(
            fontName: fontName,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing,
            indentChars: indentChars,
            kern: kern,
            alignment: alignment,
            script: scriptRaw,
            themeID: themeID,
            blockWords: blockWords,
            interfaceDark: interfaceDark
        )
    }

    func chromeSnapshot() -> ChromeSnapshot {
        ChromeSnapshot(
            showsHeader: showsHeader,
            showsFooter: showsFooter,
            marginX: horizontalMargin,
            marginTop: topMargin,
            marginBottom: bottomMargin,
            pageMode: pageModeRaw
        )
    }

    func theme(interfaceDark: Bool) -> ReadingTheme {
        ReadingThemes.resolve(id: themeID, interfaceDark: interfaceDark)
    }

    private func clamp() {
        fontSize = min(40, max(14, fontSize))
        lineSpacing = min(36, max(0, lineSpacing))
        paragraphSpacing = min(48, max(0, paragraphSpacing))
        indentChars = min(4, max(0, indentChars))
        horizontalMargin = min(56, max(12, horizontalMargin))
        brightness = min(1, max(0.45, brightness))
        autoInterval = min(30, max(3, autoInterval))
        speechRate = min(0.8, max(0.32, speechRate))
    }

    private func persist() {
        guard ready else { return }
        revision += 1
        let stored = Stored(store: self)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private static let storageKey = "doudou.reader.settings.v1"

    private struct Stored: Codable {
        var fontSize: Double
        var fontName: String
        var lineSpacing: Double
        var paragraphSpacing: Double
        var indentChars: Int
        var horizontalMargin: Double
        var topMargin: Double
        var bottomMargin: Double
        var kern: Double
        var alignment: Int
        var themeID: String
        var dayThemeID: String
        var pageModeRaw: String
        var scriptRaw: Int
        var brightness: Double
        var keepScreenOn: Bool
        var showTime: Bool
        var showBattery: Bool
        var showChapterTitle: Bool
        var showPageProgress: Bool
        var showBookPercent: Bool
        var popGestureRaw: Int
        var autoInterval: Double
        var speechRate: Double
        var speechModeRaw: Int
        var speechVoiceID: String
        var sleepMinutes: Int
        var blockWords: String
        /// 可选：旧存档没有这个字段，解码时回退为 false。
        var simpleMode: Bool?

        init(store: ReaderSettingsStore) {
            fontSize = store.fontSize
            fontName = store.fontName
            lineSpacing = store.lineSpacing
            paragraphSpacing = store.paragraphSpacing
            indentChars = store.indentChars
            horizontalMargin = store.horizontalMargin
            topMargin = store.topMargin
            bottomMargin = store.bottomMargin
            kern = store.kern
            alignment = store.alignment
            themeID = store.themeID
            dayThemeID = store.dayThemeID
            pageModeRaw = store.pageModeRaw
            scriptRaw = store.scriptRaw
            brightness = store.brightness
            keepScreenOn = store.keepScreenOn
            showTime = store.showTime
            showBattery = store.showBattery
            showChapterTitle = store.showChapterTitle
            showPageProgress = store.showPageProgress
            showBookPercent = store.showBookPercent
            popGestureRaw = store.popGestureRaw
            autoInterval = store.autoInterval
            speechRate = store.speechRate
            speechModeRaw = store.speechModeRaw
            speechVoiceID = store.speechVoiceID
            sleepMinutes = store.sleepMinutes
            blockWords = store.blockWords
            simpleMode = store.simpleMode
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 20
            fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? ""
            lineSpacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 8
            paragraphSpacing = try c.decodeIfPresent(Double.self, forKey: .paragraphSpacing) ?? 14
            indentChars = try c.decodeIfPresent(Int.self, forKey: .indentChars) ?? 2
            horizontalMargin = try c.decodeIfPresent(Double.self, forKey: .horizontalMargin) ?? 22
            topMargin = try c.decodeIfPresent(Double.self, forKey: .topMargin) ?? 4
            bottomMargin = try c.decodeIfPresent(Double.self, forKey: .bottomMargin) ?? 4
            kern = try c.decodeIfPresent(Double.self, forKey: .kern) ?? 0
            alignment = try c.decodeIfPresent(Int.self, forKey: .alignment) ?? 0
            themeID = try c.decodeIfPresent(String.self, forKey: .themeID) ?? "auto"
            dayThemeID = try c.decodeIfPresent(String.self, forKey: .dayThemeID) ?? "paper"
            pageModeRaw = try c.decodeIfPresent(String.self, forKey: .pageModeRaw) ?? PageTurnMode.curl.rawValue
            scriptRaw = try c.decodeIfPresent(Int.self, forKey: .scriptRaw) ?? 0
            brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 1
            keepScreenOn = try c.decodeIfPresent(Bool.self, forKey: .keepScreenOn) ?? false
            showTime = try c.decodeIfPresent(Bool.self, forKey: .showTime) ?? true
            showBattery = try c.decodeIfPresent(Bool.self, forKey: .showBattery) ?? true
            showChapterTitle = try c.decodeIfPresent(Bool.self, forKey: .showChapterTitle) ?? true
            showPageProgress = try c.decodeIfPresent(Bool.self, forKey: .showPageProgress) ?? true
            showBookPercent = try c.decodeIfPresent(Bool.self, forKey: .showBookPercent) ?? true
            popGestureRaw = try c.decodeIfPresent(Int.self, forKey: .popGestureRaw) ?? 1
            autoInterval = try c.decodeIfPresent(Double.self, forKey: .autoInterval) ?? 8
            speechRate = try c.decodeIfPresent(Double.self, forKey: .speechRate) ?? 0.48
            speechModeRaw = try c.decodeIfPresent(Int.self, forKey: .speechModeRaw) ?? 0
            speechVoiceID = try c.decodeIfPresent(String.self, forKey: .speechVoiceID) ?? ""
            sleepMinutes = try c.decodeIfPresent(Int.self, forKey: .sleepMinutes) ?? 0
            blockWords = try c.decodeIfPresent(String.self, forKey: .blockWords) ?? ""
            simpleMode = try c.decodeIfPresent(Bool.self, forKey: .simpleMode)
        }
    }
}
