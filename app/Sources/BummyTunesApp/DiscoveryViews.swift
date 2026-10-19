import BummyTunesCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Search (R12, R4.2)

struct SearchView: View {
    var topSignal: Int = 0
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @FocusState private var focused: Bool

    /// Held rather than computed in `body`. As a computed property the search
    /// ran twice per redraw, once for the empty check and once for the rows.
    @State private var results: [Track] = []

    var body: some View {
        NavigationStack {
            ZStack {
                Ground()
                VStack(alignment: .leading, spacing: 0) {

                    // The app's own search field. The system `.searchable`
                    // modifier renders an iOS large title and rounded search
                    // bar, which belongs to a different app entirely.
                    VStack(alignment: .leading, spacing: 0) {
                        Eyebrow("Search")
                            .rotationEffect(.degrees(-2))
                            .offset(x: 6, y: 7).zIndex(1)

                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 17, weight: .black))
                                .foregroundStyle(Ink.bone)
                            TextField("", text: $query, prompt:
                                Text("SONGS, ARTISTS, ALBUMS").foregroundColor(Ink.smoke))
                                .focused($focused)
                                .textFieldStyle(.plain)
                                .autocorrectionDisabled()
                                .submitLabel(.search)
                                .onChange(of: query) { _, q in
                                    results = q.isEmpty ? [] : app.search(q)
                                }
                                .font(Face.display(24, .black))
                                .foregroundStyle(Ink.bone)
                            if !query.isEmpty {
                                Text("\(results.count)")
                                    .font(Face.mono(11, .black))
                                    .foregroundStyle(Ink.black)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Ink.bone)
                                Button { query = "" } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 14, weight: .black))
                                        .foregroundStyle(Ink.bone)
                                }
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .block("search-field", skew: 11, stroke: 3)
                    }
                    .padding(.leading, 12).padding(.trailing, 14).padding(.top, 8)

                    if !query.isEmpty {
                        // The folded query, shown rather than hidden: it is what
                        // makes "pois e" find "Pois É".
                        HStack(spacing: 8) {
                            Text("FOLDED").font(Face.mono(8.5, .black)).tracking(1.4)
                                .foregroundStyle(Ink.black)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Ink.bone)
                            Text(SearchKey.fold(query))
                                .font(Face.mono(10.5)).foregroundStyle(Ink.bone)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 20).padding(.top, 10)
                    }

                    if results.isEmpty {
                        // Nothing here on an empty query: the field is already
                        // focused and self-explanatory, and a placard just took
                        // up the space results are about to fill.
                        if !query.isEmpty {
                            Text("NOTHING MATCHES")
                                .font(Face.display(26)).foregroundStyle(Ink.bone)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .block("search-empty", skew: 10, stroke: 2.5)
                                .padding(.leading, 16).padding(.top, 22)
                        }
                        Spacer()
                    } else {
                        ScrollViewReader { top in
                            ScrollView {
                                LazyVStack(spacing: 7) {
                                    // R4.2 — tapping a result starts a radio.
                                    ForEach(Array(results.enumerated()),
                                            id: \.element.id) { i, t in
                                        TrackRow(track: t, index: nil, showArt: true) {
                                            app.startRadio(from: t)
                                        }
                                        .riseIn(i)
                                        .id(i == 0 ? "top" : "row\(i)")
                                    }
                                }
                                .padding(.top, 12).padding(.bottom, 130)
                            }
                            .onChange(of: topSignal) { _, _ in
                                withAnimation(.easeOut(duration: 0.32)) {
                                    top.scrollTo("top", anchor: .top)
                                }
                            }
                        }
                    }
                }
            }
            .buttonStyle(BareButton())
            .hideNavBar()
        }
    }
}

// MARK: - Music map (R7.1)

struct MapView: View {
    @Environment(AppModel.self) private var app
    @State private var selected: UUID?

