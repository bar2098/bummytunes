import BummyTunesCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Root

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(Appearance.self) private var appearance
    @State private var tab = 0
    @State private var showNowPlaying = false
    /// Bumped when the already-selected tab is tapped again.
    @State private var topSignal = 0

    /// Tapping the tab you are already on scrolls that screen back to the top,
    /// the way every other iOS app behaves.
    private var tabSelection: Binding<Int> {
        Binding(get: { tab },
                set: { new in
                    if new == tab { topSignal &+= 1 } else { tab = new }
                })
    }

    /// The bottom of the ground gradient, so the bar reads as part of it.
    private var barColor: Color { appearance.ground.shaded(0.78) }

    var body: some View {
        ZStack(alignment: .bottom) {
            Ground()
            if !app.hasLibrary {
                WelcomeView()
            } else {
                TabView(selection: tabSelection) {
                    LibraryView(topSignal: topSignal).solidTabBar(barColor).iOSOnlyTabItem { Label("Library", systemImage: "square.stack.3d.down.right.fill") }.tag(0)
                    SearchView(topSignal: topSignal).solidTabBar(barColor).iOSOnlyTabItem { Label("Search", systemImage: "magnifyingglass") }.tag(1)
                    MapView().solidTabBar(barColor).iOSOnlyTabItem { Label("Map", systemImage: "scope") }.tag(2)
                    SettingsView(topSignal: topSignal).solidTabBar(barColor).iOSOnlyTabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(3)
                }
                .tint(Ink.bone)

                if app.player.nowPlaying != nil {
                    MiniPlayer(expand: { showNowPlaying = true })
                        .padding(.bottom, 49)
                        .transition(.move(edge: .bottom))
                }
            }
        }
        .buttonStyle(BareButton())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showNowPlaying) { NowPlayingView() }
        // Long-press actions can navigate from any screen, so the destination
        // is presented here rather than inside whichever list was tapped.
        .sheet(item: Binding(get: { app.navTarget },
                             set: { app.navTarget = $0 })) { target in
            NavigationStack {
                switch target {
                case .artist(let key):
                    if let a = app.artist(forKey: key) { ArtistView(artist: a) }
                case .album(let id):
                    if let a = app.album(withID: id) { AlbumView(album: a) }
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}

/// Screen header: a black block that hangs off the top-left, overlapping the
/// content below it, the way the game stacks its title cards.
struct Header: View {
    let kicker: String
    let value: String
    let unit: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(kicker)
                    .rotationEffect(.degrees(-2))
                    .offset(x: 4, y: 6)
                    .zIndex(1)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(value)
                        .font(Face.display(62)).foregroundStyle(Ink.bone)
                    Text(unit.uppercased())
                        .font(Face.display(19)).foregroundStyle(Ink.smoke)
                        .offset(y: -4)
                }
                .padding(.horizontal, 16).padding(.vertical, 9)
                .block("hdr-\(kicker)", skew: 12, stroke: 3)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10).padding(.top, 6)
    }
}

// MARK: - First run (R8.1)

struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @State private var picking = false
    @State private var docsCount = 0

    var body: some View {
        ZStack {
            Ground()
            Spine(steps: 8, width: 16).frame(width: 120)
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(x: -34)
                .opacity(0.85)

            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: 66)

                // Stacked, overlapping title cards at opposing angles.
                HStack(spacing: -14) {
                    Text("BUMMY")
                        .font(Face.display(58)).foregroundStyle(Ink.bone)
                        .padding(.horizontal, 15).padding(.vertical, 7)
                        .block("bt-1", skew: 11, stroke: 3)
                        .rotationEffect(.degrees(-3))
                    Text("TUNES")
                        .font(Face.display(58)).foregroundStyle(Ink.black)
                        .padding(.horizontal, 15).padding(.vertical, 7)
                        .block("bt-2", skew: 11, stroke: 3, fill: Ink.bone)
                        .rotationEffect(.degrees(2))
                        .offset(y: 16)
                }
                .padding(.leading, 14)

                Eyebrow("Sonic analysis · on device")
                    .offset(x: 40, y: 26)

                Spacer(minLength: 12)

                VStack(alignment: .leading, spacing: 16) {
                    Text("Point it at a folder.\nEverything after\nhappens on this phone.")
                        .font(Face.display(27, .heavy))
                        .foregroundStyle(Ink.bone)
                        .lineSpacing(-1)
                        .padding(.horizontal, 16).padding(.vertical, 13)
                        .block("wel-copy", skew: 10, stroke: 2.5)

                    Button { picking = true } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 21, weight: .black))
                            Text("ADD LIBRARY").font(Face.display(27, .black)).tracking(1)
                        }
                        .foregroundStyle(Ink.bone)
                        .padding(.horizontal, 22).padding(.vertical, 13)
                        .block("wel-cta", skew: 13, stroke: 3)
                        .rotationEffect(.degrees(-1.5))
                    }

                    // The system picker refuses to open under LiveContainer
                    // unless "Fix File Picker" is enabled for the guest app.
                    // This path needs no picker at all: music copied into the
                    // app's own folder in Files is imported directly.
                    if docsCount > 0 {
                        Button { Task { await app.importDocumentsFolder() } } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 17, weight: .black))
                                Text("IMPORT \(docsCount) IN MY FOLDER")
                                    .font(Face.display(20, .black)).tracking(0.6)
                            }
                            .foregroundStyle(Ink.black)
                            .padding(.horizontal, 18).padding(.vertical, 11)
                            .block("wel-docs", skew: 10, stroke: 2.5, fill: Ink.bone)
                        }
                    } else {
                        Text("Picker not opening? In LiveContainer long-press this app, open Settings and turn on \u{201C}Fix File Picker\u{201D}. Or copy music into Files \u{203A} On My iPhone \u{203A} BummyTunes and reopen.")
                            .font(Face.body(11.5, .semibold))
                            .foregroundStyle(Ink.bone)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .block("wel-hint", skew: 8, stroke: 2)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 44)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(BareButton())
        .task { docsCount = app.documentsAudioCount }
        .overlay {
            if app.importing {
                ImportOverlay(done: app.importProgress.0, total: app.importProgress.1)
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await app.importFolder(url) }
        }
    }
}

struct ImportOverlay: View {
    let done: Int, total: Int
    var body: some View {
        ZStack {
            Ground().opacity(0.98)
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow("Reading tags")
                Text("\(done)")
                    .font(Face.display(108)).foregroundStyle(Ink.bone)
                    .padding(.horizontal, 20).padding(.vertical, 4)
                    .block("imp", skew: 14, stroke: 3)
                Text(total > 0 ? "OF \(total) FILES" : "SCANNING")
                    .font(Face.mono(11)).tracking(2).foregroundStyle(Ink.bone)
            }
        }
    }
}

// MARK: - Library

struct LibraryView: View {
    var topSignal: Int = 0
    @Environment(AppModel.self) private var app
    @State private var mode = 0
    @State private var filtering = false
    @State private var filter = ""
    @State private var sorting = false
    @FocusState private var filterFocused: Bool

    /// Plain-text narrowing of whatever list is on screen. Uses the same folded
    /// key as search, so accents and case are optional here too.
    private func keep(_ text: String) -> Bool {
        filter.isEmpty || SearchKey.fold(text).contains(SearchKey.fold(filter))
    }
    // The lists come pre-sorted from the model; filtering keeps that order, so
    // nothing here sorts on a redraw.
    private var albums: [Album] {
        filter.isEmpty ? app.sortedAlbums
            : app.sortedAlbums.filter { keep("\($0.title) \($0.artist)") }
    }
    private var artists: [Artist] {
        filter.isEmpty ? app.sortedArtists : app.sortedArtists.filter { keep($0.name) }
    }
    private var songs: [Track] {
        filter.isEmpty ? app.sortedTracks
            : app.sortedTracks.filter { keep($0.meta.searchKey) }
    }

    var body: some View {
        GeometryReader { screen in
            // Turn the phone sideways and the library becomes Cover Flow, the
            // way the iPod did it. Portrait is the list; landscape is the
            // covers themselves.
            if screen.size.width > screen.size.height * 1.15, !app.albums.isEmpty {
                CoverFlowView(albums: albums)
                    .transition(.opacity)
            } else {
                portrait
            }
        }
        .animation(.easeInOut(duration: 0.25), value: app.albums.count)
    }

