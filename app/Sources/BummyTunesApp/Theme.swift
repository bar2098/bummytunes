import AVFoundation
import BummyTunesCore
import SwiftUI

/// Visual language (R10): Persona 5, taken from the real thing.
///
/// Studied against the game's Confidant and Command menus and against Chris
/// Horner's Persona IM. The grammar is narrow and strict:
///
///   * **Red is the ground.** Not an accent on black — the whole screen is red.
///   * **Content is a black block with a thick white outline.** That outline is
///     the signature; nothing sits on the ground without one.
///   * **Blocks are irregular quads.** Each corner is nudged a different way,
///     so no two blocks are the same rectangle and nothing looks extruded.
///   * **Type is white, heavy, tight**, inside the black. Red never carries
///     body text.
///   * **Flat bright colour appears only inside framed art**, one hue per item,
///     and never touches the chrome.
///
/// Getting this wrong the obvious way (black ground, red accent) produces a
/// generic dark app, which is exactly what the first two passes were.
public enum Ink {
    public static let blood   = Color(hex: 0x5B10C4)   // the ground, electric purple
    public static let bloodLo = Color(hex: 0x33066F)   // shaded ground
    public static let bloodHi = Color(hex: 0x7A22EE)   // lit ground
    public static let black   = Color(hex: 0x0B0B0C)   // block fill
    public static let coal    = Color(hex: 0x161618)
    public static let ash     = Color(hex: 0x2A2A2E)
    public static let bone    = Color(hex: 0xFFFFFF)   // outline and type
    public static let smoke   = Color(hex: 0xA8A8AE)   // secondary type

    /// Flat accent for framed art. Straight from the game's avatar frames.
    /// Stable across launches, unlike `hashValue`, which is seeded per process
    /// and so gave the same album a different placeholder colour and a
    /// different lean every time the app started.
    public static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }

    public static func tint(for seed: String) -> Color {
        let flats: [Color] = [Color(hex: 0x3AC8F0),   // cyan
                              Color(hex: 0xF5E63B),   // yellow
                              Color(hex: 0xFF7BC3),   // pink
                              Color(hex: 0x6BE37A),   // green
                              Color(hex: 0xFF9E3D),   // orange
                              Color(hex: 0xB98BFF)]   // violet
        return flats[Int(stableHash(seed) % UInt64(flats.count))]
    }

    public static func lean(_ seed: String, max: Double = 1.6) -> Double {
        let h = Int(stableHash(seed) % 1000)
        return (Double(h) / 500.0 - 1.0) * max
    }
}

public extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

// MARK: - Type

public enum Face {
    public static func display(_ size: CGFloat, _ weight: Font.Weight = .black) -> Font {
        .system(size: size, weight: weight, design: .default).width(.compressed)
    }
    public static func body(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight)
    }
    public static func mono(_ size: CGFloat, _ weight: Font.Weight = .black) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - The block shape

/// A rectangle whose corners are each nudged a different way. This is the shape
/// every piece of content sits in. Deterministic per `seed`, so a given row
/// always has the same silhouette and the list does not shimmer while scrolling.
public struct Quad: Shape {
    public var seed: Int
    public var skew: CGFloat        // horizontal lean, like the game's blocks
    public var jitter: CGFloat      // per-corner irregularity

    public init(seed: Int = 0, skew: CGFloat = 9, jitter: CGFloat = 4) {
        self.seed = seed; self.skew = skew; self.jitter = jitter
    }

    private func n(_ i: Int) -> CGFloat {
        let x = sin(Double(seed &* 7919 &+ i &* 104729)) * 43758.5453
        return CGFloat((x - x.rounded(.down)) - 0.5) * 2   // -1...1
    }

    public func path(in r: CGRect) -> Path {
        let j = jitter
        var p = Path()
        p.move(to:    CGPoint(x: r.minX + skew + n(0) * j, y: r.minY + n(1) * j))
        p.addLine(to: CGPoint(x: r.maxX + n(2) * j,        y: r.minY + n(3) * j))
        p.addLine(to: CGPoint(x: r.maxX - skew + n(4) * j, y: r.maxY + n(5) * j))
        p.addLine(to: CGPoint(x: r.minX + n(6) * j,        y: r.maxY + n(7) * j))
        p.closeSubpath()
        return p
    }
}

/// The signature treatment: black fill, heavy white outline, irregular quad.
public struct Block: ViewModifier {
    var seed: String
    var skew: CGFloat
    var stroke: CGFloat
    var fill: Color

