import BummyTunesCore
import SwiftUI

// MARK: - Mini player

struct MiniPlayer: View {
    @Environment(AppModel.self) private var app
    let expand: () -> Void

    var body: some View {
        let t = app.player.nowPlaying
        HStack(spacing: 10) {
            Cover(trackID: t?.id, seed: t?.meta.album ?? "x", size: 40)
            VStack(alignment: .leading, spacing: 0) {
                Text(t?.meta.title ?? "")
                    .font(Face.display(17, .heavy)).foregroundStyle(Ink.bone).lineLimit(1)
                Text(t?.meta.artist ?? "")
                    .font(Face.body(10.5, .medium)).foregroundStyle(Ink.smoke).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { app.player.toggle() } label: {
                Image(systemName: app.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(Ink.black)
                    .frame(width: 38, height: 34)
                    .block("mp-play", skew: 6, stroke: 2, fill: Ink.bone)
            }
            Button { app.player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Ink.bone).frame(width: 30, height: 38)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .overlay(alignment: .top) {
            GeometryReader { g in
                Rectangle().fill(Ink.bone)
                    .frame(width: g.size.width * progress, height: 3)
            }
            .frame(height: 3).padding(.horizontal, 6)
        }
        .block("miniplayer", skew: 7, stroke: 2.5)
        .buttonStyle(BareButton())
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: expand)
    }

    private var progress: CGFloat {
        let d = app.player.duration
        return d > 0 ? CGFloat(app.player.currentTime / d) : 0
    }
}

// MARK: - Now playing (R5)

struct NowPlayingView: View {
    @Environment(AppModel.self) private var app
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false
    @State private var artistTarget: Artist?
    @State private var albumTarget: Album?
    @State private var scrub: Double?

    // Held rather than computed in `body`. The elapsed-time ticker redraws this
    // screen four times a second, and this list was running a full similarity
    // search over the library on each of those redraws.
    @State private var similar: [(Track, Float)] = []
    @State private var similarFor: UUID?

    var body: some View {
        NavigationStack {
            let t = app.player.nowPlaying
            ZStack {
                Ground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {

                        // Art over a turning record. The disc peeks out to the
                        // right, the way a sleeve half-covers one.
                        HStack {
                            Spacer(minLength: 0)
                            ZStack {
                                // The record rides out of its sleeve when you
                                // press play and tucks back in when you pause,
                                // which is the whole charm of the thing.
                                Vinyl(spinning: app.player.isPlaying,
                                      size: 214,
                                      labelColor: appearance.ground,
                                      trackID: t?.id)
                                    .offset(x: app.player.isPlaying ? 70 : 2)
                                    .shadow(color: .black.opacity(0.45), radius: 0, x: 5, y: 5)
                                    .animation(.spring(response: 0.6, dampingFraction: 0.74),
                                               value: app.player.isPlaying)
                                Cover(trackID: t?.id, seed: t?.meta.album ?? "x", size: 196)
                                    .offset(x: -68)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.top, 26)

                        Group {
                            if case .radio(_, let title, let m) = app.player.queue.origin {
                                Eyebrow("Radio · \(m.label) · \(title)", maxWidth: 290)
                            } else if case .album(let name) = app.player.queue.origin {
                                Eyebrow("Album · \(name)", maxWidth: 290)
                            } else if case .shuffleAll = app.player.queue.origin {
                                Eyebrow("Shuffled")
                            }
                        }
                        .padding(.leading, 18).offset(y: 12).zIndex(1)

                        // Tapping the title block opens the album it came from.
                        Button {
                            if let t { albumTarget = app.album(for: t) }
                        } label: {
                            Text(t?.meta.title ?? "")
                                .font(Face.display(34))
                                .foregroundStyle(Ink.bone)
                                .lineLimit(3)
                                .minimumScaleFactor(0.6)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .block("np-title", skew: 12, stroke: 3)
                        }
                        .disabled(t == nil)
                        .padding(.horizontal, 13)

                        // R5.1 — the artist is tappable text.
                        Button {
                            if let key = t?.meta.artistKey,
                               let a = app.artist(forKey: key) { artistTarget = a }
                        } label: {
                            HStack(spacing: 5) {
                                Text((t?.meta.artist ?? "").uppercased())
                                    .font(Face.mono(12, .black)).tracking(1.4)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 10, weight: .black))
                            }
                            .foregroundStyle(Ink.black)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .block("np-artist", skew: 6, stroke: 2, fill: Ink.bone)
                        }
                        .disabled(t == nil)
                        .padding(.leading, 18).padding(.top, 10)

                        // Album is tappable too, same as the artist.
                        HStack(spacing: 8) {
                            Button {
                                // Push inside this NavigationStack. Routing via
                                // the root's sheet made iOS wait for this sheet
                                // to dismiss before presenting, which read as
                                // the tap doing nothing.
                                if let t { albumTarget = app.album(for: t) }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "square.stack.fill")
                                        .font(.system(size: 10, weight: .black))
                                    Text((t?.meta.album ?? "").uppercased())
                                        .font(Face.mono(11, .black)).tracking(1.2)
                                        .lineLimit(1)
                                }
                                .foregroundStyle(Ink.bone)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .block("np-album", skew: 5, stroke: 2)
                            }
                            .disabled(t == nil)

                            Button { showQueue = true } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "square.stack.3d.up.fill")
                                        .font(.system(size: 11, weight: .black))
                                    Text("QUEUE")
                                        .font(Face.mono(11, .black)).tracking(1.2)
                                    Text("\(app.player.queue.count)")
                                        .font(Face.mono(10, .black))
                                        .foregroundStyle(Ink.black)
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(Ink.bone)
                                }
                                .foregroundStyle(Ink.bone)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .block("np-queue", skew: 5, stroke: 2)
                            }

                            // Start a radio from whatever is playing, in the
                            // mode currently selected.
                            Button {
                                if let t { app.startRadio(from: t) }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "dot.radiowaves.left.and.right")
                                        .font(.system(size: 10, weight: .black))
                                    Text("RADIO")
                                        .font(Face.mono(11, .black)).tracking(1.2)
                                }
                                .foregroundStyle(Ink.black)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .block("np-radio", skew: 5, stroke: 2, fill: Ink.bone)
                            }
                            .disabled(t == nil || !(t?.isAnalysed ?? false))

                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 18).padding(.trailing, 14).padding(.top, 7)

                        VStack(spacing: 6) {
                            ScrubBar(value: Binding(get: { scrub ?? app.player.currentTime },
                                                    set: { scrub = $0 }),
                                     total: max(app.player.duration, 1)) { s in
                                app.player.seek(to: s); scrub = nil
                            }
                            HStack {
                                Text(fmt(scrub ?? app.player.currentTime))
                                Spacer()
                                Text("−" + fmt(max(app.player.duration
                                                   - (scrub ?? app.player.currentTime), 0)))
                            }
                            .font(Face.mono(10)).foregroundStyle(Ink.bone)
                        }
                        .padding(.horizontal, 18).padding(.top, 18)

                        HStack(spacing: 0) {
                            transport("shuffle", active: app.player.queue.isShuffled) {
                                app.player.setShuffled(!app.player.queue.isShuffled)
                            }
                            Spacer()
                            transport("backward.fill") { app.player.previous() }
                            Spacer()
                            Button { app.player.toggle() } label: {
                                Image(systemName: app.player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 26, weight: .black))
                                    .foregroundStyle(Ink.black)
                                    .frame(width: 80, height: 58)
                                    .block("np-play", skew: 13, stroke: 3, fill: Ink.bone)
                            }
                            Spacer()
                            transport("forward.fill") { app.player.next() }
                            Spacer()
                            transport(app.player.queue.repeatMode == .one ? "repeat.1" : "repeat",
                                      active: app.player.queue.repeatMode != .off) {
                                app.player.cycleRepeat()
                            }
                        }
                        .padding(.horizontal, 20).padding(.vertical, 20)

                        if let t, t.isAnalysed {
                            HStack(spacing: 8) {
                                Eyebrow("Sounds like this")
                                Spacer()
                                // Swap radio behaviour and restart from here.
                                Button {
                                    let m = app.radioMode.next
                                    app.radioMode = m
                                    app.startRadio(from: t, mode: m)
                                } label: {
                                    Text(app.radioMode.label)
                                        .font(Face.mono(9.5, .black)).tracking(1.4)
                                        .foregroundStyle(Ink.black)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .block("np-mode", skew: 5, stroke: 2, fill: Ink.bone)
                                }
                            }
                            .padding(.horizontal, 18).padding(.bottom, 8)

                            LazyVStack(spacing: 7) {
                                ForEach(Array(similar.enumerated()),
                                        id: \.element.0.id) { i, pair in
                                    let (n, sim) = pair
                                    Button { app.startRadio(from: n) } label: {
                                        HStack(spacing: 10) {
                                            Text(String(format: "%.2f", sim))
                                                .font(Face.mono(10, .black))
                                                .foregroundStyle(Ink.black)
                                                .padding(.horizontal, 5).padding(.vertical, 2)
                                                .background(Ink.bone)
                                            VStack(alignment: .leading, spacing: 0) {
                                                Text(n.meta.title).font(Face.body(13.5, .bold))
                                                    .foregroundStyle(Ink.bone).lineLimit(1)
                                                Text(n.meta.artist).font(Face.body(10.5, .medium))
                                                    .foregroundStyle(Ink.smoke).lineLimit(1)
                                            }
                                            Spacer(minLength: 6)
                                        }
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .block("nb-\(n.path)", skew: 8, stroke: 2)
                                        .padding(.leading, 12 + CGFloat(Ink.stableHash(n.path) % 12))
                                        .padding(.trailing, 14)
                                    }
                                    .riseIn(i)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
            .buttonStyle(BareButton())
            // Swipe across the whole screen to move through the queue. High
            // minimum distance so it does not fight the scrubber or a scroll.
            .gesture(
                DragGesture(minimumDistance: 55)
                    .onEnded { v in
                        guard abs(v.translation.width) > abs(v.translation.height) * 1.6
                        else { return }
                        if v.translation.width < 0 { app.player.next() }
                        else { app.player.previous() }
                    })
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .leadingBar) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .black)).foregroundStyle(Ink.bone)
                    }
                }
                ToolbarItem(placement: .trailingBar) {
                    Button { showQueue = true } label: {
                        Image(systemName: "list.number")
                            .font(.system(size: 14, weight: .black)).foregroundStyle(Ink.bone)
                    }
                }
            }
            .navigationDestination(item: $artistTarget) { a in ArtistView(artist: a) }
            .onAppear { refreshSimilar() }
            .onChange(of: app.player.nowPlaying?.id) { _, _ in refreshSimilar() }
            .onChange(of: app.analysedCount) { _, _ in
                similarFor = nil
                refreshSimilar()
            }
            .navigationDestination(item: $albumTarget) { a in AlbumView(album: a) }
            .sheet(isPresented: $showQueue) { QueueView() }
        }
    }

    private func transport(_ icon: String, active: Bool = false,
                           _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(Ink.bone)
                .frame(width: 42, height: 42)
                .background {
                    if active {
                        Quad(seed: 41, skew: 5, jitter: 2).stroke(Ink.bone, lineWidth: 2)
                    }
                }
        }
    }

    private func fmt(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

// MARK: - Queue (R3.4, R3.5)

/// The queue, as a deck you scroll rather than a list.
///
/// Persona's kinetic entrance crossed with the XMB's sense of a row sliding
/// under a fixed selection point: cards stagger in from the side, lean by a
/// deterministic angle, and the item under the cursor scales up and inverts to
/// white. Reduce Motion drops the movement and keeps the inversion, which is
/// what actually communicates the selection.
extension NowPlayingView {
    /// Recompute the "sounds like this" list, but only when the track changes.
    func refreshSimilar() {
        let id = app.player.nowPlaying?.id
        guard similarFor != id else { return }
        similarFor = id
        if let id, let t = app.track(id) {
            similar = app.neighbours(of: t, count: 8)
        } else {
            similar = []
        }
    }
}

struct QueueView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Reordering. The queue is a stack of hand-drawn cards rather than a List,
    // so the drag is done here: hold the handle on the right, drag, and the
    // card follows; how far it travelled decides where it lands.
    @State private var dragIndex: Int?
    @State private var dragOffset: CGFloat = 0
    /// Card height plus the gap, measured from a real row.
    @State private var rowPitch: CGFloat = 68

    var body: some View {
        NavigationStack {
            ZStack {
                Ground()
                VStack(spacing: 0) {
                    Header(kicker: originLabel, value: "\(app.player.queue.count)",
                           unit: "in queue")

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 9) {
                                ForEach(Array(app.player.queue.items.enumerated()),
                                        id: \.offset) { i, id in
                                    if let t = app.track(id) {
                                        card(track: t, index: i,
                                             isCurrent: id == app.player.queue.current)
                                            .id(i)
                                            .offset(y: dragIndex == i ? dragOffset : 0)
                                            .zIndex(dragIndex == i ? 5 : 0)
                                            .onTapGesture {
                                                guard dragIndex == nil else { return }
                                                app.player.jump(to: id)
                                            }
                                    }
                                }
                            }
                            .padding(.top, 10).padding(.bottom, 60)
                        }
                        .onAppear {
                            // Open on whatever is playing, not at the top.
                            if let i = app.player.queue.currentIndex {
                                proxy.scrollTo(i, anchor: .center)
                            }
                        }
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                Button { dismiss() } label: {
                    Text("DONE").font(Face.mono(11, .black)).tracking(1.4)
                        .foregroundStyle(Ink.black)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .block("q-done", skew: 6, stroke: 2, fill: Ink.bone)
                }
                .buttonStyle(BareButton())
                .padding(.trailing, 14).padding(.top, 12)
            }
            .hideNavBar()
        }
    }

    @ViewBuilder
    private func card(track t: Track, index i: Int, isCurrent: Bool) -> some View {
        let lean = Ink.lean(t.path, max: 2.4)
        HStack(spacing: 11) {
            if isCurrent {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Ink.black).frame(width: 24)
            } else {
                Text("\(i + 1)")
                    .font(Face.mono(11, .black))
                    .foregroundStyle(Ink.bone).frame(width: 24)
            }
            Cover(trackID: t.id, seed: t.meta.album, size: isCurrent ? 46 : 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.meta.title)
                    .font(Face.display(isCurrent ? 21 : 18, .heavy))
                    .foregroundStyle(isCurrent ? Ink.black : Ink.bone)
                    .lineLimit(1)
                Text(t.meta.artist)
                    .font(Face.body(11, .medium))
                    .foregroundStyle(isCurrent ? Ink.ash : Ink.smoke)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)

            // Hold this and drag to move the track.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(isCurrent ? Ink.ash : Ink.smoke)
                .frame(width: 30, height: 40)
                .contentShape(Rectangle())
                .gesture(
                    LongPressGesture(minimumDuration: 0.2)
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .onChanged { value in
                            if case .second(true, let d) = value {
                                if dragIndex != i { dragIndex = i }
                                dragOffset = d?.translation.height ?? 0
                            }
                        }
                        .onEnded { _ in commitDrag() }
                )
        }
        .background(
            GeometryReader { g in
                Color.clear.onAppear {
                    if !isCurrent { rowPitch = g.size.height + 9 }
                }
            }
        )
        .padding(.horizontal, 12).padding(.vertical, isCurrent ? 12 : 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .block("q-\(t.path)", skew: isCurrent ? 13 : 9,
               stroke: isCurrent ? 3 : 2, fill: isCurrent ? Ink.bone : Ink.black)
        // The playing card breaks the row: bigger, straighter, pushed out.
        .scaleEffect(dragIndex == i ? 1.05
                     : (isCurrent && !reduceMotion ? 1.04 : 1.0), anchor: .leading)
        .shadow(color: .black.opacity(dragIndex == i ? 0.5 : 0),
                radius: 0, x: 5, y: 6)
        .rotationEffect(.degrees(isCurrent ? 0 : lean))
        .padding(.leading, isCurrent ? 8 : 14 + CGFloat(Ink.stableHash(t.path) % 18))
        .padding(.trailing, 14)
        .animation(.spring(response: 0.34, dampingFraction: 0.74), value: isCurrent)
        .riseIn(i)
    }

    /// Land the dragged card, then clear the drag.
    private func commitDrag() {
        defer {
            dragIndex = nil
            dragOffset = 0
        }
        guard let from = dragIndex, app.player.queue.count > 1 else { return }
        let steps = Int((dragOffset / max(rowPitch, 1)).rounded())
        let to = min(max(from + steps, 0), app.player.queue.count - 1)
        guard to != from else { return }
        // `move(from:to:)` takes the destination as an index in the list before
        // the moved item is pulled out, so moving down needs one extra.
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
            app.player.moveInQueue(from: IndexSet(integer: from),
                                   to: to > from ? to + 1 : to)
        }
    }

    private var originLabel: String {
        switch app.player.queue.origin {
        case .album(let n): return "Album · \(n)"
        case .artist(let n): return "Artist · \(n)"
        case .radio(_, let n, let m): return "Radio · \(m.label) · \(n)"
        case .shuffleAll: return "Shuffled"
        case .search: return "From search"
        case .none: return "Queue"
        }
    }
}