    private var portrait: some View {
        NavigationStack {
            ZStack {
                Ground()
                ScrollViewReader { top in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Header(kicker: "Library", value: app.tracks.count.grouped, unit: "tracks")
                            .id("top")

                        HStack(spacing: 11) {
                            ActionBlock("SHUFFLE ALL", icon: "shuffle", seed: "sh1") {
                                app.shuffleEverything()
                            }
                            ActionBlock("ALBUMS", icon: "die.face.5.fill", seed: "sh2") {
                                app.shuffleAlbums()
                            }
                        }
                        .padding(.horizontal, 13).padding(.top, 14).padding(.bottom, 12)

                        // The filter replaces the mode row rather than stacking
                        // below it, so the list keeps its vertical space.
                        HStack(spacing: 8) {
                            if filtering {
                                HStack(spacing: 8) {
                                    Image(systemName: "line.3.horizontal.decrease")
                                        .font(.system(size: 12, weight: .black))
                                        .foregroundStyle(Ink.bone)
                                    TextField("", text: $filter, prompt:
                                        Text("FILTER \(["ALBUMS","ARTISTS","SONGS"][mode])")
                                            .foregroundColor(Ink.smoke))
                                        .focused($filterFocused)
                                        .textFieldStyle(.plain)
                                        .autocorrectionDisabled()
                                        .font(Face.display(17, .black))
                                        .foregroundStyle(Ink.bone)
                                    Text("\(mode == 0 ? albums.count : (mode == 1 ? artists.count : songs.count))")
                                        .font(Face.mono(10, .black))
                                        .foregroundStyle(Ink.black)
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(Ink.bone)
                                    Button {
                                        filter = ""; filtering = false; filterFocused = false
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 12, weight: .black))
                                            .foregroundStyle(Ink.bone)
                                    }
                                }
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .block("lib-filter", skew: 9, stroke: 2.5)
                            } else {
                                ModePicker(["Albums", "Artists", "Songs"], selection: $mode)
                                Button {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        sorting.toggle()
                                    }
                                } label: {
                                    Image(systemName: "arrow.up.arrow.down")
                                        .font(.system(size: 14, weight: .black))
                                        .foregroundStyle(sorting ? Ink.black : Ink.bone)
                                        .frame(width: 40, height: 38)
                                        .block("lib-sortbtn", skew: 6, stroke: 2.5,
                                               fill: sorting ? Ink.bone : Ink.black)
                                }
                                Button {
                                    filtering = true
                                    filterFocused = true
                                } label: {
                                    Image(systemName: "line.3.horizontal.decrease")
                                        .font(.system(size: 15, weight: .black))
                                        .foregroundStyle(Ink.black)
                                        .frame(width: 40, height: 38)
                                        .block("lib-filterbtn", skew: 6,
                                               stroke: 2.5, fill: Ink.bone)
                                }
                            }
                        }
                        .padding(.horizontal, 13).padding(.bottom, sorting ? 9 : 14)

                        if sorting {
                            SortRow(sorting: $sorting)
                                .padding(.horizontal, 13).padding(.bottom, 14)
                                .transition(.scale(scale: 0.94, anchor: .top)
                                    .combined(with: .opacity))
                        }

                        if mode == 0 {
                            ForEach(Array(albums.enumerated()), id: \.element.id) { i, a in
                                NavigationLink { AlbumView(album: a) } label: { AlbumRow(album: a) }
                                    .bare().riseIn(i)
                            }
                        } else if mode == 1 {
                            ForEach(Array(artists.enumerated()), id: \.element.id) { i, a in
                                NavigationLink { ArtistView(artist: a) } label: { ArtistRow(artist: a) }
                                    .bare().riseIn(i)
                            }
                        } else {
                            ForEach(Array(songs.enumerated()), id: \.element.id) { i, t in
                                TrackRow(track: t, index: nil, showArt: true) {
                                    app.startRadio(from: t)
                                }
                                .riseIn(i)
                            }
                        }
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
        }
    }
}