    public func body(content: Content) -> some View {
        // Stable across launches. With `hashValue` every block in the app
        // took a different shape each time it was opened, so the layout
        // quietly reshuffled itself between runs.
        let s = Int(Ink.stableHash(seed) % 997)
        let shape = Quad(seed: s, skew: skew, jitter: 3.5)
        content
            .background(fill, in: shape)
            .overlay(shape.stroke(Ink.bone, lineWidth: stroke))
            .rotationEffect(.degrees(Ink.lean(seed, max: 0.7)))
    }
}

public extension View {
    /// Wrap content in a black block with a white outline.
    func block(_ seed: String, skew: CGFloat = 9,
               stroke: CGFloat = 2.5, fill: Color = Ink.black) -> some View {
        modifier(Block(seed: seed, skew: skew, stroke: stroke, fill: fill))
    }

    /// White type with a hard black outline, for text sitting directly on red.
    func outlineType(_ w: CGFloat = 2, color: Color = Ink.black) -> some View {
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                let a = Double(i) / 8 * 2 * .pi
                self.foregroundStyle(color)
                    .offset(x: CGFloat(cos(a)) * w, y: CGFloat(sin(a)) * w)
            }
            self
        }
    }

    func riseIn(_ index: Int) -> some View { modifier(RiseIn(index: index)) }
}

/// Blocks snap in from the side and settle, rather than fading.
struct RiseIn: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    /// Only the opening screenful is animated in.
    ///
    /// Rows start invisible and become visible in `onAppear`, so anything that
    /// stops that from running leaves a blank hole in the list where the rows
    /// should be. Deeper rows are drawn straight away, which removes the hole
    /// for every row past the first screen and skips work besides: the effect
    /// was only ever meant for the ones you see when a screen opens.
    private var animates: Bool { index < 10 && !reduceMotion }

    func body(content: Content) -> some View {
        let hidden = animates && !shown
        content
            .opacity(hidden ? 0 : 1)
            .offset(x: hidden ? -34 : 0)
            .rotationEffect(.degrees(hidden ? -2.2 : 0))
            .onAppear {
                guard animates else { return }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.7)
                    .delay(Double(min(index, 10)) * 0.026)) { shown = true }
            }
            // A floor under the animation. If the entrance never lands, for
            // whatever reason, the row is still invisible and holding its
            // space, which is the blank hole that keeps appearing in lists.
            // After half a second it becomes visible no matter what.
            .task {
                guard animates else { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
                if !shown { shown = true }
            }
    }
}

// MARK: - Marks

/// Small label: black block, white outline, white type. The game's rank tags.
///
/// Truncates rather than growing. `fixedSize()` here was a real bug: a long
/// album name like "Barton Hall (Cornell University) - Ithaca, NY (HD)" made
/// the block wider than the screen and shoved everything beside it off both
/// edges. Labels take the width they are given and cut the text instead.
public struct Eyebrow: View {
    let text: String
    var fill: Color = Ink.black
    var maxWidth: CGFloat = 300
    public init(_ text: String, color: Color = Ink.black, maxWidth: CGFloat = 300) {
        self.text = text; self.fill = color; self.maxWidth = maxWidth
    }
    public var body: some View {
        Text(text.uppercased())
            .font(Face.mono(9.5, .black)).tracking(1.8)
            .foregroundStyle(Ink.bone)
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .block(text, skew: 5, stroke: 2, fill: fill)
            .frame(maxWidth: maxWidth, alignment: .leading)
    }
}

