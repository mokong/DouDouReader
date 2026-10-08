import CoreGraphics
import Foundation
#if os(iOS) || os(visionOS)
import UIKit
typealias AppFont = UIFont
typealias AppColor = UIColor
#elseif os(macOS)
import AppKit
typealias AppFont = NSFont
typealias AppColor = NSColor
#endif

struct RGBA: Equatable, Sendable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    var platform: AppColor {
        #if os(iOS) || os(visionOS)
        AppColor(red: r, green: g, blue: b, alpha: a)
        #else
        AppColor(srgbRed: r, green: g, blue: b, alpha: a)
        #endif
    }
}

enum PlatformFont {
    static func make(name: String, size: CGFloat, bold: Bool = false) -> AppFont {
        let base: AppFont
        if name.isEmpty {
            base = .systemFont(ofSize: size)
        } else {
            base = AppFont(name: name, size: size) ?? .systemFont(ofSize: size)
        }
        guard bold else { return base }
        #if os(iOS) || os(visionOS)
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) else {
            return .boldSystemFont(ofSize: size)
        }
        return AppFont(descriptor: descriptor, size: size)
        #else
        let descriptor = base.fontDescriptor.withSymbolicTraits(.bold)
        return AppFont(descriptor: descriptor, size: size) ?? .boldSystemFont(ofSize: size)
        #endif
    }

    static func exists(_ name: String) -> Bool {
        AppFont(name: name, size: 12) != nil
    }
}

enum PageMetrics {
    static let headerHeight: CGFloat = 28
    static let footerHeight: CGFloat = 22
    static let headerGap: CGFloat = 8
    static let footerGap: CGFloat = 8

    static func textSize(
        bounds: CGSize,
        safeTop: CGFloat,
        safeBottom: CGFloat,
        showsHeader: Bool,
        showsFooter: Bool,
        marginX: CGFloat,
        marginTop: CGFloat,
        marginBottom: CGFloat
    ) -> CGSize {
        let top = safeTop + (showsHeader ? headerGap + headerHeight : 10) + marginTop
        let bottom = safeBottom + (showsFooter ? footerGap + footerHeight : 10) + marginBottom
        return CGSize(
            width: max(40, (bounds.width - marginX * 2).rounded()),
            height: max(40, (bounds.height - top - bottom).rounded())
        )
    }

    static func textOriginY(safeTop: CGFloat, showsHeader: Bool, marginTop: CGFloat) -> CGFloat {
        safeTop + (showsHeader ? headerGap + headerHeight : 10) + marginTop
    }

    /// Wider screens keep a single comfortable column. True two-column layout is intentionally not done here.
    static func placement(
        bounds: CGSize,
        safeTop: CGFloat,
        safeBottom: CGFloat,
        marginX: CGFloat,
        marginTop: CGFloat,
        marginBottom: CGFloat,
        showsHeader: Bool,
        showsFooter: Bool
    ) -> (textRect: CGRect, pageSize: CGSize) {
        let extra: CGFloat = bounds.width > 700 ? min(140, (bounds.width - 620) / 2) : 0
        let insetX = marginX + extra
        let pageSize = textSize(
            bounds: bounds,
            safeTop: safeTop,
            safeBottom: safeBottom,
            showsHeader: showsHeader,
            showsFooter: showsFooter,
            marginX: insetX,
            marginTop: marginTop,
            marginBottom: marginBottom
        )
        let originY = textOriginY(safeTop: safeTop, showsHeader: showsHeader, marginTop: marginTop)
        let rect = CGRect(x: insetX, y: originY, width: pageSize.width, height: pageSize.height)
        return (rect, pageSize)
    }
}

enum ScreenSafeArea {
    /// Device insets from the key window. A reader that ignores the safe area
    /// still has to keep text below the sensor housing; GeometryReader often reports 0 there.
    static var windowInsets: (top: CGFloat, bottom: CGFloat) {
        #if os(iOS) || os(visionOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.keyWindow ?? scene?.windows.first
        let raw = window?.safeAreaInsets ?? .zero
        return (raw.top, raw.bottom)
        #elseif os(macOS)
        let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first
        let raw = window?.contentView?.safeAreaInsets ?? NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        return (raw.top, raw.bottom)
        #else
        return (0, 0)
        #endif
    }
}
