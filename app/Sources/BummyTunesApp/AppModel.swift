import BummyTunesCore
import Foundation
import Observation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Application state. One owner for the library, the player and the analysis job.
@Observable
@MainActor
public final class AppModel {

    public let store = LibraryStore()
    public let player = Player()
    public let prefs = Prefs()

    public var tracks: [Track] = []
    public var albums: [Album] = []
    public var artists: [Artist] = []
    public var mapPoints: [UUID: CGPoint] = [:]
    public var mapVariance: (Float, Float) = (0, 0)

    public var analysis = AnalysisJob.Progress(done: 0, total: 0, failed: 0,
                                               currentTitle: nil, isRunning: false)
    public var hasLibrary: Bool { !tracks.isEmpty }

    /// Counted live during a run.
    ///
    /// `tracks` is a cached snapshot that only changes on `refresh()`, and
    /// refresh recomputes albums, artists and the map projection — far too
    /// expensive to do per track on a library this size. So during analysis the
    /// count comes from the job's own progress instead, and the snapshot is
    /// rebuilt once at the end.
    public var analysedCount: Int {
        analysis.isRunning ? baselineAnalysed + analysis.done - analysis.failed
                           : cachedAnalysed
    }
    private var cachedAnalysed = 0
    private var baselineAnalysed = 0
    public var importing = false
    public var importProgress: (Int, Int) = (0, 0)

    private var job: AnalysisJob?

    // MARK: - Paths

    private var docs: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    /// Everything persistent lives here. LiveContainer keeps this container
    /// across a bundle replacement, so a new IPA finds the existing library.
    private var storeDir: URL { docs }
    private var modelPath: String {
        Bundle.main.path(forResource: "musicnn_embedding", ofType: "onnx")
            ?? docs.appendingPathComponent("musicnn_embedding.onnx").path
    }

    public init() {
        player.resolve = { [weak self] id in self?.store.track(id) }
        sortMode = SortMode(rawValue:
            UserDefaults.standard.string(forKey: "library.sort") ?? "") ?? .alphabetical
        loadLibrary()
    }

    // MARK: - Library

    /// Set when a load had to fall back, so the UI can say so.
    public var recovery: String?
    /// Embeddings that outlived a broken metadata file, waiting to be re-attached.
    private var orphanEmbeddings: [String: [Float]] = [:]