    // Camera. The layout in `point` never changes; these move the view over it,
    // which keeps hit testing honest because both drawing and tapping go
    // through the same transform.
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    // The seed's neighbours, held rather than recomputed. This used to be
    // worked out inside the Canvas draw, which meant a full similarity search
    // over the whole library on every single frame of a pan or a pinch.
    @State private var seedNeighbours: Set<UUID> = []
    @State private var neighboursFor: UUID?

    private var scale: CGFloat { min(max(zoom * pinch, 1), 12) }
    private var offset: CGSize {
        CGSize(width: pan.width + drag.width, height: pan.height + drag.height)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Ground(petals: false)

                if app.mapPoints.isEmpty {
                    NotAnalysedYet()
                } else {
                    GeometryReader { geo in
                        Canvas { ctx, size in draw(ctx: &ctx, size: size) }
                            .onAppear { refreshNeighbours() }
                            .onChange(of: selected) { _, _ in refreshNeighbours() }
                            .onChange(of: app.player.nowPlaying?.id) { _, _ in
                                refreshNeighbours()
                            }
                            .onChange(of: app.analysedCount) { _, _ in
                                neighboursFor = nil
                                refreshNeighbours()
                            }
                            .contentShape(Rectangle())
                            // Drag to pan, pinch to zoom. Both run at once, and
                            // both feed the same transform the hit test uses.
                            .gesture(
                                SimultaneousGesture(
                                    DragGesture(minimumDistance: 8)
                                        .updating($drag) { v, state, _ in
                                            state = v.translation
                                        }
                                        .onEnded { v in
                                            pan = clampPan(
                                                CGSize(width: pan.width + v.translation.width,
                                                       height: pan.height + v.translation.height),
                                                in: geo.size)
                                        },
                                    MagnifyGesture()
                                        .updating($pinch) { v, state, _ in
                                            state = v.magnification
                                        }
                                        .onEnded { v in
                                            zoom = min(max(zoom * v.magnification, 1), 12)
                                            pan = clampPan(pan, in: geo.size)
                                        }
                                )
                            )
                            // Double tap returns to the whole field.
                            .onTapGesture(count: 2) {
                                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                                    zoom = 1; pan = .zero
                                }
                            }
                            // Selecting a point only moves the seed and redraws
                            // its neighbours. Exploring the map should not tear
                            // down whatever you are listening to; the panel
                            // below is what commits to playing.
                            .onTapGesture { location in
                                if let hit = nearest(to: location, in: geo.size) {
                                    selected = hit
                                }
                            }
                    }

                    if let id = selected ?? app.player.nowPlaying?.id,
                       let t = app.track(id) {
                        SeedPanel(track: t,
                                  bottomInset: app.player.nowPlaying != nil ? 116 : 58) {
                            app.startRadio(from: t)
                        }
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                Header(kicker: "Music map", value: app.mapPoints.count.grouped, unit: "plotted")
            }
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 6) {
                    // Only appears once you have moved the camera, and tapping
                    // it puts the whole field back.
                    if scale > 1.02 || offset != .zero {
                        Button {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                                zoom = 1; pan = .zero
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.down.left.and.arrow.up.right")
                                    .font(.system(size: 9, weight: .black))
                                Text(String(format: "%.1f×", scale))
                                    .font(Face.mono(9, .black))
                            }
                            .foregroundStyle(Ink.black)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(Ink.bone)
                        }
                        .bare()
                    }

                    Text(String(format: "PC1 %.0f%%\nPC2 %.0f%%",
                                app.mapVariance.0 * 100, app.mapVariance.1 * 100))
                        .font(Face.mono(9)).foregroundStyle(Ink.black)
                        .multilineTextAlignment(.trailing)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(Ink.bone)

