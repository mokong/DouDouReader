import AVFoundation
import Foundation
import ObjectiveC

private nonisolated(unsafe) var speechEpochKey: UInt8 = 0

@Observable
final class SpeechController: NSObject, AVSpeechSynthesizerDelegate {
    nonisolated(unsafe) private let synthesizer = AVSpeechSynthesizer()
    private var queue: [String] = []
    private var advance: Advance = .none
    private var deadline: Date?
    private var speakingRate: Float = AVSpeechUtteranceDefaultSpeechRate
    private var epoch = 0

    var isActive = false
    var isPaused = false
    var onRange: ((NSRange) -> Void)?
    var onAdvance: ((Advance) -> Void)?

    enum Advance {
        case none
        case page
        case chapter
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func start(parts: [String], mode: SpeechReadMode, rate: Float, sleepMinutes: Int, highlight: Bool) {
        stop()
        let pieces = parts.flatMap { chunk($0) }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let first = pieces.first else { return }
        queue = Array(pieces.dropFirst())
        advance = mode == .page ? .page : .chapter
        speakingRate = rate
        isActive = true
        isPaused = false
        if sleepMinutes > 0 {
            deadline = Date().addingTimeInterval(TimeInterval(sleepMinutes * 60))
        } else {
            deadline = nil
        }
        _ = highlight
        prepareAudio()
        speak(first)
    }

    func stop() {
        epoch += 1
        queue.removeAll()
        advance = .none
        isActive = false
        isPaused = false
        deadline = nil
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
    }

    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
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

    private func expired() -> Bool {
        if let deadline, Date() >= deadline {
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
}