    /// Bookmarks for every folder the user has imported.
    private var rootBookmarks: [Data] {
        get { (UserDefaults.standard.array(forKey: "library.roots") as? [Data]) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "library.roots") }
    }

    /// Reopen every imported folder's security scope. Called at launch and
    /// whenever the app returns to the foreground, since scopes do not always
    /// survive being backgrounded.
    public func openLibraryAccess() {
        LibraryImporter.RootAccess.shared.closeAll()
        _ = LibraryImporter.RootAccess.shared.open(bookmarks: rootBookmarks)
        // Folders that read as empty before the scope was open get another go.
        Artwork.forgetMisses()
    }

    public func loadLibrary() {
        openLibraryAccess()
        switch store.load(from: storeDir) {
        case .loaded(let tracks, let version):
            if version < Store.metadataVersion {
                // Old file read fine; rewrite it in the current format.
                recovery = "Library upgraded from format v\(version)."
                persist()
            }
            _ = tracks
        case .recovered(let embeddings, let reason):
            orphanEmbeddings = embeddings
            recovery = "\(reason). Re-add your folder and the analysis is kept."
        case .empty:
            break
        }
        refresh()
    }

    /// Write the library out.
    ///
    /// Encoding thousands of tracks is not cheap, and doing it on the main actor
    /// during a large import is exactly when iOS is most likely to kill the app
    /// — which would lose the very write meant to protect the work. So it runs
    /// off the main thread, and overlapping calls collapse into one.
    /// Set whenever something worth writing changes. Saving a large library is
    /// expensive enough that doing it when nothing changed is worth avoiding.
    public private(set) var dirty = false
    public func markDirty() { dirty = true }

    public func persist() {
        dirty = false
        guard !saving else { saveAgain = true; return }
        saving = true
        let snapshot = store.tracks
        let dir = storeDir
        Task.detached(priority: .utility) {
            var failure: String?
            do { try Store.save(snapshot, to: dir) }
            catch { failure = String(describing: error).prefix(140).description }
            await MainActor.run { [failure] in
                self.saving = false
                self.lastSaveError = failure
                if self.saveAgain { self.saveAgain = false; self.persist() }
            }
        }
    }
    /// Append the vectors produced since the last flush.
    ///
    /// Falls back to writing the whole sidecar when there is no usable file to
    /// append to, which is only ever the first flush of a fresh library.
    public func appendEmbeddings(_ pairs: [(path: String, vec: [Float])]) {
        guard !pairs.isEmpty else { return }
        let dir = storeDir
        let snapshot = store.tracks
        Task.detached(priority: .utility) {
            if !Store.appendEmbeddings(pairs, toDirectory: dir) {
                try? Store.saveEmbeddings(snapshot, to: dir)
            }
        }
    }

    /// Write the embedding sidecar only. Called between analysed tracks.
    public func persistEmbeddings() {
        guard !savingVectors else { return }
        savingVectors = true
        let snapshot = store.tracks
        let dir = storeDir
        Task.detached(priority: .utility) {
            try? Store.saveEmbeddings(snapshot, to: dir)
            await MainActor.run { self.savingVectors = false }
        }
    }
    private var savingVectors = false

    private var saving = false
    private var saveAgain = false
    public var lastSaveError: String?

    /// Blocking save, for the moment the app goes to the background and may not
    /// get another chance to finish an async one.
    /// Blocking save, for the moment the app goes to the background and may not
    /// get another chance to finish an async one.
    ///
    /// Guarded two ways. It does nothing when nothing has changed, which is the
    /// common case. And it asks the system for time first, because on a large
    /// library this write can outlast the few seconds a backgrounding app is
    /// given, and being killed mid-save is the one outcome worth engineering
    /// against.
    public func persistNow() {
        guard dirty || lastSaveError != nil else { return }
        #if canImport(UIKit)
        var assertion = UIBackgroundTaskIdentifier.invalid
        assertion = UIApplication.shared.beginBackgroundTask(withName: "bummytunes.save") {
            UIApplication.shared.endBackgroundTask(assertion)
            assertion = .invalid
        }
        defer {
            if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) }
        }
        #endif
        do { try store.save(to: storeDir); lastSaveError = nil; dirty = false }
        catch { lastSaveError = String(describing: error).prefix(140).description }
    }

    public func diagnose() -> Store.Diagnosis { Store.diagnose(storeDir) }

    /// How the library lists are ordered.
    public enum SortMode: String, CaseIterable {
        case alphabetical, recentlyAdded, recentlyPlayed, random
        public var label: String {
            switch self {
            case .alphabetical: return "A–Z"
            case .recentlyAdded: return "ADDED"
            case .recentlyPlayed: return "PLAYED"
            case .random: return "RANDOM"
            }
        }
        public var icon: String {
            switch self {
            case .alphabetical: return "textformat.abc"
            case .recentlyAdded: return "clock.badge.checkmark"
            case .recentlyPlayed: return "arrow.counterclockwise"
            case .random: return "dice"
            }
        }
    }
    public var sortMode: SortMode = .alphabetical {
        didSet {
            UserDefaults.standard.set(sortMode.rawValue, forKey: "library.sort")
            // A new shuffle each time random is chosen, so it is actually random
            // rather than one fixed order for the life of the app.
            if sortMode == .random { randomSalt = UUID() }
            resort()
        }
    }

    // Sorted once and kept. These used to be computed inside the library view,
    // which re-ran a full `localizedStandardCompare` sort of every track on
    // every redraw, twice: once for the row count and once for the rows.
    // Filtering a sorted array preserves its order, so the view only filters.
    public private(set) var sortedTracks: [Track] = []
    public private(set) var sortedAlbums: [Album] = []
    public private(set) var sortedArtists: [Artist] = []

    public func resort() { rebuildLists(store.tracks) }

    /// Regroup and re-sort the library off the main thread.
    ///
    /// Grouping several thousand tracks into albums and artists and then
    /// sorting all three lists with locale-aware comparison is a second or more
    /// of arithmetic. On the main actor that second is a frozen app, which is
    /// what it was doing after an import and at the end of an analysis run.
    private var rebuilding = false
    private var rebuildAgain = false

    private func rebuildLists(_ snapshot: [Track]) {
        guard !rebuilding else { rebuildAgain = true; return }
        rebuilding = true
        let mode = sortMode
        let salt = randomSalt.hashValue
        let store = self.store
        Task.detached(priority: .userInitiated) {
            let albs = store.albums()
            let arts = store.artists()
            let ordered = AppModel.order(tracks: snapshot, albums: albs, artists: arts,
                                         mode: mode, salt: salt)
            await MainActor.run {
                self.albums = albs
                self.artists = arts
                self.sortedTracks = ordered.tracks
                self.sortedAlbums = ordered.albums
                self.sortedArtists = ordered.artists
                self.rebuilding = false
                if self.rebuildAgain {
                    self.rebuildAgain = false
                    self.rebuildLists(store.tracks)
                }
            }
        }
    }

    /// Pure ordering, so it can run anywhere.
    nonisolated private static func order(tracks: [Track], albums: [Album],
                                          artists: [Artist], mode: SortMode, salt: Int)
        -> (tracks: [Track], albums: [Album], artists: [Artist]) {

        // Newest stamp per track, for the two date orderings.
        var added: [UUID: Date] = [:], played: [UUID: Date] = [:]
        if mode == .recentlyAdded || mode == .recentlyPlayed {
            for t in tracks {
                if let d = t.addedAt { added[t.id] = d }
                if let d = t.lastPlayed { played[t.id] = d }
            }
        }
        func stamp(_ ids: [UUID]) -> Date {
            let table = mode == .recentlyAdded ? added : played
            return ids.compactMap { table[$0] }.max() ?? .distantPast
        }

        switch mode {
        case .alphabetical:
            return (tracks.sorted {
                        $0.meta.title.localizedStandardCompare($1.meta.title) == .orderedAscending
                    },
                    albums.sorted {
                        $0.title.localizedStandardCompare($1.title) == .orderedAscending
                    },
                    artists.sorted {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    })
        case .random:
            return (tracks.sorted { abs($0.id.hashValue ^ salt) < abs($1.id.hashValue ^ salt) },
                    albums.sorted { abs($0.id.hashValue ^ salt) < abs($1.id.hashValue ^ salt) },
                    artists.sorted { abs($0.id.hashValue ^ salt) < abs($1.id.hashValue ^ salt) })
        default:
            let byDate: (Track, Track) -> Bool = { a, b in
                let x = (mode == .recentlyAdded ? a.addedAt : a.lastPlayed) ?? .distantPast
                let y = (mode == .recentlyAdded ? b.addedAt : b.lastPlayed) ?? .distantPast
                return x == y ? a.meta.title < b.meta.title : x > y
            }
            return (tracks.sorted(by: byDate),
                    albums.sorted { stamp($0.trackIDs) > stamp($1.trackIDs) },
                    artists.sorted { stamp($0.trackIDs) > stamp($1.trackIDs) })
        }
    }
    private var randomSalt = UUID()

    private var warmingArtwork = false

    /// Fill the artwork cache in the background.
    ///
    /// Covers otherwise only load for rows you actually scroll past, so a list
    /// you have not visited still shows placeholders. This walks the library at
    /// low priority and pauses between tracks, so it fills in while you use the
    /// app rather than competing with it. Anything already cached is skipped,
    /// which means after the first pass later launches cost almost nothing.
    public func warmArtwork() {
        guard !warmingArtwork, !tracks.isEmpty else { return }
        // Analysis holds tens of megabytes per track. Filling an image cache
        // alongside it is how a long run gets the app killed.
        guard !analysis.isRunning else { return }
        warmingArtwork = true

        let albumFirsts = albums.compactMap(\.trackIDs.first)
        let all = tracks

        Task { @MainActor in
            defer { warmingArtwork = false }

            // Work out what is left to do off the main thread. This asks the
            // file system about every track, and on a library of thousands
            // that is thousands of stat calls. Doing it in the loop below, with
            // a `continue` that skipped the pause, meant the whole pass ran
            // without ever yielding: the app froze until it finished, rows
            // stayed invisible mid-animation, and playback controls did
            // nothing because the main thread was busy.
            let todo: [UUID] = await Task.detached(priority: .utility) {
                let byID = Dictionary(all.map { ($0.id, $0) },
                                      uniquingKeysWith: { a, _ in a })
                var ordered: [Track] = albumFirsts.compactMap { byID[$0] }
                ordered += all
                var seen = Set<UUID>()
                var out: [UUID] = []
                for t in ordered where seen.insert(t.id).inserted {
                    if Artwork.isCachedOnDisk(t) { continue }
                    out.append(t.id)
                }
                return out
            }.value

            for id in todo {
                // Unconditional, so the loop can never run without giving the
                // main thread back regardless of what happens below.
                try? await Task.sleep(nanoseconds: 30_000_000)
                if self.analysis.isRunning { break }
                guard let t = store.track(id), Artwork.cached(for: t) == nil else { continue }
                _ = await Artwork.load(for: t)
            }
        }
    }

    private var lastPlaySave = Date.distantPast
    /// Record a play. The write is rate limited: the whole library is one JSON
    /// file, and saving it on every fifth track meant rewriting megabytes while
    /// music was playing. Backgrounding the app flushes it regardless.
    public func recordPlay(_ track: Track) {
        store.markPlayed(track.id)
        dirty = true
        if Date().timeIntervalSince(lastPlaySave) > 180 {
            lastPlaySave = Date()
            persist()
        }
    }

    private func refresh() {
        dirty = true
        let snapshot = store.tracks
        tracks = snapshot
        cachedAnalysed = snapshot.filter(\.isAnalysed).count
        rebuildLists(snapshot)
        recomputeMap()
    }

    /// Import a folder the user picked (R8).
    /// Look at the library folders again and pick up anything new.
    ///
    /// The app imported a folder once and then never looked at it again, so
    /// music dropped into the library after that was simply invisible. This
    /// walks each folder that was imported, skips every path already known
    /// before reading a single tag, and adds whatever is left.
    public private(set) var rescanning = false
    public private(set) var lastRescanAdded = 0
    /// What the last scan did, so the button can say so. Finding nothing and
    /// never running look identical otherwise.
    public private(set) var rescanStatus: String?
    /// True when scanning found no folder it was allowed to read, which the
    /// picker is the only cure for.
    public private(set) var needsFolderAgain = false
    private var lastRescan = Date.distantPast

    /// Look at the library folders again and pick up anything new.
    ///
    /// All of the work happens off the main thread. Resolving a bookmark is not
    /// cheap, there are thousands of them, and doing that on the main actor is
    /// how tapping a button ends in the system killing the app for not
    /// responding. The scanning below is bounded for the same reason.
    @discardableResult
    public func rescanLibrary(force: Bool = false) async -> Int {
        guard !rescanning, !importing else { return 0 }
        // Throttled when called automatically; the button in Settings forces it.
        if !force, Date().timeIntervalSince(lastRescan) < 300 { return 0 }
        rescanning = true
        lastRescan = Date()
        defer { rescanning = false }

        let snapshot = store.tracks
        let roots = rootBookmarks
        let outcome = await Task.detached(priority: .userInitiated) {
            await AppModel.scan(snapshot: snapshot, rootBookmarks: roots)
        }.value

        var repaired = 0
        if !outcome.fixes.isEmpty {
            repaired = store.repairPaths(outcome.fixes)
            if repaired > 0 { Artwork.forgetMisses() }
        }
        for bm in outcome.newRoots where !rootBookmarks.contains(bm) {
            rootBookmarks.append(bm)
        }

        lastRescanAdded = outcome.tracks.count
        let note = repaired > 0 ? ", fixed \(repaired.grouped) paths" : ""
        guard !outcome.tracks.isEmpty else {
            // Nothing could be listed. A bookmark to a file grants that file
            // and nothing else, so without a bookmark to the folder itself
            // there is no way to see what is in it. Only the picker can hand
            // one back, and preferences are where it was lost.
            needsFolderAgain = outcome.walked == 0
            rescanStatus = outcome.walked == 0
                ? "Pick your library folder below to let it scan\(note)"
                : "Scanned \(outcome.walked.grouped) files, nothing new\(note)"
            if repaired > 0 { persist(); refresh() }
            return 0
        }
        needsFolderAgain = false
        rescanStatus = "Added \(outcome.tracks.count.grouped)\(note)"

        var merged = store.tracks
        merged.append(contentsOf: outcome.tracks)
        store.replaceAll(merged)
        persist()
        refresh()
        if analysisWanted { resumeAnalysisIfWanted() }
        return outcome.tracks.count
    }

    struct ScanOutcome: Sendable {
        var tracks: [Track] = []
        var walked = 0
        /// Tracks whose bookmark resolves somewhere other than their stored path.
        var fixes: [UUID: String] = [:]
        var newRoots: [Data] = []
    }

    /// The whole scan, with nothing main-actor about it.
    nonisolated static func scan(snapshot: [Track],
                                 rootBookmarks: [Data]) async -> ScanOutcome {
        var out = ScanOutcome()
        guard !snapshot.isEmpty || !rootBookmarks.isEmpty else { return out }

        // Anything already in the library, by stored path and by a key made of
        // the album folder and file name, so a library whose container was
        // renamed is still recognised instead of imported twice.
        var known = Set(snapshot.map(\.path))
        for t in snapshot { known.insert(LibraryImporter.tailKey(forStoredPath: t.path)) }

        // Where the files actually are, according to their bookmarks. This also
        // produces the corrections for any stored path that has gone stale.
        var dirToBookmark: [String: Data] = [:]
        var order: [String] = []
        autoreleasepool {
            for t in snapshot {
                guard let data = t.bookmark else { continue }
                var stale = false
                guard let u = try? URL(resolvingBookmarkData: data, options: [],
                                       relativeTo: nil, bookmarkDataIsStale: &stale)
                else { continue }
                let actual = Track.portablePath(for: u)
                if actual != t.path { out.fixes[t.id] = actual }
                let dir = (u.hasDirectoryPath ? u : u.deletingLastPathComponent())
                    .standardizedFileURL.path
                if dirToBookmark[dir] == nil {
                    dirToBookmark[dir] = data
                    order.append(dir)
                }
            }
        }
        if dirToBookmark.isEmpty {
            for t in snapshot {
                let dir = t.url.deletingLastPathComponent().standardizedFileURL.path
                if dirToBookmark[dir] == nil {
                    dirToBookmark[dir] = nil
                    order.append(dir)
                }
            }
        }

        var found: [Track] = []

        // 1. Folders the user picked, which carry their own bookmark.
        for data in rootBookmarks {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [],
                                     relativeTo: nil, bookmarkDataIsStale: &stale)
            else { continue }
            let r = await scoped(url, bookmark: data, skipping: known)
            out.walked += r.scanned
            found.append(contentsOf: r.tracks)
        }

        // 2. The shallowest folder every track shares.
        if out.walked == 0, let root = commonAncestor(of: order) {
            let inside = order.first { $0.hasPrefix(root) }.flatMap { dirToBookmark[$0] }
            let r = await scoped(URL(fileURLWithPath: root),
                                 bookmark: inside, skipping: known)
            out.walked += r.scanned
            found.append(contentsOf: r.tracks)
            if r.scanned > 0,
               let bm = try? URL(fileURLWithPath: root)
                   .bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                 relativeTo: nil) {
                out.newRoots.append(bm)
            }
        }

        // 3. Failing that, the folders the library actually came from, one
        //    level up so a new album under a known artist is found. Bounded:
        //    a library of thousands has hundreds of these and each walk is
        //    recursive, so this is a fallback, not a sweep.
        if out.walked == 0 {
            var parents: [String] = []
            var seenParent = Set<String>()
            for dir in order {
                let parent = (dir as NSString).deletingLastPathComponent
                guard parent.count > 1, seenParent.insert(parent).inserted else { continue }
                parents.append(parent)
                if parents.count >= 60 { break }
            }
            for parent in parents {
                let bm = order.first { $0.hasPrefix(parent) }.flatMap { dirToBookmark[$0] }
                let r = await scoped(URL(fileURLWithPath: parent),
                                     bookmark: bm, skipping: known)
                out.walked += r.scanned
                found.append(contentsOf: r.tracks)
            }
        }

        // 4. The app's own folder, which needs no bookmark at all.
        let docs = await LibraryImporter.importDocumentsFolder(skipping: known)
        out.walked += docs.scanned
        found.append(contentsOf: docs.tracks)

        var seen = known
        out.tracks = found.filter {
            seen.insert($0.path).inserted
                && seen.insert(LibraryImporter.tailKey(forStoredPath: $0.path)).inserted
        }
        return out
    }

    /// Walk a folder with a security scope opened from a track inside it.
    ///
    /// A file bookmark is what the library has; folders are read by opening the
    /// scope it grants and listing from there, the same route the artwork
    /// lookup already takes successfully.
    nonisolated private static func scoped(_ folder: URL, bookmark: Data?,
                                           skipping: Set<String>)
        async -> LibraryImporter.ImportResult {
        var open: URL?
        if let bookmark {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: bookmark, options: [],
                                relativeTo: nil, bookmarkDataIsStale: &stale) {
                let target = u.hasDirectoryPath ? u : u.deletingLastPathComponent()
                if target.startAccessingSecurityScopedResource() { open = target }
            }
        }
        defer { open?.stopAccessingSecurityScopedResource() }
        return await LibraryImporter.importFolder(folder, skipping: skipping)
    }

    /// Longest path every one of these folders shares, or nil when they have
    /// nothing meaningful in common.
    nonisolated private static func commonAncestor(of paths: [String]) -> String? {
        guard var shared = paths.first.map({ ($0 as NSString).pathComponents }) else {
            return nil
        }
        for p in paths.dropFirst() {
            let other = (p as NSString).pathComponents
            var i = 0
            while i < shared.count, i < other.count, shared[i] == other[i] { i += 1 }
            shared = Array(shared.prefix(i))
            if shared.count <= 1 { return nil }
        }
        guard shared.count >= 2 else { return nil }
        return NSString.path(withComponents: shared)
    }

    public func importFolder(_ url: URL) async {
        importing = true
        importProgress = (0, 0)
        // Skip what is already here, by path and by album folder plus file
        // name. Re-picking the same folder to restore access is then a
        // directory walk rather than a full re-read of every tag, and it
        // cannot import the library a second time.
        var known = Set(store.tracks.map(\.path))
        for t in store.tracks { known.insert(LibraryImporter.tailKey(forStoredPath: t.path)) }
        let result = await LibraryImporter.importFolder(url, skipping: known) {
            [weak self] done, total in
            Task { @MainActor in self?.importProgress = (done, total) }
        }
        var merged = store.tracks
        merged.append(contentsOf: result.tracks.filter {
            !known.contains($0.path)
                && !known.contains(LibraryImporter.tailKey(forStoredPath: $0.path))
        })
        needsFolderAgain = false
        rescanStatus = result.tracks.isEmpty
            ? "Folder restored, nothing new"
            : "Added \(result.tracks.count.grouped)"
        if let root = result.rootBookmark, !rootBookmarks.contains(root) {
            rootBookmarks.append(root)
            openLibraryAccess()
        }
        store.replaceAll(merged)
        // Anything that survived a broken metadata file gets its vector back.
        if !orphanEmbeddings.isEmpty {
            store.attach(embeddings: orphanEmbeddings)
            orphanEmbeddings.removeAll()
            recovery = nil
        }
        persist()
        refresh()
        importing = false
    }

    /// Audio sitting in the app's own Documents folder, for the no-picker path.
    public var documentsAudioCount: Int { LibraryImporter.documentsAudioCount() }

    /// Import without the system picker. See LibraryImporter.importDocumentsFolder.
    public func importDocumentsFolder() async {
        importing = true
        importProgress = (0, 0)
        let result = await LibraryImporter.importDocumentsFolder { [weak self] done, total in
            Task { @MainActor in self?.importProgress = (done, total) }
        }
        var merged = store.tracks
        let known = Set(merged.map(\.path))
        merged.append(contentsOf: result.tracks.filter { !known.contains($0.path) })
        store.replaceAll(merged)
        if !orphanEmbeddings.isEmpty {
            store.attach(embeddings: orphanEmbeddings)
            orphanEmbeddings.removeAll()
            recovery = nil
        }
        persist()
        refresh()
        importing = false
    }

    // MARK: - Analysis (R6)

    /// Whether the user has asked for the library to be analysed.
    ///
    /// Persisted, because a long run gets interrupted: the app is killed
    /// overnight, or the phone reboots. Without this, analysis stopped where it
    /// was and waited for someone to press the button again, which is exactly
    /// what happened at four thousand tracks.
    public var analysisWanted: Bool {
        get { UserDefaults.standard.bool(forKey: "analysis.wanted") }
        set { UserDefaults.standard.set(newValue, forKey: "analysis.wanted") }
    }

    /// Pick an interrupted run back up on launch.
    public func resumeAnalysisIfWanted() {
        guard analysisWanted, !analysis.isRunning else { return }
        guard analysedCount < tracks.count else { analysisWanted = false; return }
        startAnalysis(trigger: .duringPlayback)
    }

    public func startAnalysis(trigger: AnalysisJob.Trigger = .foreground) {
        analysisWanted = true
        let j = job ?? AnalysisJob(modelPath: modelPath, store: store,
                                   persist: { [weak self] in
                                       Task { @MainActor in self?.persist() }
                                   },
                                   persistVectors: { [weak self] pairs in
                                       Task { @MainActor in self?.appendEmbeddings(pairs) }
                                   })
        job = j
        baselineAnalysed = cachedAnalysed
        Task {
            await j.setProgressHandler { [weak self] p in
                Task { @MainActor in
                    guard let self else { return }
                    self.analysis = p
                    if !p.isRunning {
                        // Finished for real, rather than interrupted.
                        if self.analysedCount >= self.tracks.count {
                            self.analysisWanted = false
                        }
                        // One full rebuild at the end, not per track.
                        self.refresh()
                    }
                }
            }
            await j.run(trigger: trigger)
        }
    }

    public func cancelAnalysis() {
        analysisWanted = false
        Task { await job?.cancel() }
    }

    // MARK: - Map (R7.1)

    /// Genre (or cluster) each track belongs to, for map colouring.
    public var mapGroups: [UUID: Int] = [:]
    public var mapGroupNames: [String] = []
    public var mapGroupsFromTags = false

    /// Flat, high-contrast hues that read on any ground colour.
    /// Sixteen, to match the sixteen groups the map can produce. With twelve
    /// the last few genres wrapped around and reused a colour already on the
    /// legend, which makes two unrelated groups look like one.
    public static let groupColors: [Color] = [
        Color(hex: 0x3AC8F0), Color(hex: 0xF5E63B), Color(hex: 0xFF7BC3),
        Color(hex: 0x6BE37A), Color(hex: 0xFF9E3D), Color(hex: 0xB98BFF),
        Color(hex: 0xFF5C5C), Color(hex: 0x4DF0C4), Color(hex: 0xFFD9A0),
        Color(hex: 0x9BE0FF), Color(hex: 0xE0FF6B), Color(hex: 0xFFFFFF),
        Color(hex: 0xC97BFF), Color(hex: 0x7DFF3D), Color(hex: 0xFF8A6B),
        Color(hex: 0x6BA8FF),
    ]
    /// Which group index holds the untagged tracks, drawn dim.
    public private(set) var mapUntaggedIndex: Int?

    public func color(forGroup i: Int?) -> Color {
        guard let i else { return Color(hex: 0x8A8A96) }
        // Untagged tracks recede. They are usually the largest group in a real
        // library, and giving them a bright colour makes the whole map look
        // like one genre while the real ones disappear into it.
        if i == mapUntaggedIndex { return Color(hex: 0x5A5A66) }
        return Self.groupColors[i % Self.groupColors.count]
    }

    private var mapping = false

    /// Rebuild the map.
    ///
    /// Off the main thread: this is a principal component analysis plus k-means
    /// over every embedding in the library, which at several thousand tracks is
    /// seconds of arithmetic, and it used to run on the main actor where those
    /// seconds are a frozen app.
    public func recomputeMap() {
        guard !mapping else { return }
        let snapshot = store.tracks
        guard !snapshot.isEmpty else {
            mapPoints = [:]; mapGroups = [:]; mapGroupNames = []
            return
        }
        mapping = true
        Task.detached(priority: .utility) {
            let g = MusicMap.grouping(snapshot)
            let projection = MusicMap.project(snapshot)
            var pts: [UUID: CGPoint] = [:]
            if let r = projection {
                pts.reserveCapacity(r.points.count)
                for p in r.points { pts[p.id] = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)) }
            }
            let variance = projection?.variance ?? (0, 0)
            await MainActor.run {
                self.mapGroups = g.group
                self.mapGroupNames = g.names
                self.mapGroupsFromTags = g.fromTags
                self.mapUntaggedIndex = g.untaggedIndex
                self.mapPoints = pts
                self.mapVariance = variance
                self.mapping = false
            }
        }
    }

    // MARK: - Playback intents

    /// R4.1 — tap inside an album: play it, then the rest of that album.
    public func playAlbum(_ album: Album, startingAt id: UUID? = nil) {
        var q = PlayQueue()
        q.load(album.trackIDs, startAt: id, origin: .album(album.title))
        player.play(queue: q)
    }

    public func playArtist(_ artist: Artist, startingAt id: UUID? = nil) {
        var q = PlayQueue()
        q.load(artist.trackIDs, startAt: id, origin: .artist(artist.name))
        player.play(queue: q)
    }

    /// Which radio behaviour new radios use. Persisted across launches.
    public var radioMode: PlayQueue.RadioMode {
        get {
            PlayQueue.RadioMode(rawValue:
                UserDefaults.standard.string(forKey: "radioMode") ?? "") ?? .similar
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "radioMode") }
    }

    /// R4.2 — tap from search: start a radio seeded on that track.
    public func startRadio(from track: Track, mode: PlayQueue.RadioMode? = nil) {
        let mode = mode ?? radioMode
        guard track.isAnalysed else {
            var q = PlayQueue()
            q.load([track.id], origin: .none)
            player.play(queue: q)
            return
        }
        // The two modes differ from the first track, not just eventually.
        //
        // Similar stays close: a long queue of the nearest tracks, with a
        // normal cap so an album or an artist can appear a few times.
        // Continuous is meant to travel, so it starts short and takes at most
        // one track per artist, which walks it away from the seed immediately
        // instead of replaying the record it started on.
        let ids: [UUID]
        if mode == .similar {
            ids = Radio.neighbours(of: track, in: store.tracks,
                                   count: prefs.radioLength,
                                   maxPerAlbum: prefs.maxPerAlbum,
                                   maxPerArtist: max(2, prefs.maxPerAlbum)).map(\.id)
        } else {
            ids = Radio.continuousOpening(seed: track, in: store.tracks, count: 12)
        }
        var q = PlayQueue()
        q.load([track.id] + ids,
               startAt: track.id,
               origin: .radio(seed: track.id, title: track.meta.title, mode: mode))
        player.play(queue: q)
    }

    /// Called when a track starts. A continuous radio re-seeds off it, so the
    /// queue keeps walking outward instead of orbiting the original track.
    public func extendRadioIfNeeded(after track: Track) {
        guard player.queue.isContinuousRadio else { return }
        guard player.queue.upNext.count <= 4 else { return }   // top up before it runs dry

        // Re-seed off whatever is playing. If that track has no vector yet,
        // fall back to the one the radio started from rather than giving up.
        var seed = track
        if !seed.isAnalysed {
            guard case .radio(let id, _, _) = player.queue.origin,
                  let original = store.track(id), original.isAnalysed else { return }
            seed = original
        }

        let fresh = Radio.continuation(seed: seed, in: store.tracks,
                                       seen: player.queue.seen, count: 8)
        guard !fresh.isEmpty else { return }
        player.extendQueue(fresh)
    }

    // MARK: - Navigation from anywhere (long-press actions)

    public enum NavTarget: Identifiable, Equatable {
        case artist(String)      // canonical key
        case album(String)       // album id
        public var id: String {
            switch self { case .artist(let k): return "ar-\(k)"
                          case .album(let a): return "al-\(a)" }
        }
    }
    public var navTarget: NavTarget?

    public func showArtist(of track: Track) {
        navTarget = .artist(track.meta.artistKey)
    }
    public func showAlbum(of track: Track) {
        if let a = album(for: track) { navTarget = .album(a.id) }
    }
    public func album(withID id: String) -> Album? { albums.first { $0.id == id } }

    /// R2.4 — the random button.
    public func shuffleEverything() {
        guard !tracks.isEmpty else { return }
        var q = PlayQueue()
        q.loadShuffled(tracks.map(\.id))
        player.play(queue: q)
    }

    public func shuffleAlbums() {
        guard !albums.isEmpty else { return }
        let order = albums.shuffled().flatMap(\.trackIDs)
        var q = PlayQueue()
        q.load(order, origin: .shuffleAll)
        player.play(queue: q)
    }

    // MARK: - Lookup helpers

    public func track(_ id: UUID) -> Track? { store.track(id) }
    public func search(_ q: String) -> [Track] { store.search(q) }

    public func album(for track: Track) -> Album? {
        albums.first { $0.trackIDs.contains(track.id) }
    }
    public func artist(forKey key: String) -> Artist? {
        artists.first { $0.key == key }
    }

    public func neighbours(of track: Track, count: Int = 25) -> [(Track, Float)] {
        Radio.neighbours(of: track, in: store.tracks, count: count)
            .compactMap { n in store.track(n.id).map { ($0, n.similarity) } }
    }
}
