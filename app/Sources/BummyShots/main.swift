import AppKit
import BummyTunesCore
import SwiftUI

// Visual test harness.
//
// Renders each screen to a PNG so the UI can be inspected on a machine with no
// simulator. Uses a real NSWindow + NSHostingView rather than ImageRenderer:
// ImageRenderer does not lay out NavigationStack contents and never fires
// onAppear, so anything gated on either renders blank.

@MainActor
final class Shooter {
    let window: NSWindow

    init(size: CGSize) {
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        // Off the visible screen but still a real, laid-out window.
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
    }

    /// Let SwiftUI settle: onAppear, async artwork loads, entrance animations.
    func pump(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    func shoot<V: View>(_ name: String, size: CGSize, _ view: V) {
        let host = NSHostingView(rootView:
            view.frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
        )
        host.frame = CGRect(origin: .zero, size: size)
        window.setContentSize(size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        pump(1.4)                       // entrance animations run ~0.4s
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("  FAIL  \(name): no bitmap rep"); return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("  FAIL  \(name): png encode failed"); return
        }
        try? data.write(to: URL(fileURLWithPath: "/tmp/shots/\(name).png"))

        // Report how much of the frame is not just background, so a blank
        // render is obvious in the log instead of needing a human to look.
        let ink = nonBackgroundFraction(rep)
        print(String(format: "  ok    %-18s %dx%d   content %.1f%%",
                     (name as NSString).utf8String!, rep.pixelsWide, rep.pixelsHigh, ink * 100))
    }

    /// Fraction of pixels differing meaningfully from the darkest colour present.
    private func nonBackgroundFraction(_ rep: NSBitmapImageRep) -> Double {
        guard let cg = rep.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return 0 }
        var counts: [UInt32: Int] = [:]
        var samples = 0
        guard let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return 0 }
        let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        for y in stride(from: 0, to: h, by: 4) {
            for x in stride(from: 0, to: w, by: 4) {
                let o = y * bpr + x * bpp
                let key = (UInt32(ptr[o]) << 16) | (UInt32(ptr[o+1]) << 8) | UInt32(ptr[o+2])
                counts[key, default: 0] += 1
                samples += 1
            }
        }
        guard samples > 0, let bg = counts.max(by: { $0.value < $1.value })?.value else { return 0 }
        return 1.0 - Double(bg) / Double(samples)
    }
}

@main
enum Shots {
    static func main() {
        let appKit = NSApplication.shared
        appKit.setActivationPolicy(.accessory)
        MainActor.assumeIsolated { run() }
    }

    @MainActor static func run() {
        let phone = CGSize(width: 393, height: 852)
        let shooter = Shooter(size: phone)

        let app = AppModel()
        let appearance = Appearance()
        print("library: \(app.tracks.count) tracks, \(app.albums.count) albums, "
              + "\(app.artists.count) artists, \(app.analysedCount) analysed\n")

        if let seed = app.tracks.first(where: {
            $0.isAnalysed && $0.meta.artist != TrackMetadata.unknownArtist
        }) {
            app.startRadio(from: seed)
            print("player seeded: \(seed.meta.title) — \(seed.meta.artist)\n")
        }

        shooter.shoot("welcome", size: phone, WelcomeView().environment(app).environment(appearance))
        shooter.shoot("library-albums", size: phone, LibraryView().environment(app).environment(appearance))
        shooter.shoot("search", size: phone, SearchView().environment(app).environment(appearance))
        shooter.shoot("map", size: phone, MapView().environment(app).environment(appearance))
        shooter.shoot("settings", size: phone, SettingsView().environment(app).environment(appearance))
        shooter.shoot("nowplaying", size: phone, NowPlayingView().environment(app).environment(appearance))
        shooter.shoot("queue", size: phone, QueueView().environment(app).environment(appearance))
        if let album = app.albums.first(where: { $0.trackIDs.count > 5 }) {
            shooter.shoot("album", size: phone, AlbumView(album: album).environment(app).environment(appearance))
        }
        if let artist = app.artists.first(where: { $0.trackIDs.count > 5 }) {
            shooter.shoot("artist", size: phone, ArtistView(artist: artist).environment(app).environment(appearance))
        }
        // The record on its own, big, so its detail can actually be judged.
        shooter.shoot("vinyl", size: CGSize(width: 360, height: 360),
                      ZStack {
                          Color(hex: 0x5B10C4)
                          Vinyl(spinning: true, size: 300,
                                labelColor: Color(hex: 0x5B10C4),
                                trackID: app.player.nowPlaying?.id)
                              .environment(app)
                      })
        // Cover Flow is checked against made-up albums rather than the real
        // library, so the harness never needs the user's own files to render.
        let land = CGSize(width: 852, height: 393)
        let fake: [Album] = [
            ("Neon Arcade", "Tokyo Static"), ("Salt Mirror", "Ora Vell"),
            ("Low Orbit Radio", "Mint Divide"), ("Paper Lanterns", "Kudzu"),
            ("Black Sand", "Hale & Wick"), ("Third Rail", "Mercury Fold"),
            ("Sunday Drift", "Ora Vell"), ("Gravel Song", "Kudzu"),
        ].map { title, artist in
            Album(title: title, artist: artist,
                  artistKey: artist.lowercased(), trackIDs: [UUID()])
        }
        shooter.shoot("coverflow", size: land,
                      CoverFlowView(albums: fake)
                          .environment(app).environment(appearance))
        shooter.shoot("miniplayer", size: CGSize(width: 393, height: 90),
                      MiniPlayer(expand: {}).environment(app).environment(appearance))

        print("\ndone -> /tmp/shots")
    }
}
