import SwiftData
import SwiftUI
#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@main
struct MyApp: App {
    @State private var settings = ReaderSettingsStore()
    @Environment(\.scenePhase) private var scenePhase
    private let container: ModelContainer

    init() {
        FontRegistry.registerAll()
        do {
            container = try ModelContainer(for: BookRecord.self, BookmarkRecord.self, SourceRecord.self)
        } catch {
            fatalError("无法打开书架数据库：\(error)")
        }
        LogicChecks.exitIfRequested()
        #if os(macOS)
        ScreenshotExporter.exportIfRequested(container: container)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            SystemAppearanceReader {
                HomeShell()
            }
            .environment(settings)
            .modelContainer(container)
            .onChange(of: scenePhase) { _, phase in
                // 设置写盘是去抖的，退到后台可能就没有下一次机会了。
                if phase != .active { settings.flush() }
            }
        }
    }
}

/// The shelf forces a light paper scheme. Reading still needs the device appearance for the auto theme.
struct DeviceColorSchemeKey: EnvironmentKey {
    static let defaultValue: ColorScheme = .light
}

extension EnvironmentValues {
    var deviceColorScheme: ColorScheme {
        get { self[DeviceColorSchemeKey.self] }
        set { self[DeviceColorSchemeKey.self] = newValue }
    }
}

enum DeviceAppearance {
    /// Screen style, not the shelf's forced light paper. A view override must not flip the night theme.
    static var current: ColorScheme {
        #if os(iOS) || os(visionOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let style = (scenes.first?.screen ?? UIScreen.main).traitCollection.userInterfaceStyle
        return style == .dark ? .dark : .light
        #elseif os(macOS)
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? .dark : .light
        #else
        return .light
        #endif
    }
}

private struct SystemAppearanceReader<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var scheme = DeviceAppearance.current
    var content: () -> Content

    var body: some View {
        content()
            .environment(\.deviceColorScheme, scheme)
            .onAppear { scheme = DeviceAppearance.current }
            .onChange(of: scenePhase) { _, _ in scheme = DeviceAppearance.current }
    }
}