/// Primary action: black block, white outline, white type.
struct ActionBlock: View {
    let title: String
    var icon: String?
    var seed: String
    var invert: Bool = false
    let action: () -> Void

    init(_ title: String, icon: String? = nil, seed: String,
         invert: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.seed = seed
        self.invert = invert; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 13, weight: .black))
                }
                Text(title).font(Face.display(17, .black)).tracking(0.8)
            }
            .foregroundStyle(invert ? Ink.black : Ink.bone)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .block(seed, skew: 10, stroke: 2.5, fill: invert ? Ink.bone : Ink.black)
        }
    }
}

/// Segmented control as three blocks; the selected one inverts to white.
struct ModePicker: View {
    let options: [String]
    @Binding var selection: Int
    init(_ options: [String], selection: Binding<Int>) {
        self.options = options; self._selection = selection
    }
    var body: some View {
        HStack(spacing: 7) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, name in
                let on = i == selection
                Button { selection = i } label: {
                    Text(name.uppercased())
                        .font(Face.display(15, .black)).tracking(1)
                        .foregroundStyle(on ? Ink.black : Ink.bone)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .block("mode-\(name)", skew: 8, stroke: 2.5,
                               fill: on ? Ink.bone : Ink.black)
                }
            }
        }
    }
}

/// The four orderings, as blocks. Picking one closes the row, so it behaves
/// like a menu rather than a second permanent control bar.
struct SortRow: View {
    @Environment(AppModel.self) private var app
    @Binding var sorting: Bool

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 7) {
            Text("ORDER BY")
                .font(Face.mono(10, .black)).tracking(2.5)
                .foregroundStyle(Ink.smoke)
            HStack(spacing: 7) {
                ForEach(AppModel.SortMode.allCases, id: \.self) { m in
                    let on = app.sortMode == m
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            app.sortMode = m
                            sorting = false
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: m.icon)
                                .font(.system(size: 13, weight: .black))
                            Text(m.label)
                                .font(Face.mono(9, .black)).tracking(0.8)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .foregroundStyle(on ? Ink.black : Ink.bone)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .block("sort-\(m.rawValue)", skew: 7, stroke: 2.5,
                               fill: on ? Ink.bone : Ink.black)
                    }
                }
            }
        }
    }
}

struct AlbumRow: View {
    @Environment(AppModel.self) private var app
    let album: Album

    var body: some View {
        HStack(spacing: 0) {
            Cover(trackID: album.trackIDs.first, seed: album.id, size: 60)
                .padding(.trailing, 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(Face.display(20, .heavy))
                    .foregroundStyle(Ink.bone).lineLimit(1)
                HStack(spacing: 6) {
                    Text(album.artist).font(Face.body(11.5, .semibold))
                        .foregroundStyle(Ink.smoke).lineLimit(1)
                    Text("\(album.trackIDs.count)")
                        .font(Face.mono(9)).foregroundStyle(Ink.black)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Ink.bone)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 10).padding(.leading, 11).padding(.trailing, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .block(album.id, skew: 10, stroke: 2.5)
        // Rows stagger horizontally rather than sitting on a grid.
        .padding(.leading, 10 + CGFloat(Ink.stableHash(album.id) % 16))
        .padding(.trailing, 14).padding(.bottom, 9)
    }
}

struct ArtistRow: View {
    let artist: Artist
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Quad(seed: Int(Ink.stableHash(artist.key) % 400), skew: 7, jitter: 2)
                    .fill(Ink.tint(for: artist.key))
                Quad(seed: Int(Ink.stableHash(artist.key) % 400), skew: 7, jitter: 2)
                    .stroke(Ink.bone, lineWidth: 2.5)
                Text(String(artist.name.prefix(1)).uppercased())
                    .font(Face.display(28)).foregroundStyle(Ink.black)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 1) {
                Text(artist.name).font(Face.display(21, .heavy))
                    .foregroundStyle(Ink.bone).lineLimit(1)
                Text("\(artist.albumIDs.count) ALBUMS · \(artist.trackIDs.count) TRACKS")
                    .font(Face.mono(8.5)).tracking(1.2).foregroundStyle(Ink.smoke)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 10).padding(.leading, 11).padding(.trailing, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .block(artist.key, skew: 10, stroke: 2.5)
        .padding(.leading, 10 + CGFloat(Ink.stableHash(artist.key) % 16))
        .padding(.trailing, 14).padding(.bottom, 9)
    }
}

// MARK: - Album / Artist

struct AlbumView: View {
    @Environment(AppModel.self) private var app
    let album: Album
    @State private var artistTarget: Artist?
    @State private var zoomingCover = false

