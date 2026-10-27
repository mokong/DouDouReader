import Foundation

nonisolated enum ChineseConverter {
    static func convert(_ text: String, to script: ChineseScript) -> String {
        switch script {
        case .original:
            return text
        case .simplified:
            return transform(text, "Hant-Hans")
        case .traditional:
            return transform(text, "Hans-Hant")
        }
    }

    private static func transform(_ text: String, _ name: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, name as CFString, false)
        return mutable as String
    }
}
