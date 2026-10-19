import SwiftUI

// Cross-platform shims so the same view code builds for iOS and macOS (R1.2).
// The macOS build is also how the UI gets looked at at all, since there is no
// simulator here: the views render in a real window and can be screenshotted.

#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#else
import AppKit
public typealias PlatformImage = NSImage
#endif

public extension Image {
    /// `Image(uiImage:)` on iOS, `Image(nsImage:)` on macOS.
    init(platform image: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: image)
        #else
        self.init(nsImage: image)
        #endif
    }
}

public extension View {
    /// `.navigationBarTitleDisplayMode(.inline)` exists only on iOS.
    @ViewBuilder func inlineTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Tab bars are iOS-shaped; on macOS the same content sits in a plain stack.
    @ViewBuilder func iOSOnlyTabItem<L: View>(@ViewBuilder _ label: () -> L) -> some View {
        #if os(iOS)
        self.tabItem(label)
        #else
        self
        #endif
    }
}

#if os(macOS)
public extension NSImage {
    /// NSImage has no `.size` in points the way UIImage does for artwork sizing.
    var pixelSize: CGSize {
        guard let r = representations.first else { return size }
        return CGSize(width: r.pixelsWide, height: r.pixelsHigh)
    }
}
#endif

public extension ToolbarItemPlacement {
    /// `.topBarLeading` / `.topBarTrailing` are iOS-only names for what macOS
    /// calls navigation and primary action placement.
    static var leadingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }
    static var trailingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}

public extension View {
    /// The queue list is always reorderable. `editMode` is iOS-only; on macOS
    /// rows drag without it.
    @ViewBuilder func alwaysEditable() -> some View {
        #if os(iOS)
        self.environment(\.editMode, .constant(.active))
        #else
        self
        #endif
    }
}

public extension View {
    /// `.toolbarBackground(_:for: .navigationBar)` names an iOS-only bar.
    @ViewBuilder func barBackground(_ color: Color) -> some View {
        #if os(iOS)
        self.toolbarBackground(color, for: .navigationBar)
        #else
        self
        #endif
    }
}

/// Every button in this app draws its own shape, so the platform's default
/// background must be suppressed. Without this, macOS and iOS both paint a
/// rounded rect behind the slashed shape and it bleeds out at the corners.
public struct BareButton: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

public extension View {
    func bare() -> some View { buttonStyle(BareButton()) }
}

public extension View {
    /// `.toolbar(.hidden, for: .navigationBar)` names an iOS-only bar. These
    /// screens draw their own headers, so the system bar is suppressed on iOS
    /// and simply absent on macOS.
    @ViewBuilder func hideNavBar() -> some View {
        #if os(iOS)
        self.toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }
}

public extension Int {
    /// Grouped with the locale's thousands separator. Big counts are the hero
    /// of several screens, and "1008" reads as an id rather than a quantity.
    var grouped: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}

public extension PlatformImage {
    /// Downscaled JPEG, for the on-disk artwork cache.
    ///
    /// Covers are frequently 1500px or larger and there is no point keeping
    /// that on disk to draw a 60pt row, so this bounds the long edge and
    /// re-encodes. Returns nil rather than a full-size image if anything fails.
    func cacheJPEG(maxEdge: CGFloat = 512, quality: CGFloat = 0.82) -> Data? {
        #if canImport(UIKit)
        let w = size.width, h = size.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(1, maxEdge / max(w, h))
        let target = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        let small = UIGraphicsImageRenderer(size: target, format: fmt).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return small.jpegData(compressionQuality: quality)
        #else
        let px = pixelSize
        guard px.width > 0, px.height > 0 else { return nil }
        let scale = min(1, maxEdge / max(px.width, px.height))
        let target = CGSize(width: (px.width * scale).rounded(),
                            height: (px.height * scale).rounded())
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(target.width),
            pixelsHigh: Int(target.height), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: CGRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg,
                                  properties: [.compressionFactor: quality])
        #endif
    }
}

public extension View {
    /// Give the tab bar the app's own colour, on every screen.
    ///
    /// Left alone, iOS swaps in a blurred material behind the bar as soon as
    /// content scrolls under it, so the long screens went grey behind their
    /// icons while the short ones stayed clear. Hiding the background instead
    /// made every screen consistent but let list rows scroll through the icons.
    /// A solid colour taken from the ground does both: same on every tab, and
    /// nothing shows through it.
    @ViewBuilder func solidTabBar(_ color: Color) -> some View {
        #if os(iOS)
        self.toolbarBackground(color, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
        #else
        self
        #endif
    }
}

public extension View {
    /// `.statusBarHidden` is iOS-only. Cover Flow fills the screen.
    @ViewBuilder func statusHidden() -> some View {
        #if os(iOS)
        self.statusBarHidden(true)
        #else
        self
        #endif
    }
}

public extension View {
    /// `.fullScreenCover` is iOS-only; macOS gets a sheet, which is the
    /// closest thing it has.
    @ViewBuilder func fullScreen<C: View>(isPresented: Binding<Bool>,
                                          @ViewBuilder content: @escaping () -> C) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, content: content)
        #else
        self.sheet(isPresented: isPresented, content: content)
        #endif
    }
}