                    // Legend. Says plainly whether these are real genre tags or
                    // clusters derived from the audio, so the colours are not
                    // mistaken for something they are not.
                    if !app.mapGroupNames.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.mapGroupsFromTags ? "GENRE" : "SONIC CLUSTER")
                                .font(Face.mono(8, .black)).tracking(1.2)
                                .foregroundStyle(Ink.smoke)
                            // Every group, not a slice of them. A legend that
                            // stops early is worse than no legend: the colours
                            // it leaves out are still on the map.
                            ForEach(Array(app.mapGroupNames.enumerated()),
                                    id: \.offset) { i, name in
                                HStack(spacing: 5) {
                                    Rectangle().fill(app.color(forGroup: i))
                                        .frame(width: 8, height: 8)
                                    Text(name.uppercased())
                                        .font(Face.mono(8)).tracking(0.6)
                                        .foregroundStyle(Ink.bone).lineLimit(1)
                                }
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 7)
                        .block("map-legend", skew: 5, stroke: 2)
                        .frame(maxWidth: 132, alignment: .trailing)
                    }
                }
                .padding(.trailing, 13).padding(.top, 14)
            }
            .buttonStyle(BareButton())
            .hideNavBar()
        }
    }

    /// Where a point sits before the camera is applied.
    private func layout(_ p: CGPoint, in size: CGSize) -> CGPoint {
        let padX: CGFloat = 26, top: CGFloat = 112, bottom: CGFloat = 172
        return CGPoint(x: padX + (p.x + 1) / 2 * (size.width - padX * 2),
                       y: top + (1 - (p.y + 1) / 2) * max(size.height - top - bottom, 1))
    }

    /// Layout position with pan and zoom applied.
    private func point(_ p: CGPoint, in size: CGSize) -> CGPoint {
        let q = layout(p, in: size)
        let cx = size.width / 2, cy = size.height / 2
        return CGPoint(x: (q.x - cx) * scale + cx + offset.width,
                       y: (q.y - cy) * scale + cy + offset.height)
    }

    /// Keep the field from being flung off screen entirely.
    private func clampPan(_ p: CGSize, in size: CGSize) -> CGSize {
        let slackX = size.width * (scale - 1) / 2 + 100
        let slackY = size.height * (scale - 1) / 2 + 100
        return CGSize(width: min(max(p.width, -slackX), slackX),
                      height: min(max(p.height, -slackY), slackY))
    }

    private func nearest(to loc: CGPoint, in size: CGSize) -> UUID? {
        var best: UUID?; var bd = CGFloat.greatestFiniteMagnitude
        for (id, p) in app.mapPoints {
            let q = point(p, in: size)
            let d = pow(q.x - loc.x, 2) + pow(q.y - loc.y, 2)
            if d < bd { bd = d; best = id }
        }
        return bd < 2200 ? best : nil
    }

    private var seedID: UUID? { selected ?? app.player.nowPlaying?.id }

    /// Recompute the highlighted neighbours, but only when the seed moves.
    private func refreshNeighbours() {
        let want = seedID
        guard neighboursFor != want else { return }
        neighboursFor = want
        if let s = want, let t = app.track(s) {
            seedNeighbours = Set(app.neighbours(of: t, count: 12).map(\.0.id))
        } else {
            seedNeighbours = []
        }
    }

    private func draw(ctx: inout GraphicsContext, size: CGSize) {
        let seedID = self.seedID
        let neighbourIDs = seedNeighbours

        // Field: one colour per genre, or per sonic cluster when the library
        // has no usable genre tags.
        for (id, p) in app.mapPoints where id != seedID && !neighbourIDs.contains(id) {
            let q = point(p, in: size)
            let c = app.color(forGroup: app.mapGroups[id])
            let r = CGRect(x: q.x - 2.6, y: q.y - 2.6, width: 5.2, height: 5.2)
            ctx.fill(Path(ellipseIn: r), with: .color(c.opacity(0.92)))
        }

        if let s = seedID, let sp = app.mapPoints[s] {
            let a = point(sp, in: size)
            for id in neighbourIDs {
                guard let np = app.mapPoints[id] else { continue }
                let b = point(np, in: size)
                var line = Path(); line.move(to: a); line.addLine(to: b)
                ctx.stroke(line, with: .color(Ink.black), lineWidth: 2)
                ctx.stroke(line, with: .color(Ink.bone), lineWidth: 0.8)
            }
            for id in neighbourIDs {
                guard let np = app.mapPoints[id] else { continue }
                let b = point(np, in: size)
                let r = CGRect(x: b.x - 5, y: b.y - 5, width: 10, height: 10)
                ctx.fill(Path(ellipseIn: r), with: .color(Ink.black))
                ctx.stroke(Path(ellipseIn: r), with: .color(Ink.bone), lineWidth: 2)
            }
            // Seed: a white diamond with a black outline, the one bright mark.
            var d = Path()
            d.move(to: CGPoint(x: a.x, y: a.y - 11))
            d.addLine(to: CGPoint(x: a.x + 11, y: a.y))
            d.addLine(to: CGPoint(x: a.x, y: a.y + 11))
            d.addLine(to: CGPoint(x: a.x - 11, y: a.y))
            d.closeSubpath()
            ctx.fill(d, with: .color(Ink.bone))
            ctx.stroke(d, with: .color(Ink.black), lineWidth: 3)
        }
    }
}