    var body: some View {
        ZStack {
            Ground()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        Button { zoomingCover = true } label: {
                            Cover(trackID: album.trackIDs.first, seed: album.id, size: 124)
                        }
                        .bare()
                        VStack(alignment: .leading, spacing: 5) {
                            Eyebrow("Album")
                            Text(album.title)
                                .font(Face.display(28))
                                .foregroundStyle(Ink.bone).lineLimit(3)
                                .padding(.horizontal, 11).padding(.vertical, 7)
                                .block("alb-\(album.id)", skew: 9, stroke: 2.5)
                            // The artist line is tappable here for the same
                            // reason it is on Now Playing: the album is how
                            // you land on an artist you want to explore.
                            Button {
                                artistTarget = app.artist(forKey: album.artistKey)
                            } label: {
                                HStack(spacing: 5) {
                                    Text(album.artist.uppercased())
                                        .font(Face.mono(10, .black)).tracking(1.6)
                                        .lineLimit(2)
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 8, weight: .black))
                                }
                                .foregroundStyle(Ink.black)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .block("alb-art-\(album.id)", skew: 5,
                                       stroke: 2, fill: Ink.bone)
                            }
                            .bare()
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 13).padding(.top, 10)

                    HStack(spacing: 11) {
                        ActionBlock("PLAY", icon: "play.fill", seed: "ap", invert: true) {
                            app.playAlbum(album)
                        }
                        ActionBlock("SHUFFLE", icon: "shuffle", seed: "as") {
                            var q = PlayQueue()
                            q.loadShuffled(album.trackIDs, origin: .album(album.title))
                            app.player.play(queue: q)
                        }
                    }
                    .padding(.horizontal, 13).padding(.vertical, 14)

                    // R4.1 — tapping a track continues through the album.
                    LazyVStack(spacing: 7) {
                        ForEach(Array(album.trackIDs.enumerated()), id: \.element) { i, id in
                            if let t = app.track(id) {
                                TrackRow(track: t, index: t.meta.trackNumber ?? i + 1) {
                                    app.playAlbum(album, startingAt: id)
                                }
                                .riseIn(i)
                            }
                        }
                    }
                }
                .padding(.bottom, 130)
            }
        }
        .buttonStyle(BareButton())
        .inlineTitle()
        .navigationDestination(item: $artistTarget) { a in ArtistView(artist: a) }
        .fullScreen(isPresented: $zoomingCover) {
            CoverZoomView(trackID: album.trackIDs.first, seed: album.id)
                .environment(app)
        }
    }
}

struct ArtistView: View {
    @Environment(AppModel.self) private var app
    let artist: Artist

    var body: some View {
        ZStack {
            Ground()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Eyebrow("Artist").rotationEffect(.degrees(-2))
                            .offset(x: 6, y: 7).zIndex(1)
                        Text(artist.name)
                            .font(Face.display(40))
                            .foregroundStyle(Ink.bone).lineLimit(2)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .block("art-\(artist.key)", skew: 13, stroke: 3)
                    }
                    .padding(.leading, 12).padding(.top, 8)

                    Text("\(artist.trackIDs.count) TRACKS · \(artist.albumIDs.count) ALBUMS")
                        .font(Face.mono(10)).tracking(1.6).foregroundStyle(Ink.bone)
                        .padding(.leading, 18).padding(.top, 10)

                    ActionBlock("PLAY ALL", icon: "play.fill", seed: "pa", invert: true) {
                        app.playArtist(artist)
                    }
                    .padding(.horizontal, 13).padding(.vertical, 14)

                    ForEach(Array(app.albums.filter { artist.albumIDs.contains($0.id) }
                        .enumerated()), id: \.element.id) { i, a in
                        NavigationLink { AlbumView(album: a) } label: { AlbumRow(album: a) }
                            .bare().riseIn(i)
                    }
                }
                .padding(.bottom, 130)
            }
        }
        .buttonStyle(BareButton())
        .inlineTitle()
    }
}

