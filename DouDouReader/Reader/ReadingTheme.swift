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
    static let kraft = ReadingTheme(
        id: "kraft",
        name: "羊皮",
        background: RGBA(r: 0.945, g: 0.890, b: 0.776, a: 1),
        text: RGBA(r: 0.220, g: 0.157, b: 0.082, a: 1),
        secondary: RGBA(r: 0.45, g: 0.34, b: 0.20, a: 1),
        isDark: false
    )
    static let green = ReadingTheme(
        id: "green",
        name: "豆绿",
        background: RGBA(r: 0.800, g: 0.910, b: 0.812, a: 1),
        text: RGBA(r: 0.118, g: 0.200, b: 0.141, a: 1),
        secondary: RGBA(r: 0.28, g: 0.40, b: 0.32, a: 1),
        isDark: false
    )
    static let pine = ReadingTheme(
        id: "pine",
        name: "松花",
        background: RGBA(r: 0.882, g: 0.918, b: 0.855, a: 1),
        text: RGBA(r: 0.165, g: 0.212, b: 0.157, a: 1),
        secondary: RGBA(r: 0.36, g: 0.42, b: 0.35, a: 1),
        isDark: false
    )
    static let mistBlue = ReadingTheme(
        id: "mist_blue",
        name: "雾蓝",
        background: RGBA(r: 0.875, g: 0.914, b: 0.945, a: 1),
        text: RGBA(r: 0.137, g: 0.188, b: 0.239, a: 1),
        secondary: RGBA(r: 0.34, g: 0.40, b: 0.46, a: 1),
        isDark: false
    )
    static let lotusPink = ReadingTheme(
        id: "lotus_pink",
        name: "藕粉",
        background: RGBA(r: 0.957, g: 0.906, b: 0.902, a: 1),
        text: RGBA(r: 0.235, g: 0.153, b: 0.153, a: 1),
        secondary: RGBA(r: 0.46, g: 0.34, b: 0.34, a: 1),
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
    static let warmNight = ReadingTheme(
        id: "warm_night",
        name: "暖夜",
        background: RGBA(r: 0.145, g: 0.133, b: 0.122, a: 1),
        text: RGBA(r: 0.780, g: 0.733, b: 0.667, a: 1),
        secondary: RGBA(r: 0.52, g: 0.48, b: 0.42, a: 1),
        isDark: true
    )
    static let night = ReadingTheme(
        id: "night",
        name: "夜间",
        background: RGBA(r: 0.102, g: 0.102, b: 0.110, a: 1),
        text: RGBA(r: 0.784, g: 0.784, b: 0.800, a: 1),
        secondary: RGBA(r: 0.52, g: 0.52, b: 0.55, a: 1),
        isDark: true
    )

    static let choices: [ReadingTheme] = [paper, kraft, green, pine, mistBlue, lotusPink, gray, warmNight, night]

    static func resolve(id: String, interfaceDark: Bool) -> ReadingTheme {
        if id == "auto" {
            return interfaceDark ? night : paper
        }
        return choices.first { $0.id == id } ?? paper
    }
}
