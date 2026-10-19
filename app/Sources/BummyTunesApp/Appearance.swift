import BummyTunesCore
import Observation
import SwiftUI

/// Theming.
///
/// Only the ground changes. Blocks stay black, outlines and type stay white, so
/// contrast is guaranteed whatever the ground becomes and no preset can make the
/// app unreadable. That is why this is a small object rather than a full palette.
@Observable
@MainActor
public final class Appearance {

    public struct Preset: Identifiable, Hashable {
        public let id: String
        public let name: String
        public let hex: UInt32
        public var color: Color { Color(hex: hex) }
    }

    public static let presets: [Preset] = [
        .init(id: "violet",  name: "Electric Violet", hex: 0x5B10C4),
        .init(id: "crimson", name: "Persona Red",     hex: 0xC4101B),
        .init(id: "abyss",   name: "Abyss Blue",      hex: 0x0D2BA8),
        .init(id: "toxic",   name: "Toxic Green",     hex: 0x0F8A2E),
        .init(id: "magenta", name: "Hot Magenta",     hex: 0xB3008F),
        .init(id: "ember",   name: "Ember Orange",    hex: 0xC2450A),
        .init(id: "teal",    name: "Deep Teal",       hex: 0x00706B),
        .init(id: "ink",     name: "Near Black",      hex: 0x17171A),
    ]

    public enum Mode: String, CaseIterable {
        case preset, custom, dynamic
        public var label: String {
            switch self {
            case .preset: return "PRESET"
            case .custom: return "CUSTOM"
            case .dynamic: return "ALBUM"
            }
        }
    }

    // MARK: - Stored choices

    public var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "appearance.mode") }
    }
    public var presetID: String {
        didSet { UserDefaults.standard.set(presetID, forKey: "appearance.preset") }
    }
    public var customHex: UInt32 {
        didSet { UserDefaults.standard.set(Int(customHex), forKey: "appearance.custom") }
    }
    /// Pulled from the current track's artwork when mode is `.dynamic`.
    public private(set) var albumColor: Color?

    public init() {
        let d = UserDefaults.standard
        mode = Mode(rawValue: d.string(forKey: "appearance.mode") ?? "") ?? .preset
        presetID = d.string(forKey: "appearance.preset") ?? "violet"
        let stored = d.integer(forKey: "appearance.custom")
        customHex = stored == 0 ? 0x5B10C4 : UInt32(stored)
    }

    // MARK: - Resolved colours

    public var ground: Color {
        switch mode {
        case .preset:
            return (Self.presets.first { $0.id == presetID } ?? Self.presets[0]).color
        case .custom:
            return Color(hex: customHex)
        case .dynamic:
            return albumColor ?? (Self.presets.first { $0.id == presetID } ?? Self.presets[0]).color
        }
    }

    public var r: Double { Double((customHex >> 16) & 0xFF) }
    public var g: Double { Double((customHex >> 8) & 0xFF) }
    public var b: Double { Double(customHex & 0xFF) }

    public func setCustom(r: Double, g: Double, b: Double) {
        customHex = (UInt32(r.rounded()) << 16) | (UInt32(g.rounded()) << 8) | UInt32(b.rounded())
    }

    /// Recolour from the playing track's artwork.
    public func adopt(from track: Track?) {
        guard mode == .dynamic else { return }
        guard let track, let image = Artwork.cached(for: track) else { albumColor = nil; return }
        albumColor = DominantColor.extract(from: image).map { Color(hex: $0) }
    }
}

/// Pulls a usable ground colour out of cover art.
///
/// Not a plain average: averaging a whole cover tends toward mud, because light
/// and dark regions cancel. This bins pixels by hue, takes the most populated
/// bin, then forces the result into a range that still reads as a ground with
/// white type on it: deep enough for contrast, saturated enough to be a colour.
enum DominantColor {