struct SeedPanel: View {
    let track: Track
    /// How much room to leave under it. Only the tab bar when nothing is
    /// playing, the tab bar plus the mini player when something is.
    var bottomInset: CGFloat = 118
    var play: () -> Void

    var body: some View {
        // No eyebrow here. It was bone on bone, so it rendered as a blank
        // white slab over the panel and said nothing.
        VStack(alignment: .leading, spacing: 4) {
            Button(action: play) {
                HStack(spacing: 11) {
                    Cover(trackID: track.id, seed: track.meta.album, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.meta.title)
                            .font(Face.display(24)).foregroundStyle(Ink.bone).lineLimit(2)
                        Text("\(track.meta.artist.uppercased()) — \(track.meta.album)")
                            .font(Face.mono(9.5)).tracking(1)
                            .foregroundStyle(Ink.smoke).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "play.fill")
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(Ink.black)
                        .frame(width: 40, height: 36)
                        .block("seed-play", skew: 6, stroke: 2, fill: Ink.bone)
                }
                .padding(.horizontal, 13).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .block("seed-panel", skew: 11, stroke: 3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, bottomInset)
    }
}

struct NotAnalysedYet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer()
            Eyebrow("No embeddings yet").rotationEffect(.degrees(-2))
                .offset(x: 6, y: 8).zIndex(1)
            Text("THE MAP\nNEEDS\nANALYSIS")
                .font(Face.display(44)).foregroundStyle(Ink.bone)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .block("map-empty", skew: 12, stroke: 3)
            Text("Run it in Settings and every track lands here by how it sounds.")
                .font(Face.body(12.5, .semibold)).foregroundStyle(Ink.bone)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Settings (R6.1)

struct SettingsView: View {
    var topSignal: Int = 0
    @Environment(AppModel.self) private var app
    @Environment(Appearance.self) private var appearance
    @State private var picking = false
    @State private var docsCount = 0

    private var done: Bool { app.analysedCount == app.tracks.count }

