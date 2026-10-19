import BummyTunesCore
import SwiftUI

/// Cover Flow.
///
/// The iPod and early iPhone Music app did this: turn the phone sideways and
/// the list was replaced by a black screen holding the covers themselves,
/// stood up in a row like records in a crate. You flicked through them, and
/// tapping the one in the middle flipped it over to show the track list.
///
/// Rebuilt here rather than imitated loosely, so the parts that made it worth
/// using are all present: perspective on the side covers, reflections under
/// them, momentum on the flick, snapping to whole albums, and the flip.
struct CoverFlowView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let albums: [Album]
    /// Fractional position in `albums`. Whole numbers are centred covers.
    @State private var position: Double = 0
    @State private var flipped = false
    @GestureState private var dragBy: Double = 0

    /// How many covers are drawn either side of the middle. Beyond this they
    /// are edge-on and contribute nothing but cost.
    /// Nine cards on screen instead of eleven. The two furthest out are
    /// nearly edge on and cost as much to draw as the one in the middle.
    private let wing = 4

    private var index: Int {
        min(max(Int((position - dragBy).rounded()), 0), max(albums.count - 1, 0))
    }
    private var current: Album? { albums.indices.contains(index) ? albums[index] : nil }

    var body: some View {
        GeometryReader { geo in
            // Cover, reflection and caption all share the short edge of a
            // landscape phone, so everything is sized off the height.
            let side = min(geo.size.height * 0.44, geo.size.width * 0.34)
            let here = position - dragBy
            let cx = geo.size.width / 2
            let cy = geo.size.height * 0.42

            ZStack {
                Color.black.ignoresSafeArea()

                ForEach(visible(around: here), id: \.self) { i in
                    let d = Double(i) - here
                    cover(albums[i], side: side, distance: d)
                        .position(x: cx + xOffset(d, side: side), y: cy)
                        .zIndex(10 - abs(d))
                }

                caption.position(x: cx, y: geo.size.height - 34)

            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .updating($dragBy) { v, state, _ in
                        guard !flipped else { return }
                        state = v.translation.width / (side * 0.62)
                    }
                    .onEnded { v in
                        guard !flipped else { return }
                        let unit = side * 0.62
                        let travelled = v.translation.width / unit

                        // Absorb the drag with no animation first. The gesture
                        // state resets to zero the instant the finger lifts, so
                        // animating straight from the old position made the row
                        // jump back to where the drag started and then slide.
                        // That jump is the hiccup.
                        position = clamp(position - travelled)

                        // Then coast, off how fast the finger was moving rather
                        // than how far it went. The square term is the point: a
                        // flick crosses a large stretch of the collection in one
                        // go, the way spinning the wheel on an iPod did, while a
                        // gentle push still lands on the next cover along.
                        let speed = v.velocity.width / unit          // covers a second
                        let carry = speed * 0.42 + speed * abs(speed) * 0.008
                        let far = abs(carry) > 6
                        withAnimation(.interpolatingSpring(mass: far ? 2.2 : 1.2,
                                                           stiffness: far ? 34 : 88,
                                                           damping: far ? 13 : 17)) {
                            position = clamp((position - carry).rounded())
                        }
                    }
            )
        }
        .background(Color.black.ignoresSafeArea())
        .statusHidden()
        .onAppear { position = clamp(Double(startIndex)) }
    }

    // MARK: - Pieces

    private func visible(around here: Double) -> [Int] {
        let mid = Int(here.rounded())
        return (mid - wing...mid + wing).filter { albums.indices.contains($0) }
    }

    /// How far from the middle a cover sits. The first step out is wide and the
    /// rest compress, so the row reads as receding depth rather than a strip.
    private func xOffset(_ d: Double, side: CGFloat) -> CGFloat {
        let mag = min(abs(d), Double(wing))
        guard mag > 0 else { return 0 }
        let dir: CGFloat = d < 0 ? -1 : 1
        return dir * side * CGFloat(0.62 + (mag - 1) * 0.24)
    }

    private func cover(_ album: Album, side: CGFloat, distance d: Double) -> some View {
        let mag = min(abs(d), Double(wing))
        let lean = min(mag, 1)
        let angle = (d < 0 ? 1.0 : -1.0) * lean * 64.0
        let dim = lean * 0.45
        let isCentre = abs(d) < 0.5
        // Turning the card over is a half turn of the whole card. The back face
        // carries its own half turn below, so the two cancel and the track list
        // reads the right way round.
        let flip = (isCentre && flipped) ? 180.0 : 0.0

        return FlowCard(trackID: album.trackIDs.first, seed: album.id,
                        side: side, dim: dim,
                        showingBack: isCentre && flipped) {
            trackList(album, side: side)
        }
        .scaleEffect(1 - lean * 0.1)
        .rotation3DEffect(.degrees(angle + flip), axis: (x: 0, y: 1, z: 0),
                          anchor: .center, perspective: 0.2)
        .onTapGesture {
            if isCentre {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
                    flipped.toggle()
                }
            } else {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                    position = clamp(Double(albums.firstIndex(of: album) ?? index))
                    flipped = false
                }
            }
        }
    }

    /// The back of the sleeve: what the original flipped to.
    private func trackList(_ album: Album, side: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(album.title)
                .font(Face.display(15, .black))
                .foregroundStyle(Ink.black)
                .lineLimit(1)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Ink.bone)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(album.trackIDs.enumerated()), id: \.element) { i, id in
                        if let t = app.track(id) {
                            Button {
                                app.playAlbum(album, startingAt: id)
                            } label: {
                                HStack(spacing: 7) {
                                    Text("\(t.meta.trackNumber ?? i + 1)")
                                        .font(Face.mono(9))
                                        .foregroundStyle(Ink.smoke)
                                        .frame(width: 16, alignment: .trailing)
                                    Text(t.meta.title)
                                        .font(Face.body(11, .semibold))
                                        .foregroundStyle(Ink.bone)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .bare()
                            Rectangle().fill(Ink.bone.opacity(0.16)).frame(height: 1)
                        }
                    }
                }
            }
        }
        .background(Ink.black)
        .overlay(Rectangle().stroke(Ink.bone, lineWidth: 2))
        // Flip the face itself, or the list would read mirrored.
        .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
    }

    private var caption: some View {
        VStack(spacing: 3) {
            Text(current?.title ?? "")
                .font(Face.display(17, .black))
                .foregroundStyle(Ink.bone)
                .lineLimit(1)
            Text((current?.artist ?? "").uppercased())
                .font(Face.mono(10)).tracking(1.6)
                .foregroundStyle(Ink.smoke)
                .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .animation(.easeOut(duration: 0.18), value: index)
    }

    private var startIndex: Int {
        guard let playing = app.player.nowPlaying,
              let a = app.album(for: playing),
              let i = albums.firstIndex(of: a) else { return 0 }
        return i
    }

    private func clamp(_ v: Double) -> Double {
        min(max(v, 0), Double(max(albums.count - 1, 0)))
    }
}