// MARK: - Rows

struct TrackRow: View {
    @Environment(AppModel.self) private var app
    let track: Track
    var index: Int?
    var showArt = false
    let action: () -> Void

    private var isCurrent: Bool { app.player.nowPlaying?.id == track.id }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let i = index {
                    Text("\(i)")
                        .font(Face.mono(11, .black))
                        .foregroundStyle(isCurrent ? Ink.black : Ink.bone)
                        .frame(width: 24, alignment: .trailing)
                } else if showArt {
                    Cover(trackID: track.id, seed: track.meta.album, size: 40)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(track.meta.title)
                        .font(Face.body(14.5, .bold))
                        .foregroundStyle(isCurrent ? Ink.black : Ink.bone)
                        .lineLimit(1)
                    Text(track.meta.artist)
                        .font(Face.body(11, .medium))
                        .foregroundStyle(isCurrent ? Ink.ash : Ink.smoke).lineLimit(1)
                }
                Spacer(minLength: 6)
                if !track.isAnalysed {
                    Image(systemName: "waveform.slash")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isCurrent ? Ink.ash : Ink.smoke)
                }
                Text(fmt(track.meta.duration))
                    .font(Face.mono(9.5))
                    .foregroundStyle(isCurrent ? Ink.ash : Ink.smoke)
            }
            .padding(.horizontal, 13).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The playing row inverts to white, the way a selected menu item does.
            .block(track.path, skew: 9, stroke: 2.5,
                   fill: isCurrent ? Ink.bone : Ink.black)
            .padding(.leading, 10 + CGFloat(Ink.stableHash(track.path) % 14))
            .padding(.trailing, 14)
            .contentShape(Rectangle())
        }
        // R3.1 — long press for queue actions and navigation
        .contextMenu {
            Button { app.player.playNext([track.id]) } label: {
                Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button { app.player.addToQueue([track.id]) } label: {
                Label("Add to queue", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            Divider()
            Button { app.startRadio(from: track, mode: .similar) } label: {
                Label("Radio · similar", systemImage: "dot.radiowaves.left.and.right")
            }
            Button { app.startRadio(from: track, mode: .continuous) } label: {
                Label("Radio · continuous", systemImage: "shuffle.circle")
            }
            Divider()
            Button { app.showArtist(of: track) } label: {
                Label("Go to artist", systemImage: "person.fill")
            }
            Button { app.showAlbum(of: track) } label: {
                Label("Go to album", systemImage: "square.stack.fill")
            }
        }
    }

    private func fmt(_ s: Double) -> String {
        guard s > 0 else { return "--:--" }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

/// Art in a white-outlined frame with a flat colour behind it, as the game
/// frames its portraits.
struct Cover: View {
    let trackID: UUID?
    let seed: String
    var size: CGFloat = 52
    @Environment(AppModel.self) private var app
    @State private var image: PlatformImage?

    var body: some View {
        let shape = Quad(seed: Int(Ink.stableHash(seed) % 601), skew: size * 0.07, jitter: 2)
        ZStack {
            if let img = image {
                Image(platform: img).resizable().scaledToFill()
            } else {
                Ink.tint(for: seed)
                Image(systemName: "waveform")
                    .font(.system(size: size * 0.32, weight: .black))
                    .foregroundStyle(Ink.black)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.stroke(Ink.bone, lineWidth: size > 80 ? 3 : 2.5))
        .rotationEffect(.degrees(Ink.lean(seed, max: 2.4)))
        .task(id: trackID) {
            guard let id = trackID, let t = app.track(id) else { image = nil; return }
            if let hit = Artwork.cached(for: t) { image = hit; return }
            image = await Artwork.load(for: t)
        }
    }
}