    var body: some View {
        NavigationStack {
            ZStack {
                Ground()
                ScrollViewReader { top in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Header(kicker: "Sonic analysis",
                               value: app.analysedCount.grouped,
                               unit: "of \(app.tracks.count.grouped)")
                            .id("top")

                        if app.analysis.isRunning {
                            VStack(alignment: .leading, spacing: 9) {
                                ProgressView(value: app.analysis.fraction).tint(Ink.bone)
                                Text(app.analysis.currentTitle ?? "")
                                    .font(Face.mono(10)).foregroundStyle(Ink.bone).lineLimit(1)
                                ActionBlock("STOP", icon: "stop.fill", seed: "stop") {
                                    app.cancelAnalysis()
                                }
                            }
                            .padding(.horizontal, 14).padding(.top, 16)
                        } else {
                            ActionBlock(done ? "ALL ANALYSED" : "EMBED LIBRARY",
                                        icon: done ? "checkmark" : "waveform.path",
                                        seed: "embed", invert: !done) {
                                app.startAnalysis()
                            }
                            .opacity(done ? 0.55 : 1)
                            .disabled(done)
                            .padding(.horizontal, 14).padding(.top, 16)

                            Text("Runs on this device. Nothing is uploaded. It keeps going while music plays, so a big library finishes as you listen.")
                                .font(Face.body(12, .semibold)).foregroundStyle(Ink.bone)
                                .padding(.horizontal, 16).padding(.top, 12)
                        }

                        // MARK: appearance
                        VStack(alignment: .leading, spacing: 10) {
                            Eyebrow("Colour").rotationEffect(.degrees(-2))
                                .offset(x: 4, y: 8).zIndex(1)

                            ModePicker(Appearance.Mode.allCases.map(\.label),
                                       selection: Binding(
                                        get: { Appearance.Mode.allCases
                                            .firstIndex(of: appearance.mode) ?? 0 },
                                        set: { appearance.mode = Appearance.Mode.allCases[$0] }))

                            switch appearance.mode {
                            case .preset:
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(),
                                                                            spacing: 8), count: 4),
                                          spacing: 8) {
                                    ForEach(Appearance.presets) { p in
                                        let shapeSeed = Int(Ink.stableHash(p.id) % 300)
                                        Button { appearance.presetID = p.id } label: {
                                            ZStack {
                                                Quad(seed: shapeSeed,
                                                     skew: 6, jitter: 2).fill(p.color)
                                                Quad(seed: shapeSeed,
                                                     skew: 6, jitter: 2)
                                                    .stroke(Ink.bone,
                                                            lineWidth: appearance.presetID == p.id
                                                                       ? 4 : 2)
                                                if appearance.presetID == p.id {
                                                    Image(systemName: "checkmark")
                                                        .font(.system(size: 15, weight: .black))
                                                        .foregroundStyle(Ink.bone)
                                                }
                                            }
                                            .frame(height: 52)
                                        }
                                    }
                                }
                                Text((Appearance.presets.first { $0.id == appearance.presetID }
                                      ?? Appearance.presets[0]).name.uppercased())
                                    .font(Face.mono(9.5)).tracking(1.4)
                                    .foregroundStyle(Ink.bone)

                            case .custom:
                                VStack(spacing: 8) {
                                    channel("R", appearance.r) {
                                        appearance.setCustom(r: $0, g: appearance.g,
                                                             b: appearance.b) }
                                    channel("G", appearance.g) {
                                        appearance.setCustom(r: appearance.r, g: $0,
                                                             b: appearance.b) }
                                    channel("B", appearance.b) {
                                        appearance.setCustom(r: appearance.r, g: appearance.g,
                                                             b: $0) }
                                    HStack(spacing: 10) {
                                        Rectangle().fill(Color(hex: appearance.customHex))
                                            .frame(height: 34)
                                            .overlay(Rectangle().stroke(Ink.bone, lineWidth: 2))
                                        Text(String(format: "#%06X", appearance.customHex))
                                            .font(Face.mono(12, .black))
                                            .foregroundStyle(Ink.bone)
                                    }
                                }
                                .padding(.horizontal, 12).padding(.vertical, 11)
                                .block("custom-rgb", skew: 8, stroke: 2.5)

                            case .dynamic:
                                Text("The ground takes its colour from the cover of whatever is playing. Blocks stay black and type stays white, so it never stops being readable.")
                                    .font(Face.body(12, .semibold)).foregroundStyle(Ink.bone)
                                    .padding(.horizontal, 12).padding(.vertical, 10)
                                    .block("dyn-note", skew: 8, stroke: 2.5)
                            }
                        }
                        .padding(.horizontal, 14).padding(.top, 26)

                        // MARK: audio
                        VStack(alignment: .leading, spacing: 8) {
                            Eyebrow("Audio").rotationEffect(.degrees(-2))
                                .offset(x: 4, y: 8).zIndex(1)

                            switchRow("MONO AUDIO", "Fold stereo down to one channel",
                                      "mono",
                                      Binding(get: { app.player.mono },
                                              set: { app.player.mono = $0 }))

                            switchRow("GAPLESS-ISH", "Start the next track the moment one ends",
                                      "gapless",
                                      Binding(get: { app.prefs.gapless },
                                              set: { app.prefs.gapless = $0 }))

                            switchRow("RESUME ON LAUNCH", "Reopen where you left off",
                                      "resume",
                                      Binding(get: { app.prefs.resumeOnLaunch },
                                              set: { app.prefs.resumeOnLaunch = $0 }))
                        }
                        .padding(.horizontal, 14).padding(.top, 26)

                        // MARK: radio
                        VStack(alignment: .leading, spacing: 8) {
                            Eyebrow("Radio").rotationEffect(.degrees(-2))
                                .offset(x: 4, y: 8).zIndex(1)

                            ModePicker(PlayQueue.RadioMode.allCases.map(\.label),
                                       selection: Binding(
                                        get: { PlayQueue.RadioMode.allCases
                                            .firstIndex(of: app.radioMode) ?? 0 },
                                        set: { app.radioMode = PlayQueue.RadioMode.allCases[$0] }))
                            Text(app.radioMode.blurb)
                                .font(Face.body(11.5, .medium)).foregroundStyle(Ink.bone)

                            stepperRow("QUEUE LENGTH", "\(app.prefs.radioLength)",
                                       "radiolen",
                                       down: { app.prefs.radioLength =
                                            max(10, app.prefs.radioLength - 10) },
                                       up: { app.prefs.radioLength =
                                            min(200, app.prefs.radioLength + 10) })

                            stepperRow("MAX PER ALBUM", "\(app.prefs.maxPerAlbum)",
                                       "maxalbum",
                                       down: { app.prefs.maxPerAlbum =
                                            max(1, app.prefs.maxPerAlbum - 1) },
                                       up: { app.prefs.maxPerAlbum =
                                            min(12, app.prefs.maxPerAlbum + 1) })
                        }
                        .padding(.horizontal, 14).padding(.top, 26)

                        // MARK: map
                        VStack(alignment: .leading, spacing: 8) {
                            Eyebrow("Music map").rotationEffect(.degrees(-2))
                                .offset(x: 4, y: 8).zIndex(1)
                            HStack(spacing: 8) {
                                Text(app.mapGroupsFromTags ? "COLOURED BY GENRE TAG"
                                                           : "COLOURED BY SONIC CLUSTER")
                                    .font(Face.mono(9.5, .black)).tracking(1.2)
                                    .foregroundStyle(Ink.bone)
                                Spacer()
                                Text("\(app.mapGroupNames.count)")
                                    .font(Face.mono(10, .black)).foregroundStyle(Ink.black)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Ink.bone)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .block("mapinfo", skew: 8, stroke: 2.5)

                            ActionBlock("RECOMPUTE MAP", icon: "arrow.triangle.2.circlepath",
                                        seed: "recompute") { app.recomputeMap() }
                        }
                        .padding(.horizontal, 14).padding(.top, 26)

                        VStack(alignment: .leading, spacing: 12) {
                            Eyebrow("Library").rotationEffect(.degrees(-2))
                                .offset(x: 4, y: 8).zIndex(1)
                            HStack(spacing: 8) {
                                stat(app.tracks.count.grouped, "TRACKS", "s1")
                                stat("\(app.albums.count)", "ALBUMS", "s2")
                                stat("\(app.artists.count)", "ARTISTS", "s3")
                            }
                            // Music added to a folder after it was imported is
                            // invisible until someone looks again. This is that.
                            VStack(alignment: .leading, spacing: 6) {
                                ActionBlock(app.rescanning ? "SCANNING…" : "SCAN FOR NEW MUSIC",
                                            icon: "arrow.clockwise", seed: "rescan",
                                            invert: true) {
                                    Task { await app.rescanLibrary(force: true) }
                                }
                                .disabled(app.rescanning)
                                // Say what happened. Finding nothing and never
                                // having run look the same otherwise.
                                if let status = app.rescanStatus, !app.rescanning {
                                    Text(status.uppercased())
                                        .font(Face.mono(9.5)).tracking(1.2)
                                        .foregroundStyle(Ink.smoke)
                                        .padding(.leading, 4)
                                }
                            }

                            ActionBlock(app.needsFolderAgain
                                        ? "PICK YOUR LIBRARY FOLDER"
                                        : "ADD ANOTHER FOLDER",
                                        icon: "folder.badge.plus",
                                        seed: "addfolder",
                                        invert: app.needsFolderAgain) { picking = true }
                            // No-picker path, for when LiveContainer blocks the
                            // document picker. See LibraryImporter.
                            if docsCount > 0 {
                                ActionBlock("IMPORT \(docsCount) IN MY FOLDER",
                                            icon: "folder.fill", seed: "importdocs",
                                            invert: true) {
                                    Task { await app.importDocumentsFolder() }
                                }
                            }
                        }
                        .padding(.horizontal, 14).padding(.top, 26)

                    }
                    .padding(.bottom, 130)
                }
                .onChange(of: topSignal) { _, _ in
                    withAnimation(.easeOut(duration: 0.32)) {
                        top.scrollTo("top", anchor: .top)
                    }
                }
                }
            }
            .buttonStyle(BareButton())
            .hideNavBar()
            .task { docsCount = app.documentsAudioCount }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await app.importFolder(url) }
        }
    }

    private func diagRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(k.uppercased()).font(Face.mono(9)).tracking(1)
                .foregroundStyle(Ink.smoke)
            Spacer(minLength: 8)
            Text(v).font(Face.mono(9.5, .black)).foregroundStyle(Ink.bone)
                .multilineTextAlignment(.trailing).lineLimit(3)
        }
    }

    /// A labelled on/off row in the app's block language.
    private func switchRow(_ title: String, _ blurb: String, _ seed: String,
                           _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Face.display(17, .black)).foregroundStyle(Ink.bone)
                Text(blurb).font(Face.body(11, .medium)).foregroundStyle(Ink.smoke)
            }
        }
        .tint(Ink.bone)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .block(seed, skew: 8, stroke: 2.5)
    }

    /// A numeric row with minus and plus blocks either side of the value.
    private func stepperRow(_ title: String, _ value: String, _ seed: String,
                            down: @escaping () -> Void,
                            up: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title).font(Face.display(16, .black)).foregroundStyle(Ink.bone)
            Spacer()
            Button(action: down) {
                Image(systemName: "minus").font(.system(size: 13, weight: .black))
                    .foregroundStyle(Ink.black).frame(width: 32, height: 28)
                    .block("\(seed)-d", skew: 5, stroke: 2, fill: Ink.bone)
            }
            Text(value).font(Face.mono(13, .black)).foregroundStyle(Ink.bone)
                .frame(minWidth: 34)
            Button(action: up) {
                Image(systemName: "plus").font(.system(size: 13, weight: .black))
                    .foregroundStyle(Ink.black).frame(width: 32, height: 28)
                    .block("\(seed)-u", skew: 5, stroke: 2, fill: Ink.bone)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .block(seed, skew: 8, stroke: 2.5)
    }

    /// One RGB channel: a labelled slider with its 0-255 value.
    private func channel(_ name: String, _ value: Double,
                         _ set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(name).font(Face.mono(12, .black)).foregroundStyle(Ink.bone)
                .frame(width: 14)
            Slider(value: Binding(get: { value }, set: set), in: 0...255)
                .tint(Ink.bone)
            Text("\(Int(value))").font(Face.mono(11))
                .foregroundStyle(Ink.bone).frame(width: 32, alignment: .trailing)
        }
    }

    private func stat(_ value: String, _ label: String, _ seed: String) -> some View {
        VStack(alignment: .leading, spacing: -2) {
            Text(value).font(Face.display(27)).foregroundStyle(Ink.bone)
            Text(label).font(Face.mono(8)).tracking(1.2).foregroundStyle(Ink.smoke)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .block(seed, skew: 7, stroke: 2)
    }
}
