import AVFoundation
import Foundation
import MediaPlayer
import ObjectiveC

private nonisolated(unsafe) var speechEpochKey: UInt8 = 0

@Observable
final class SpeechController: NSObject, AVSpeechSynthesizerDelegate {
    nonisolated(unsafe) private let synthesizer = AVSpeechSynthesizer()
    private var queue: [String] = []
    private var advance: Advance = .none
    private(set) var deadline: Date?
    private var speakingRate: Float = AVSpeechUtteranceDefaultSpeechRate
    private var speakingVoiceID: String = ""
    private var epoch = 0
    private var nowPlayingTitle: String = ""
    private var nowPlayingChapter: String = ""
    private var remoteCommandsInstalled = false

    var isActive = false
    var isPaused = false
    var onRange: ((NSRange) -> Void)?
    var onAdvance: ((Advance) -> Void)?
    var onRemoteSkip: ((Int) -> Void)?
    /// 朗读被系统音频中断（来电、其他 App 抢占）开始时的 UI 回调，主线程派发，仅在朗读活跃时触发。
    /// ReaderScreen 据此弹「朗读被中断」确认窗；默认 nil，由 UI 层注入。
    var onInterruptionBegan: (@MainActor () -> Void)?

    #if os(iOS) || os(visionOS)
    /// 音频会话中断通知的观察者令牌；register/unregister 成对出现，deinit 兜底注销。
    private var interruptionObserver: NSObjectProtocol?
    #endif

    enum Advance {
        case none
        case page
        case chapter
    }

    override init() {
        super.init()
        synthesizer.delegate = self
        #if os(iOS) || os(visionOS)
        registerInterruptionObserver()
        #endif
    }

    deinit {
        #if os(iOS) || os(visionOS)
        unregisterInterruptionObserver()
        #endif
    }

    func start(parts: [String], mode: SpeechReadMode, rate: Float, voiceID: String, sleepMinutes: Int, highlight: Bool) {
        let existingDeadline = deadline
        stop(preserveDeadline: true)
        let pieces = parts.flatMap { chunk($0) }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let first = pieces.first else { return }
        queue = Array(pieces.dropFirst())
        advance = mode == .page ? .page : .chapter
        speakingRate = rate
        speakingVoiceID = voiceID
        isActive = true
        isPaused = false
        if let existingDeadline, existingDeadline > Date() {
            deadline = existingDeadline
        } else if sleepMinutes > 0 {
            deadline = Date().addingTimeInterval(TimeInterval(sleepMinutes * 60))
        } else {
            deadline = nil
        }
        _ = highlight
        prepareAudio()
        installRemoteCommandsIfNeeded()
        publishNowPlaying()
        speak(first)
    }

    func stop(preserveDeadline: Bool = false) {
        epoch += 1
        queue.removeAll()
        advance = .none
        isActive = false
        isPaused = false
        if !preserveDeadline {
            deadline = nil
            clearNowPlaying()
        }
        synthesizer.stopSpeaking(at: .immediate)
        onRange?(NSRange(location: 0, length: 0))
    }