/// One card in the flow: the sleeve, and its reflection under it.
///
/// Both come from a single decoded image and a single load. Drawing them as
/// two independent views meant two artwork lookups and two image layers per
/// album, twenty-two of them on screen at once, all being re-rendered on every
/// frame of a swipe. That is what made scrolling feel heavy.
private struct FlowCard<Back: View>: View {
    let trackID: UUID?
    let seed: String
    let side: CGFloat
    let dim: Double
    let showingBack: Bool
    @ViewBuilder var back: () -> Back

    @Environment(AppModel.self) private var app
    @State private var image: PlatformImage?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                sleeve
                if showingBack { back() }
            }
            .frame(width: side, height: side)
            // Covers butt up against each other, so each needs its own edge or
            // two neighbours in similar colours read as one slab.
            .overlay(Rectangle().stroke(.black.opacity(0.55), lineWidth: 1))
            .overlay(Color.black.opacity(dim))

            // Reflection: flipped about its own centre so it stays in frame,
            // cropped to half height, then faded out.
            sleeve
                .frame(width: side, height: side)
                .scaleEffect(y: -1)
                .frame(width: side, height: side * 0.5, alignment: .top)
                .clipped()
                .mask(LinearGradient(colors: [.white.opacity(0.42), .clear],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Color.black.opacity(dim))
                .opacity(showingBack ? 0 : 1)
                .allowsHitTesting(false)
        }
        .frame(width: side, height: side * 1.5)
        .task(id: trackID) {
            guard let id = trackID, let t = app.track(id) else { image = nil; return }
            if let hit = Artwork.cached(for: t) { image = hit; return }
            image = await Artwork.load(for: t)
        }
    }

    @ViewBuilder private var sleeve: some View {
        if let img = image {
            Image(platform: img).resizable().scaledToFill()
                .frame(width: side, height: side)
                .clipped()
        } else {
            ZStack {
                Ink.tint(for: seed)
                Image(systemName: "opticaldisc")
                    .font(.system(size: side * 0.3, weight: .black))
                    .foregroundStyle(Ink.black.opacity(0.6))
            }
            .frame(width: side, height: side)
        }
    }
}

