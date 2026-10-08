import CoreText
import CryptoKit
import Foundation

struct ReaderFont: Identifiable, Hashable {
    var displayName: String
    var postScriptName: String
    var id: String { postScriptName }
}

enum FontRegistry {
    private static let candidates: [(String, String)] = [
        ("系统", ""),
        ("苹方", "PingFangSC-Regular"),
        ("宋体", "SongtiSC-Regular"),
        ("楷体", "KaitiSC-Regular"),
        ("黑体", "STHeitiSC-Light"),
        ("手札", "HannotateSC-W5"),
    ]

    private static var imported: [ReaderFont] = []

    static func registerAll() {
        let directory = BookStorage.fontsDirectory
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for url in urls where ["ttf", "otf", "ttc"].contains(url.pathExtension.lowercased()) {
            _ = register(url: url)
        }
    }

    @discardableResult
    static func importFont(from url: URL) throws -> ReaderFont {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw ImportError.fontUnreadable }
        let ext = url.pathExtension.isEmpty ? "ttf" : url.pathExtension.lowercased()
        let digest = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
        let destination = BookStorage.fontsDirectory.appendingPathComponent("\(digest).\(ext)")
        if !FileManager.default.fileExists(atPath: destination.path) {
            try data.write(to: destination, options: .atomic)
        }
        guard let face = register(url: destination) else { throw ImportError.fontUnreadable }
        return face
    }

    static func available(current: String = "") -> [ReaderFont] {
        var faces = candidates.compactMap { display, name -> ReaderFont? in
            guard name.isEmpty || PlatformFont.exists(name) else { return nil }
            return ReaderFont(displayName: display, postScriptName: name)
        }
        for face in imported where !faces.contains(where: { $0.postScriptName == face.postScriptName }) {
            faces.append(face)
        }
        if !current.isEmpty, !faces.contains(where: { $0.postScriptName == current }) {
            faces.append(ReaderFont(displayName: current, postScriptName: current))
        }
        return faces
    }

    private static func register(url: URL) -> ReaderFont? {
        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if let error {
            let nsError = error.takeRetainedValue() as Error as NSError
            let alreadyRegistered = nsError.code == CTFontManagerError.alreadyRegistered.rawValue
            if !registered && !alreadyRegistered { return nil }
        } else if !registered {
            return nil
        }
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first else {
            return nil
        }
        let font = CTFontCreateWithFontDescriptor(descriptor, 0, nil)
        let postScript = CTFontCopyPostScriptName(font) as String
        guard !postScript.isEmpty else { return nil }
        let display = CTFontCopyDisplayName(font) as String
        let face = ReaderFont(
            displayName: display.isEmpty ? postScript : display,
            postScriptName: postScript
        )
        if !imported.contains(where: { $0.postScriptName == postScript }) {
            imported.append(face)
        }
        return face
    }
}