/// The ground. Every screen sits on this.
///
/// Untextured on purpose: the blocks and their outlines carry the identity, and
/// ornament behind them only competed for attention. The hue comes from
/// `Appearance`, so a preset, a custom colour or the current album art can drive
/// it. Blocks stay black and type stays white whatever happens here, which is
/// what keeps every option readable.
public struct Ground: View {
    @Environment(Appearance.self) private var appearance
    public init(petals: Bool = false) {}
    public var body: some View {
        let base = appearance.ground
        // No cross-fade. The tab bar takes its colour from the same source but
        // is drawn by UIKit, which will not animate alongside this, so fading
        // here made the bar visibly lag the rest of the screen on every track
        // change. Switching everything at once is the only way they agree.
        LinearGradient(colors: [base.shaded(0.62), base, base.shaded(0.78)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}

public extension Color {
    /// Multiply toward black, for the ground gradient.
    func shaded(_ f: Double) -> Color {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        let n = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let r = n.redComponent, g = n.greenComponent, b = n.blueComponent, a = n.alphaComponent
        #endif
        return Color(.sRGB, red: Double(r) * f, green: Double(g) * f,
                     blue: Double(b) * f, opacity: Double(a))
    }
}

/// Thin black zigzag, the ribbon the game runs behind its message lists.
/// A stroked path, not a filled wedge: filled, it reads as a stray black shape.
public struct Spine: View {
    var steps: Int = 7
    var width: CGFloat = 14
    public init(steps: Int = 7, width: CGFloat = 14) {
        self.steps = steps; self.width = width
    }
    public var body: some View {
        Canvas { ctx, size in
            var p = Path()
            let w = size.width, h = size.height
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let x = (i % 2 == 0) ? w * 0.22 : w * 0.78
                let pt = CGPoint(x: x, y: h * t)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .color(Ink.black),
                       style: StrokeStyle(lineWidth: width, lineJoin: .miter))
        }
        .allowsHitTesting(false)
    }
}

/// Scrub bar in the app's own language: a black track with a white outline and
/// a white block thumb. The system slider is the last stock element left.
public struct ScrubBar: View {
    @Binding var value: Double
    var total: Double
    var onCommit: (Double) -> Void
    @State private var dragging: Double?
    private static let space = "bummy.scrub"

    public init(value: Binding<Double>, total: Double,
                onCommit: @escaping (Double) -> Void) {
        self._value = value; self.total = total; self.onCommit = onCommit
    }

    public var body: some View {
        GeometryReader { g in
            let frac = total > 0 ? min(max((dragging ?? value) / total, 0), 1) : 0
            let w = g.size.width
            ZStack(alignment: .leading) {
                Rectangle().fill(Ink.black)
                    .overlay(Rectangle().stroke(Ink.bone, lineWidth: 2))
                    .frame(height: 16)
                Rectangle().fill(Ink.bone)
                    .padding(3)
                    .frame(width: max(w * frac, 0), height: 16)
                // Only the thumb scrubs.
                //
                // The gesture used to sit on the whole bar, so touching the
                // progress line anywhere jumped the track to that point. It is
                // on the handle now, with a grab area far larger than the
                // handle itself so it stays easy to catch.
                Rectangle().fill(Ink.bone)
                    .overlay(Rectangle().stroke(Ink.black, lineWidth: 2))
                    .frame(width: 12, height: 28)
                    .scaleEffect(dragging == nil ? 1 : 1.3)
                    .animation(.easeOut(duration: 0.12), value: dragging == nil)
                    .contentShape(Rectangle().inset(by: -18))
                    .offset(x: max(min(w * frac - 6, w - 12), 0))
                    .gesture(
                        DragGesture(minimumDistance: 0,
                                    coordinateSpace: .named(ScrubBar.space))
                            .onChanged { v in
                                dragging = min(max(Double(v.location.x / max(w, 1)), 0), 1)
                                    * total
                            }
                            .onEnded { _ in
                                if let d = dragging { onCommit(d) }
                                dragging = nil
                            })
            }
            .coordinateSpace(name: ScrubBar.space)
        }
        // Tall enough for the thumb. An 18pt frame clipped it and let the
        // time labels below collide with the bar.
        .frame(height: 30)
    }
}

// MARK: - Artwork

/// Artwork lookup, off the main actor.
///
/// AVFoundation's `commonMetadata` misses a lot: FLAC keeps art in a
/// METADATA_BLOCK_PICTURE it does not surface, and many MP3s keep it in a
/// format-specific APIC frame. So this tries common metadata, then raw format
/// metadata, then a cover file sitting beside the audio, which is how most
/// ripped libraries actually carry their art.
enum ArtworkLoader {
    /// Ranked front-cover names, best first. Measured against a 1,458-artist
    /// library: cover.jpg dominates, then folder.jpg, then front.jpg.
    static let coverNames = ["cover", "folder", "front", "albumart",
                             "albumartsmall", "album", "artwork", "thumb"]
    static let coverExts = ["jpg", "jpeg", "png", "webp"]

    /// Images that are emphatically not the front cover.
    ///
    /// The same library carries 175 back.jpg, hundreds of booklet scans, and
    /// disc art. A naive "any image in the folder" fallback happily picks a
    /// booklet page or the back of the sleeve, which looks like a bug to
    /// everyone but the code.
    static let notCover = ["back", "booklet", "disc", "discart", "cd",
                           "inside", "inlay", "tray", "matrix", "obi",
                           "spine", "sticker", "scan", "wm", "thumb-"]

    /// Reject words unambiguous enough to look for anywhere in the name.
    /// "cd" and "wm" stay out of this list: they are two letters and turn up
    /// inside innocent words.
    static let notCoverAnywhere = ["back", "booklet", "inlay", "obi", "spine",
                                   "sticker", "tray", "matrix", "inside",
                                   "discart"]

    static func isLikelyCover(_ lowercasedName: String) -> Bool {
        let stem = (lowercasedName as NSString).deletingPathExtension
        if notCover.contains(where: { stem == $0 || stem.hasPrefix($0) }) { return false }
        return !notCoverAnywhere.contains { stem.contains($0) }
    }

    /// A cover word anywhere in the name, e.g.
    /// "herbie mann [brazil blues] front cover.jpg". Measured against a real
    /// 10,943-album library, plain name matching already resolves 99.7% of
    /// folders; this and the single-image rule below take it to all of them.
    static func namesACover(_ lowercasedName: String) -> Bool {
        guard isLikelyCover(lowercasedName) else { return false }
        let stem = (lowercasedName as NSString).deletingPathExtension
        return ["cover", "front", "albumart", "artwork", "folder"]
            .contains { stem.contains($0) }
    }

    /// FLAC cover art, parsed by hand.
    ///
    /// AVFoundation does not surface METADATA_BLOCK_PICTURE, so on a FLAC
    /// library its metadata APIs return no artwork at all however you ask. The
    /// container is simple enough to walk directly: "fLaC", then a chain of
    /// blocks, each a 1-byte header (top bit = last block, low 7 = type) and a
    /// 3-byte big-endian length. Type 6 is a picture.
    static func flacPicture(at url: URL) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let magic = try? h.read(upToCount: 4), magic == Data("fLaC".utf8) else {
            return nil
        }

        var guardCount = 0
        while guardCount < 64 {
            guardCount += 1
            guard let head = try? h.read(upToCount: 4), head.count == 4 else { return nil }
            let isLast = (head[head.startIndex] & 0x80) != 0
            let type = head[head.startIndex] & 0x7F
            let len = (Int(head[head.startIndex + 1]) << 16)
                    | (Int(head[head.startIndex + 2]) << 8)
                    |  Int(head[head.startIndex + 3])
            guard len >= 0, len < 40_000_000 else { return nil }

            if type == 6 {
                guard let block = try? h.read(upToCount: len), block.count == len else {
                    return nil
                }
                return picturePayload(block)
            }
            // Skip this block.
            let pos = (try? h.offset()) ?? 0
            try? h.seek(toOffset: pos + UInt64(len))
            if isLast { return nil }
        }
        return nil
    }

    /// Pull the image bytes out of a METADATA_BLOCK_PICTURE body.
    private static func picturePayload(_ b: Data) -> Data? {
        var i = b.startIndex
        func u32() -> Int? {
            guard i + 4 <= b.endIndex else { return nil }
            let v = (Int(b[i]) << 24) | (Int(b[i+1]) << 16) | (Int(b[i+2]) << 8) | Int(b[i+3])
            i += 4
            return v
        }
        guard u32() != nil else { return nil }                 // picture type
        guard let mimeLen = u32(), mimeLen >= 0,
              i + mimeLen <= b.endIndex else { return nil }
        i += mimeLen                                            // mime string
        guard let descLen = u32(), descLen >= 0,
              i + descLen <= b.endIndex else { return nil }
        i += descLen                                            // description
        guard u32() != nil, u32() != nil,                       // width, height
              u32() != nil, u32() != nil else { return nil }     // depth, colours
        guard let dataLen = u32(), dataLen > 0,
              i + dataLen <= b.endIndex else { return nil }
        return b.subdata(in: i..<(i + dataLen))
    }

    static func embedded(at url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        if let items = try? await asset.load(.commonMetadata) {
            for item in items where item.commonKey?.rawValue == "artwork" {
                if let d = try? await item.load(.dataValue) { return d }
            }
        }
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for f in formats {
                guard let items = try? await asset.loadMetadata(for: f) else { continue }
                for item in items {
                    let k = ((item.key as? String) ?? item.identifier?.rawValue ?? "").lowercased()
                    guard k.contains("apic") || k.contains("covr")
                            || k.contains("pic") || k.contains("artwork") else { continue }
                    if let d = try? await item.load(.dataValue) { return d }
                }
            }
        }
        return nil
    }