    static func extract(from image: PlatformImage) -> UInt32? {
        guard let cg = cgImage(from: image) else { return nil }

        // Downsample hard; 32x32 is plenty to find a dominant hue.
        let side = 32
        let bytesPerRow = side * 4
        var buf = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &buf, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

        // 24 hue bins, weighted by saturation so greys barely vote.
        var bins = [Double](repeating: 0, count: 24)
        var binR = [Double](repeating: 0, count: 24)
        var binG = [Double](repeating: 0, count: 24)
        var binB = [Double](repeating: 0, count: 24)

        for i in stride(from: 0, to: buf.count, by: 4) {
            let r = Double(buf[i]) / 255, g = Double(buf[i+1]) / 255, b = Double(buf[i+2]) / 255
            let mx = max(r, g, b), mn = min(r, g, b)
            let delta = mx - mn
            let sat = mx <= 0 ? 0 : delta / mx
            guard sat > 0.12, mx > 0.08 else { continue }   // skip greys and near-black

            var hue: Double = 0
            if delta > 0 {
                if mx == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
                else if mx == g { hue = (b - r) / delta + 2 }
                else { hue = (r - g) / delta + 4 }
                hue *= 60
                if hue < 0 { hue += 360 }
            }
            let bin = min(23, Int(hue / 15))
            let w = sat * mx                                 // vivid pixels count more
            bins[bin] += w; binR[bin] += r * w; binG[bin] += g * w; binB[bin] += b * w
        }

        guard let best = bins.indices.max(by: { bins[$0] < bins[$1] }), bins[best] > 0 else {
            return nil
        }
        let w = bins[best]
        return groundify(r: binR[best] / w, g: binG[best] / w, b: binB[best] / w)
    }

    /// Force a colour into the band that works as a ground under white type.
    private static func groundify(r: Double, g: Double, b: Double) -> UInt32 {
        let mx = max(r, g, b), mn = min(r, g, b)
        var h = 0.0
        let delta = mx - mn
        if delta > 0 {
            if mx == r { h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / delta + 2 }
            else { h = (r - g) / delta + 4 }
            h *= 60; if h < 0 { h += 360 }
        }
        // Keep the hue, pin saturation high and brightness into a readable band.
        let s = 0.86
        let v = 0.62
        let c = v * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        var rr = 0.0, gg = 0.0, bb = 0.0
        switch Int(h / 60) {
        case 0: (rr, gg, bb) = (c, x, 0)
        case 1: (rr, gg, bb) = (x, c, 0)
        case 2: (rr, gg, bb) = (0, c, x)
        case 3: (rr, gg, bb) = (0, x, c)
        case 4: (rr, gg, bb) = (x, 0, c)
        default: (rr, gg, bb) = (c, 0, x)
        }
        let R = UInt32(((rr + m) * 255).rounded())
        let G = UInt32(((gg + m) * 255).rounded())
        let B = UInt32(((bb + m) * 255).rounded())
        return (R << 16) | (G << 8) | B
    }

    private static func cgImage(from image: PlatformImage) -> CGImage? {
        #if canImport(UIKit)
        return image.cgImage
        #else
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #endif
    }
}

/// Plain user preferences, backed by UserDefaults.
///
/// Separate from `Appearance` because these change behaviour rather than looks,
/// and separate from the library store because losing them costs nothing.
@Observable
@MainActor
public final class Prefs {
    public var gapless: Bool {
        didSet { UserDefaults.standard.set(gapless, forKey: "prefs.gapless") }
    }
    public var resumeOnLaunch: Bool {
        didSet { UserDefaults.standard.set(resumeOnLaunch, forKey: "prefs.resume") }
    }
    /// How many tracks a new radio queues up.
    public var radioLength: Int {
        didSet { UserDefaults.standard.set(radioLength, forKey: "prefs.radioLength") }
    }
    /// Cap on tracks from any single album in a radio, so it does not just
    /// replay the album you seeded from.
    public var maxPerAlbum: Int {
        didSet { UserDefaults.standard.set(maxPerAlbum, forKey: "prefs.maxPerAlbum") }
    }

    public init() {
        let d = UserDefaults.standard
        gapless = d.object(forKey: "prefs.gapless") as? Bool ?? true
        resumeOnLaunch = d.object(forKey: "prefs.resume") as? Bool ?? true
        radioLength = d.object(forKey: "prefs.radioLength") as? Int ?? 60
        maxPerAlbum = d.object(forKey: "prefs.maxPerAlbum") as? Int ?? 3
    }
}