/// The cover, full screen, zoomable.
///
/// Pinch to zoom, drag to move it around, double tap to fit again. Tapping the
/// black around it closes, which is why the image swallows its own taps.
struct CoverZoomView: View {
    let trackID: UUID?
    let seed: String
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app

    @State private var image: PlatformImage?
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    private var scale: CGFloat { min(max(zoom * pinch, 1), 8) }

    var body: some View {
        ZStack {
            // The ground, and the way out.
            Color.black.ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            GeometryReader { geo in
                Group {
                    if let img = image {
                        Image(platform: img).resizable().scaledToFit()
                    } else {
                        Ink.tint(for: seed)
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(scale)
                .offset(x: pan.width + drag.width, y: pan.height + drag.height)
                .gesture(
                    SimultaneousGesture(
                        DragGesture(minimumDistance: 4)
                            .updating($drag) { v, state, _ in state = v.translation }
                            .onEnded { v in
                                pan = clamp(CGSize(width: pan.width + v.translation.width,
                                                   height: pan.height + v.translation.height),
                                            in: geo.size)
                            },
                        MagnifyGesture()
                            .updating($pinch) { v, state, _ in state = v.magnification }
                            .onEnded { v in
                                zoom = min(max(zoom * v.magnification, 1), 8)
                                if zoom == 1 { pan = .zero } else { pan = clamp(pan, in: geo.size) }
                            }
                    )
                )
                // Swallow single taps so only the surrounding black dismisses.
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                        if zoom > 1 { zoom = 1; pan = .zero } else { zoom = 2.6 }
                    }
                }
                .onTapGesture { }
            }
        }
        .statusHidden()
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Ink.black)
                    .frame(width: 34, height: 30)
                    .background(Ink.bone)
            }
            .bare()
            .padding(.trailing, 14).padding(.top, 14)
        }
        .task(id: trackID) {
            guard let id = trackID, let t = app.track(id) else { return }
            if let hit = Artwork.cached(for: t) { image = hit; return }
            image = await Artwork.load(for: t)
        }
    }

    /// Keep the image from being dragged away entirely.
    private func clamp(_ p: CGSize, in size: CGSize) -> CGSize {
        let slackX = size.width * (scale - 1) / 2
        let slackY = size.height * (scale - 1) / 2
        return CGSize(width: min(max(p.width, -slackX), slackX),
                      height: min(max(p.height, -slackY), slackY))
    }
}