    /// Folders that are dumping grounds rather than album folders.
    ///
    /// A loose track sitting in Downloads has hundreds of unrelated images
    /// beside it. Treating any of them as its cover puts private photos on
    /// screen, so no folder art is read from these at all.
    static let dumpNames: Set<String> = ["downloads", "desktop", "documents",
                                         "pictures", "photos", "movies",
                                         "public", "library", "icloud drive",
                                         "on my iphone", "on my ipad"]

    static func isDumpFolder(_ dir: URL) -> Bool {
        let here = dir.standardizedFileURL.path
        if here == NSHomeDirectory() { return true }
        return dumpNames.contains(dir.lastPathComponent.lowercased())
    }

    /// A cover image file in the same folder, shared by the whole album.
    ///
    /// Only files actually named like a cover count. There is no "biggest
    /// image in the folder" fallback: it looks clever on a tidy album folder
    /// and grabs a holiday photo everywhere else.
    static func folderCover(in dir: URL) -> Data? {
        guard !isDumpFolder(dir) else { return nil }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        let pairs = entries.map { ($0, $0.lowercased()) }
            .filter { coverExts.contains(($0.1 as NSString).pathExtension) }
        guard !pairs.isEmpty else { return nil }
        // A folder carrying this many images is a pile of files, not an album.
        guard pairs.count <= 40 else { return nil }

        // 1: an exact known cover name, in preference order.
        for name in coverNames {
            for ext in coverExts {
                if let hit = pairs.first(where: { $0.1 == "\(name).\(ext)" }),
                   let d = try? Data(contentsOf: dir.appendingPathComponent(hit.0)) {
                    return d
                }
            }
        }
        // 2: a name that merely starts with one, e.g. "cover (1).jpg".
        for name in coverNames {
            if let hit = pairs.first(where: { $0.1.hasPrefix(name) && isLikelyCover($0.1) }),
               let d = try? Data(contentsOf: dir.appendingPathComponent(hit.0)) {
                return d
            }
        }
        // 3: a cover word anywhere in the name.
        if let hit = pairs.first(where: { namesACover($0.1) }),
           let d = try? Data(contentsOf: dir.appendingPathComponent(hit.0)) {
            return d
        }
        // 4: the folder holds exactly one image and it is not a back cover or
        //    a booklet page. An album folder named after the record often
        //    carries its art as "Artist - Album.jpg". A folder full of loose
        //    files never has exactly one image, which is what keeps this from
        //    reaching for unrelated photos.
        if pairs.count == 1, isLikelyCover(pairs[0].1),
           let d = try? Data(contentsOf: dir.appendingPathComponent(pairs[0].0)) {
            return d
        }
        return nil
    }
}

