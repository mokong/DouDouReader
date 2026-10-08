import Foundation

struct ReadingTheme: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var background: RGBA
    var text: RGBA
    var secondary: RGBA
    var isDark: Bool
}

enum ReadingThemes {
    static let paper = ReadingTheme(
        id: "paper",
        name: "纸白",
        background: RGBA(r: 0.965, g: 0.945, b: 0.906, a: 1),
        text: RGBA(r: 0.173, g: 0.141, b: 0.086, a: 1),
        secondary: RGBA(r: 0.42, g: 0.36, b: 0.28, a: 1),
        isDark: false
    )
    static let green = ReadingTheme(
        id: "green",
        name: "护眼",
        background: RGBA(r: 0.800, g: 0.910, b: 0.812, a: 1),
        text: RGBA(r: 0.118, g: 0.200, b: 0.141, a: 1),
        secondary: RGBA(r: 0.28, g: 0.40, b: 0.32, a: 1),
        isDark: false
    )
    static let kraft = ReadingTheme(
        id: "kraft",
        name: "羊皮",
        background: RGBA(r: 0.953, g: 0.902, b: 0.784, a: 1),
        text: RGBA(r: 0.227, g: 0.165, b: 0.086, a: 1),
        secondary: RGBA(r: 0.45, g: 0.34, b: 0.20, a: 1),
        isDark: false
    )
    static let gray = ReadingTheme(
        id: "gray",
        name: "烟灰",
        background: RGBA(r: 0.902, g: 0.902, b: 0.902, a: 1),
        text: RGBA(r: 0.133, g: 0.133, b: 0.133, a: 1),
        secondary: RGBA(r: 0.38, g: 0.38, b: 0.38, a: 1),
        isDark: false
    )
    static let night = ReadingTheme(
        id: "night",
        name: "夜间",
        background: RGBA(r: 0.110, g: 0.110, b: 0.118, a: 1),
        text: RGBA(r: 0.784, g: 0.784, b: 0.800, a: 1),
        secondary: RGBA(r: 0.55, g: 0.55, b: 0.58, a: 1),
        isDark: true
    )

    static let choices: [ReadingTheme] = [paper, green, kraft, gray, night]

    static func resolve(id: String, interfaceDark: Bool) -> ReadingTheme {
        if id == "auto" {
            return interfaceDark ? night : paper
        }
        return choices.first { $0.id == id } ?? paper
    }
}