    func togglePause() {
        guard isActive else { return }
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            isPaused = false
        } else if synthesizer.isSpeaking {
            synthesizer.pauseSpeaking(at: .word)
            isPaused = true
        }
        publishNowPlaying()
    }

    func updateSleepTimer(minutes: Int) {
        if minutes > 0 {
            deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
        } else {
            deadline = nil
        }
    }

    func checkSleepDeadline(at now: Date = Date()) {
        guard isActive else { return }
        _ = expired(at: now)
    }

    func remainingSleepText(at now: Date = Date()) -> String? {
        guard let deadline else { return nil }
        let remaining = Int(deadline.timeIntervalSince(now).rounded(.up))
        guard remaining > 0 else { return nil }
        let mins = remaining / 60
        let secs = remaining % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    func updateNowPlaying(bookTitle: String, chapterTitle: String) {
        nowPlayingTitle = bookTitle
        nowPlayingChapter = chapterTitle
        if isActive {
            publishNowPlaying()
        }
    }

    private func installRemoteCommandsIfNeeded() {
        guard !remoteCommandsInstalled else { return }
        remoteCommandsInstalled = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            guard let self, self.isActive else { return .commandFailed }
            if self.isPaused { self.togglePause() }
            return .success
        }
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.isActive else { return .commandFailed }
            if !self.isPaused { self.togglePause() }
            return .success
        }
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.isActive else { return .commandFailed }
            self.togglePause()
            return .success
        }
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.isActive else { return .commandFailed }
            self.onRemoteSkip?(1)
            return .success
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, self.isActive else { return .commandFailed }
            self.onRemoteSkip?(-1)
            return .success
        }
    }

    private func publishNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlayingChapter.isEmpty ? "正在朗读" : nowPlayingChapter,
            MPMediaItemPropertyArtist: nowPlayingTitle.isEmpty ? "豆豆阅读" : nowPlayingTitle,
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0.0 : 1.0
        ]
        if let deadline {
            let remaining = max(0, deadline.timeIntervalSinceNow)
            info[MPMediaItemPropertyPlaybackDuration] = remaining
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.resolveVoice(identifier: speakingVoiceID)
        utterance.rate = speakingRate
        objc_setAssociatedObject(
            utterance,
            &speechEpochKey,
            NSNumber(value: epoch),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        synthesizer.speak(utterance)
    }

    private func chunk(_ text: String, limit: Int = 2800) -> [String] {
        let ns = text as NSString
        guard ns.length > limit else { return [text] }
        var parts: [String] = []
        var location = 0
        while location < ns.length {
            let remaining = ns.length - location
            if remaining <= limit {
                parts.append(ns.substring(from: location))
                break
            }
            var end = location + limit
            let window = ns.substring(with: NSRange(location: location, length: limit))
            if let range = window.range(of: "。", options: .backwards) {
                let prefixCount = String(window[..<range.upperBound]).utf16.count
                if prefixCount > limit / 4 {
                    end = location + prefixCount
                }
            }
            parts.append(ns.substring(with: NSRange(location: location, length: end - location)))
            location = end
        }
        return parts
    }

    private func prepareAudio() {
        #if os(iOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
        #endif
    }

    #if os(iOS) || os(visionOS)
    /// 注册音频会话中断通知观察者（init 时调用）。单独成方法，便于手动重新注册与单测。
    private func registerInterruptionObserver() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            self?.handleInterruptionNotification(note)
        }
    }

    /// 注销中断通知观察者（deinit 兜底，与 register 成对）。
    private func unregisterInterruptionObserver() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        interruptionObserver = nil
    }

    /// 解析中断通知类型，切到主 actor 后分派给 began/ended 处理。
    /// 通知回调可能在非主线程到达，与合成器 delegate 一样统一收口到主线程再改 UI 状态。
    nonisolated private func handleInterruptionNotification(_ note: Notification) {
        guard let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        Task { @MainActor in
            switch type {
            case .began:
                self.handleInterruptionBegan()
            case .ended:
                self.handleInterruptionEnded()
            @unknown default:
                break
            }
        }
    }
    #endif

    /// 中断开始：仅在朗读活跃时自动暂停合成器并同步 isPaused，随后触发 UI 回调弹窗。
    /// 用户已手动暂停期间（isPaused == true）直接忽略，避免被短暂音频抢占（如通知声）重复打扰。
    @MainActor
    private func handleInterruptionBegan() {
        guard isActive, !isPaused else { return }
        if synthesizer.isSpeaking, !synthesizer.isPaused {
            synthesizer.pauseSpeaking(at: .word)
        }
        isPaused = true
        onInterruptionBegan?()
    }

    /// 中断结束：只重新激活音频会话（.began 时系统会 deactivate 本 App 的会话，
    /// 不重新激活则「继续朗读」时 continueSpeaking 会无声）；
    /// 不自动恢复发声：synthesizer 保持暂停，由用户在弹窗里选「继续朗读」或「退出朗读」。
    @MainActor
    private func handleInterruptionEnded() {
        guard isActive else { return }
        // 用户已在弹窗选「退出朗读」时 isActive 为 false，无需重新激活。
        prepareAudio()
    }

    private func expired(at now: Date = Date()) -> Bool {
        if let deadline, now >= deadline {
            stop()
            return true
        }
        return false
    }

    nonisolated private static func storedEpoch(_ utterance: AVSpeechUtterance) -> Int? {
        (objc_getAssociatedObject(utterance, &speechEpochKey) as? NSNumber)?.intValue
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let range = characterRange
        let spokenEpoch = Self.storedEpoch(utterance)
        Task { @MainActor in
            guard spokenEpoch == self.epoch else { return }
            self.onRange?(range)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let spokenEpoch = Self.storedEpoch(utterance)
        Task { @MainActor in
            self.handleFinished(spokenEpoch)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let spokenEpoch = Self.storedEpoch(utterance)
        Task { @MainActor in
            guard spokenEpoch == self.epoch, !self.isActive else { return }
            self.onRange?(NSRange(location: 0, length: 0))
        }
    }

    private func handleFinished(_ spokenEpoch: Int?) {
        guard spokenEpoch == epoch, isActive else { return }
        if expired() { return }
        if !queue.isEmpty {
            let next = queue.removeFirst()
            speak(next)
            return
        }
        let step = advance
        onAdvance?(step)
    }

    /// 运行时枚举系统可用的中文音色（iOS/macOS/visionOS 列表不同），按名称排序。
    static func chineseVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") }
            .sorted { $0.name < $1.name }
    }

    /// 按用户选择的 identifier 解析音色；空 ID、不可用或列表为空时回落 zh-CN 默认语音。
    static func resolveVoice(identifier: String) -> AVSpeechSynthesisVoice? {
        if !identifier.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: "zh-CN")
    }
}