/// The on-disk artwork cache.
///
/// Without it every launch re-reads and re-decodes art out of the audio files,
/// so covers fade in again each time the app starts. Decoded covers are written
/// once, downscaled, and read back instantly afterwards. They live in Caches so
/// the system can reclaim the space, and they are keyed by path so a moved
/// library simply re-warms itself.
///
/// Deliberately not main-actor isolated: reads and writes belong off the main
/// thread, and only `Data` crosses the boundary.
enum ArtworkDisk {
    static let dir: URL? = {
        let fm = FileManager.default
        guard let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let d = base.appendingPathComponent("artwork", isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// FNV-1a. Swift's own `hashValue` is seeded per process, so it cannot name
    /// a file that has to be found again after a relaunch.
    static func name(_ key: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 16) + ".jpg"
    }

    static func url(_ key: String) -> URL? { dir?.appendingPathComponent(name(key)) }

    static func read(_ key: String) -> Data? {
        guard let u = url(key) else { return nil }
        return try? Data(contentsOf: u)
    }

    /// Is this cover already cached? Cheaper than reading and decoding it,
    /// which is what the background warm pass needs to know.
    static func has(_ key: String) -> Bool {
        guard let u = url(key) else { return false }
        return FileManager.default.fileExists(atPath: u.path)
    }

    static func write(_ data: Data, _ key: String) {
        guard let u = url(key) else { return }
        try? data.write(to: u, options: .atomic)
    }

    static func size() -> Int64 {
        guard let dir, let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(into: Int64(0)) { total, u in
            total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    static func clear() {
        guard let dir else { return }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

@MainActor
public final class Artwork {
    // Bounded on purpose. Decoded covers are a few megabytes each, and the
    // background warm pass walks the whole library, so an unbounded cache would
    // sit on hundreds of megabytes before the system asked for any of it back.
    private static let cache: NSCache<NSString, PlatformImage> = {
        let c = NSCache<NSString, PlatformImage>()
        c.countLimit = 120
        c.totalCostLimit = 28 * 1024 * 1024
        return c
    }()
    /// Folder covers are shared by every track in an album, so they cache by
    /// directory rather than by file.
    private static let folderCache: NSCache<NSString, PlatformImage> = {
        let c = NSCache<NSString, PlatformImage>()
        c.countLimit = 120
        c.totalCostLimit = 28 * 1024 * 1024
        return c
    }()

    /// Rough decoded size, used as the cache cost.
    private static func cost(_ image: PlatformImage) -> Int {
        #if canImport(UIKit)
        let px = image.size
        return Int(px.width * px.height * 4 * image.scale * image.scale)
        #else
        let px = image.pixelSize
        return Int(px.width * px.height * 4)
        #endif
    }
    private static var missingFolders: Set<String> = []
    /// Lookups in progress, by track path.
    ///
    /// Held as tasks rather than as a set of keys. When two callers asked for
    /// the same cover at once, the second used to get nil back, and a row that
    /// receives nil keeps its placeholder until it is rebuilt. The background
    /// warm pass made that collision constant, which is why covers went
    /// missing at random. Now the second caller waits on the first.
    private static var inFlight: [String: Task<FoundArt?, Never>] = [:]

    /// Forget which folders had no cover.
    ///
    /// A folder read that happens before the library's security scope is open
    /// comes back empty, and without this that folder would be written off for
    /// the rest of the session.
    public static func forgetMisses() {
        missingFolders.removeAll()
    }

    /// Folder key must be the *resolved* directory, the same one `load` stores
    /// under. Using the stored path here meant a "@docs/..." relative path never
    /// matched the absolute path written by the loader, so the folder cache
    /// never hit and every row rescanned the directory.
    private static func folderKey(for track: Track) -> String {
        track.url.deletingLastPathComponent().path
    }

    public static func cached(for track: Track) -> PlatformImage? {
        if let hit = cache.object(forKey: track.path as NSString) { return hit }
        return folderCache.object(forKey: folderKey(for: track) as NSString)
    }

    @discardableResult
    /// One track's cover, decoded off the main thread.
    ///
    /// Everything expensive happens inside a single detached task: reading the
    /// file, decoding the image, and downscaling it for the disk cache. Doing
    /// any of that here would put a JPEG decode and re-encode on the main actor
    /// for every track the background warm pass walks, which is exactly the
    /// kind of work that makes a list stutter.
    public static func load(for track: Track) async -> PlatformImage? {
        if let hit = cached(for: track) { return hit }
        let key = track.path
        let url = track.url
        let dir = url.deletingLastPathComponent()
        let dirKey = dir.path
        if let hit = folderCache.object(forKey: dirKey as NSString) { return hit }

        // Join the lookup already running for this track, or start one.
        let task: Task<FoundArt?, Never>
        if let existing = inFlight[key] {
            task = existing
        } else {
            let folderKnownEmpty = missingFolders.contains(dirKey)
            let bookmark = track.bookmark
            task = Task.detached(priority: .utility) { () -> FoundArt? in
                // 1. Disk: a cover seen in a previous session, already downscaled.
                if let d = ArtworkDisk.read(key), let img = PlatformImage(data: d) {
                    return FoundArt(image: img, scope: .track, encoded: nil)
                }
                if let d = ArtworkDisk.read(dirKey), let img = PlatformImage(data: d) {
                    return FoundArt(image: img, scope: .folder, encoded: nil)
                }

                // 2. Inside the file. FLAC is parsed by hand because
                //    AVFoundation does not surface its picture block at all.
                var embedded: Data?
                if url.pathExtension.lowercased() == "flac" {
                    embedded = ArtworkLoader.flacPicture(at: url)
                } else {
                    embedded = await ArtworkLoader.embedded(at: url)
                }
                if let d = embedded, let img = PlatformImage(data: d) {
                    return FoundArt(image: img, scope: .track, encoded: img.cacheJPEG())
                }

                // 3. A cover file beside it. Listing a picked folder needs its
                //    security scope open, which is why the bookmark comes along.
                guard !folderKnownEmpty else { return nil }
                var scoped: URL?
                if let data = bookmark {
                    var stale = false
                    if let u = try? URL(resolvingBookmarkData: data, options: [],
                                        relativeTo: nil, bookmarkDataIsStale: &stale) {
                        let target = u.hasDirectoryPath ? u : u.deletingLastPathComponent()
                        if target.startAccessingSecurityScopedResource() { scoped = target }
                    }
                }
                defer { scoped?.stopAccessingSecurityScopedResource() }
                if let d = ArtworkLoader.folderCover(in: dir), let img = PlatformImage(data: d) {
                    return FoundArt(image: img, scope: .folder, encoded: img.cacheJPEG())
                }
                return nil
            }
            inFlight[key] = task
        }

        let found = await task.value
        inFlight[key] = nil

        guard let found else {
            missingFolders.insert(dirKey)
            return nil
        }

        switch found.scope {
        case .track:
            cache.setObject(found.image, forKey: key as NSString, cost: cost(found.image))
        case .folder:
            folderCache.setObject(found.image, forKey: dirKey as NSString,
                                  cost: cost(found.image))
        }
        if let small = found.encoded {
            let diskKey = found.scope == .track ? key : dirKey
            Task.detached(priority: .background) { ArtworkDisk.write(small, diskKey) }
        }
        return found.image
    }

    /// Result of one lookup. `PlatformImage` is immutable here and never
    /// touched from two places at once, so crossing the boundary is safe.
    private struct FoundArt: @unchecked Sendable {
        enum Scope { case track, folder }
        let image: PlatformImage
        let scope: Scope
        /// Downscaled bytes to write to the disk cache, or nil if it came from
        /// there in the first place.
        let encoded: Data?
    }

    public static func image(for track: Track) -> PlatformImage? { cached(for: track) }

    /// Already on disk? Lets the warm pass skip work it has done before.
    ///
    /// Not main-actor isolated: this hits the file system, and the warm pass
    /// calls it once per track across the whole library.
    nonisolated public static func isCachedOnDisk(_ track: Track) -> Bool {
        ArtworkDisk.has(track.path)
            || ArtworkDisk.has(track.url.deletingLastPathComponent().path)
    }

    /// Why artwork is or is not appearing.
    ///
    /// Samples rather than scanning everything, and reports each source
    /// separately so "no art" stops being a mystery: embedded art absent is a
    /// different problem from cover files absent, and each has a different fix.
    public struct ArtReport: Sendable {
        public var sampled = 0
        public var embedded = 0
        public var flacEmbedded = 0
        public var folderCover = 0
        public var none = 0
        public var foldersChecked = 0
        public var foldersWithImage = 0
        public var exampleFolder = ""
        public var exampleContents = ""
    }

    public static func diagnoseArt(_ tracks: [Track], sample: Int = 24) async -> ArtReport {
        var r = ArtReport()
        guard !tracks.isEmpty else { return r }
        let step = max(1, tracks.count / sample)
        var folders = Set<String>()

        for t in stride(from: 0, to: tracks.count, by: step).prefix(sample).map({ tracks[$0] }) {
            r.sampled += 1
            let url = t.url
            let dir = url.deletingLastPathComponent()

            var got = false
            if url.pathExtension.lowercased() == "flac" {
                if ArtworkLoader.flacPicture(at: url) != nil { r.flacEmbedded += 1; got = true }
            } else if await ArtworkLoader.embedded(at: url) != nil {
                r.embedded += 1; got = true
            }

            if !got {
                if folders.insert(dir.path).inserted {
                    r.foldersChecked += 1
                    let names = (try? FileManager.default
                        .contentsOfDirectory(atPath: dir.path)) ?? []
                    let imgs = names.filter {
                        ArtworkLoader.coverExts.contains(($0 as NSString)
                            .pathExtension.lowercased())
                    }
                    if !imgs.isEmpty { r.foldersWithImage += 1 }
                    if r.exampleFolder.isEmpty {
                        r.exampleFolder = dir.lastPathComponent
                        r.exampleContents = names.isEmpty
                            ? "unreadable or empty"
                            : names.prefix(4).joined(separator: ", ")
                    }
                }
                if ArtworkLoader.folderCover(in: dir) != nil { r.folderCover += 1; got = true }
            }
            if !got { r.none += 1 }
        }
        return r
    }
}


/// A record turning behind the cover.
///
/// Drawn rather than an asset: grooves are concentric strokes, the label is the
/// ground colour, and the whole thing rotates only while audio is playing. The
/// spin is driven by a repeating animation on a single angle so it costs one
/// animatable value rather than a timer.
public struct Vinyl: View {
    var spinning: Bool
    var size: CGFloat
    var labelColor: Color
    /// The track whose cover becomes the label.
    var trackID: UUID?

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var art: Image?
    /// Where the record was left when it last stopped.
    @State private var restAngle: Double = 0
    /// When the current spin began, or nil while stopped.
    @State private var startedAt: Date?

    private let secondsPerTurn: Double = 4.0

    public init(spinning: Bool, size: CGFloat, labelColor: Color, trackID: UUID? = nil) {
        self.spinning = spinning; self.size = size
        self.labelColor = labelColor; self.trackID = trackID
    }

    /// The angle is read off the clock rather than animated.
    ///
    /// A `repeatForever` rotation is at the mercy of every other animation in
    /// the view: the spring that slides the record out of its sleeve was
    /// capturing the spin and cutting it short. Computing the angle from
    /// elapsed time cannot be interrupted by anything.
    private func angle(at date: Date) -> Double {
        guard let startedAt else { return restAngle }
        return restAngle + date.timeIntervalSince(startedAt) / secondsPerTurn * 360
    }

    private var turning: Bool { spinning && !reduceMotion }

    public var body: some View {
        TimelineView(.animation(paused: !turning)) { tick in
            face.rotationEffect(.degrees(angle(at: tick.date)))
        }
        .frame(width: size, height: size)
        .onAppear { if turning && startedAt == nil { startedAt = Date() } }
        .onChange(of: turning) { _, now in
            if now {
                startedAt = Date()
            } else {
                restAngle = angle(at: Date())        // stop where it is
                startedAt = nil
            }
        }
        .task(id: trackID) {
            guard let id = trackID, let t = app.track(id) else { art = nil; return }
            if let hit = Artwork.cached(for: t) {
                art = Image(platform: hit).resizable()
            } else if let loaded = await Artwork.load(for: t) {
                art = Image(platform: loaded).resizable()
            } else {
                art = nil
            }
        }
    }

    private var face: some View {
        Canvas { ctx, s in
            let c = CGPoint(x: s.width / 2, y: s.height / 2)
            let r = min(s.width, s.height) / 2
            func circle(_ rad: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: c.x - rad, y: c.y - rad,
                                       width: rad * 2, height: rad * 2))
            }

            ctx.fill(circle(r), with: .color(Ink.black))

            // The gaps between tracks. On a record these are rings, not
            // spokes: each one sits where a song ends, so they are unevenly
            // spaced because songs run different lengths.
            for (t, w) in [(0.95, 2.0), (0.845, 1.5), (0.755, 1.5),
                           (0.64, 1.5), (0.545, 1.5), (0.46, 2.0)] as [(CGFloat, CGFloat)] {
                ctx.stroke(circle(r * t), with: .color(.white.opacity(0.13)), lineWidth: w)
            }

            // The label is the album cover. Every vinyl player people actually
            // like does this, and it is also the thing that makes the rotation
            // readable without drawing a single extra line on the disc.
            let lr = r * 0.34
            let box = CGRect(x: c.x - lr, y: c.y - lr, width: lr * 2, height: lr * 2)
            if let art {
                ctx.drawLayer { layer in
                    layer.clip(to: circle(lr))
                    layer.draw(art, in: box)
                }
            } else {
                // No cover yet: a plain label with a band printed across one
                // side, so it still reads as turning.
                ctx.fill(circle(lr), with: .color(labelColor))
                ctx.drawLayer { layer in
                    layer.clip(to: circle(lr))
                    layer.fill(Path(CGRect(x: c.x - lr, y: c.y - lr * 0.64,
                                           width: lr * 2, height: lr * 0.40)),
                               with: .color(Ink.black))
                }
            }
            ctx.stroke(circle(lr), with: .color(Ink.bone), lineWidth: 2)

            let hr = r * 0.045
            ctx.fill(circle(hr), with: .color(Ink.black))

            ctx.stroke(circle(r * 0.99), with: .color(Ink.bone), lineWidth: 2.5)
        }
        .frame(width: size, height: size)
    }
}
