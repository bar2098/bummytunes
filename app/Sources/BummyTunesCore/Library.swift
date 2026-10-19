import Foundation

/// One track in the library.
public struct Track: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    /// Bookmark data, so access survives relaunch under the security scope (R8.4).
    public var bookmark: Data?
    public var path: String
    public var meta: TrackMetadata
    /// 200-d MusiCNN vector, unit length. Nil until analysed.
    public var embedding: [Float]?
    /// Map position, filled by `MusicMap`.
    public var mapX: Float?
    public var mapY: Float?
    /// Sorting metadata. Optional so an existing library decodes unchanged.
    public var addedAt: Date?
    public var lastPlayed: Date?

    public init(id: UUID = UUID(), path: String, bookmark: Data? = nil,
                meta: TrackMetadata, embedding: [Float]? = nil) {
        self.id = id; self.path = path; self.bookmark = bookmark
        self.meta = meta; self.embedding = embedding
    }

    public var isAnalysed: Bool { embedding != nil }

    /// Resolved file location.
    ///
    /// Paths inside the app's own container are stored relative to it. iOS can
    /// hand an app a different container path after a reinstall, and an absolute
    /// path baked at import time would then point nowhere — every track would
    /// look missing and the whole library would need re-importing. Storing the
    /// tail and rejoining it at read time survives that.
    public var url: URL {
        if path.hasPrefix(Track.containerMarker) {
            let tail = String(path.dropFirst(Track.containerMarker.count))
            return Track.documents.appendingPathComponent(tail)
        }
        return URL(fileURLWithPath: path)
    }

    /// Marker for "relative to this app's Documents folder".
    public static let containerMarker = "@docs/"

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Rewrite an absolute path into a container-relative one where possible.
    public static func portablePath(for url: URL) -> String {
        let docs = documents.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        if p.hasPrefix(docs + "/") {
            return containerMarker + String(p.dropFirst(docs.count + 1))
        }
        return p
    }
}

/// Grouping views over the track list.
public struct Album: Identifiable, Hashable, Sendable {
    /// Stored, not derived from the title and artist.
    ///
    /// Deriving it meant two different records could share an id: the same
    /// album title under the same artist in two folders, or two compilations
    /// both credited to Various Artists. A list keyed on a duplicated id draws
    /// one row and leaves a blank hole where the other should be, and tapping
    /// one opens the other.
    public let id: String
    public let title: String
    public let artist: String
    public let artistKey: String
    public var trackIDs: [UUID]

    public init(id: String, title: String, artist: String,
                artistKey: String, trackIDs: [UUID]) {
        self.id = id; self.title = title; self.artist = artist
        self.artistKey = artistKey; self.trackIDs = trackIDs
    }

    public init(title: String, artist: String, artistKey: String, trackIDs: [UUID]) {
        self.init(id: "\(artistKey)|\(SearchKey.fold(title))", title: title,
                  artist: artist, artistKey: artistKey, trackIDs: trackIDs)
    }
}

public struct Artist: Identifiable, Hashable, Sendable {
    public var id: String { key }
    public let key: String
    /// The most common spelling seen, used for display.
    public let name: String
    public var trackIDs: [UUID]
    public var albumIDs: [String]
}

/// The library database (R9.1).
///
/// Deliberately an in-memory index with a JSON store behind it rather than
/// SQLite: a personal library is thousands of rows, not millions, and brute
/// force over 200-d vectors is microseconds at that size. That keeps the whole
/// thing dependency-free and identical on macOS and iOS.
public final class LibraryStore: @unchecked Sendable {

    /// The rows. Private on purpose: analysis writes embeddings from a
    /// background thread, so reading this array without going through the
    /// queue is a data race on its buffer, not merely a stale read.
    private var storage: [Track] = []
    private var index: [UUID: Int] = [:]

    /// Terms per track, by field, built once when the library changes.
    ///
    /// Not persisted: it is derived, and rebuilding it is milliseconds. Held so
    /// a keystroke does not have to fold and split every title in the library.
    private struct Terms {
        var title: [String] = []
        var artist: [String] = []
        var album: [String] = []
    }
    private var terms: [Terms] = []
    private let queue = DispatchQueue(label: "bummytunes.library", attributes: .concurrent)

    /// A snapshot, taken under the lock. Cheap: arrays are copy-on-write.
    public var tracks: [Track] { queue.sync { storage } }

    public init() {}

    // MARK: - Mutation

    public func replaceAll(_ new: [Track]) {
        queue.sync(flags: .barrier) {
            storage = new
            reindex()
        }
    }

    public func upsert(_ track: Track) {
        queue.sync(flags: .barrier) {
            if let i = index[track.id] { storage[i] = track }
            else { index[track.id] = storage.count; storage.append(track) }
        }
    }

    /// Record a play, for the recently-played sort.
    public func markPlayed(_ id: UUID, at date: Date = Date()) {
        queue.sync(flags: .barrier) {
            guard let i = index[id] else { return }
            storage[i].lastPlayed = date
        }
    }

    /// Point a track at where its file actually is now.
    ///
    /// Bookmarks survive a container being renamed; the paths recorded at
    /// import time do not. Playback hides this because it resolves the
    /// bookmark, but everything that works from the path, artwork and folder
    /// scanning included, quietly fails until the path is corrected.
    @discardableResult
    public func repairPaths(_ fixes: [UUID: String]) -> Int {
        queue.sync(flags: .barrier) {
            var changed = 0
            for (id, path) in fixes {
                guard let i = index[id], storage[i].path != path else { continue }
                storage[i].path = path
                changed += 1
            }
            return changed
        }
    }

    public func setEmbedding(_ vec: [Float], for id: UUID) {
        queue.sync(flags: .barrier) {
            guard let i = index[id] else { return }
            storage[i].embedding = vec
        }
    }

    private func reindex() {
        index.removeAll(keepingCapacity: true)
        terms = []
        terms.reserveCapacity(storage.count)
        for (i, t) in storage.enumerated() {
            index[t.id] = i
            terms.append(Terms(title: SearchKey.terms(raw: t.meta.title),
                               artist: SearchKey.terms(raw: t.meta.artist),
                               album: SearchKey.terms(raw: t.meta.album)))
        }
    }

    public func track(_ id: UUID) -> Track? {
        queue.sync { index[id].map { storage[$0] } }
    }

    // MARK: - Derived views

    public var analysedCount: Int { queue.sync { storage.filter(\.isAnalysed).count } }

    /// Albums, grouped the way they sit on disk.
    ///
    /// Keying on the track artist splits a compilation into one album per
    /// featured artist: "Hydeout Productions First Collection" came out as
    /// thirteen albums of one track each. So the key is the album title plus
    /// the album artist where the tags carry one, and the containing folder
    /// where they do not, which is what actually makes a record a record.
    public func albums() -> [Album] {
        queue.sync {
            // Metadata is pulled out here rather than through `track(_:)` in the
            // sort below. That call takes the same lock, and a nested sync on a
            // concurrent queue deadlocks the moment a barrier write is waiting.
            var meta: [UUID: TrackMetadata] = [:]
            meta.reserveCapacity(storage.count)
            for t in storage { meta[t.id] = t.meta }

            struct Group {
                var title: String
                var albumArtist: String?
                var trackIDs: [UUID] = []
                /// Track artist keys seen, with how often, to name the album
                /// and to file it under someone when there is no album artist.
                var artistCounts: [String: (name: String, count: Int)] = [:]
            }
            var groups: [String: Group] = [:]
            var keyOrder: [String] = []

            for t in storage {
                let m = t.meta
                let titleKey = SearchKey.fold(m.album)
                let scope: String
                if let aa = m.albumArtist, !aa.trimmingCharacters(in: .whitespaces).isEmpty {
                    scope = MetadataParser.canonicalArtist(aa)
                } else {
                    scope = (t.path as NSString).deletingLastPathComponent
                }
                let key = "\(titleKey)|\(scope)"

                if groups[key] == nil {
                    groups[key] = Group(title: m.album, albumArtist: m.albumArtist)
                    keyOrder.append(key)
                }
                groups[key]?.trackIDs.append(t.id)
                let prior = groups[key]?.artistCounts[m.artistKey]
                groups[key]?.artistCounts[m.artistKey] =
                    (prior?.name ?? m.artist, (prior?.count ?? 0) + 1)
            }

            var out: [Album] = []
            out.reserveCapacity(groups.count)
            for gKey in keyOrder {
                guard let g = groups[gKey] else { continue }
                // Who the record is by: the album artist if tagged, the one
                // contributor if there is only one, otherwise a compilation.
                //
                // The tie-break matters. `Album.id` is built from this key, and
                // picking the busiest contributor by dictionary order gave a
                // different answer on each call when contributors tied, so an
                // album's id changed between one listing and the next.
                let dominant = g.artistCounts.max {
                    $0.value.count != $1.value.count
                        ? $0.value.count < $1.value.count
                        : $0.key > $1.key
                }
                let name: String
                let key: String
                if let aa = g.albumArtist, !aa.trimmingCharacters(in: .whitespaces).isEmpty {
                    name = aa
                    key = MetadataParser.canonicalArtist(aa)
                } else if g.artistCounts.count == 1, let only = dominant {
                    name = only.value.name
                    key = only.key
                } else {
                    // A fixed key, not the busiest contributor: a compilation
                    // belongs to no one artist, and every contributor gets it
                    // listed on their own page below regardless.
                    name = "Various Artists"
                    key = "various artists"
                }

                var ids = g.trackIDs
                // Order within an album follows disc then track number, then
                // title, so "play the rest of the album from here" is meaningful.
                ids.sort { a, b in
                    guard let x = meta[a], let y = meta[b] else { return false }
                    if (x.discNumber ?? 1) != (y.discNumber ?? 1) {
                        return (x.discNumber ?? 1) < (y.discNumber ?? 1)
                    }
                    if let tx = x.trackNumber, let ty = y.trackNumber, tx != ty { return tx < ty }
                    if x.trackNumber != nil && y.trackNumber == nil { return true }
                    if x.trackNumber == nil && y.trackNumber != nil { return false }
                    return x.title.localizedStandardCompare(y.title) == .orderedAscending
                }
                // The grouping key is unique by construction, so it is the id.
                out.append(Album(id: gKey, title: g.title, artist: name,
                                 artistKey: key, trackIDs: ids))
            }
            return out.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
    }

    public func artists() -> [Artist] {
        let albs = albums()
        return queue.sync {
            var names: [String: [String: Int]] = [:]   // key -> spelling -> count
            var trackIDs: [String: [UUID]] = [:]
            for t in storage {
                names[t.meta.artistKey, default: [:]][t.meta.artist, default: 0] += 1
                trackIDs[t.meta.artistKey, default: []].append(t.id)
            }
            // File each album under every artist with a track on it, not only
            // under whoever the record is credited to, so a compilation shows
            // up on the pages of everyone who is actually on it.
            var albumIDs: [String: [String]] = [:]
            var owners: [String: Set<String>] = [:]
            for a in albs {
                var keys = Set<String>([a.artistKey])
                for id in a.trackIDs {
                    if let i = index[id] { keys.insert(storage[i].meta.artistKey) }
                }
                for k in keys where owners[k]?.contains(a.id) != true {
                    owners[k, default: []].insert(a.id)
                    albumIDs[k, default: []].append(a.id)
                }
            }

            return names.map { key, spellings in
                // Display the spelling that appears most often.
                let name = spellings.max { $0.value < $1.value }?.key ?? key
                return Artist(key: key, name: name,
                              trackIDs: trackIDs[key] ?? [],
                              albumIDs: albumIDs[key] ?? [])
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    // MARK: - Search (R12)

    /// Search.
    ///
    /// Terms, not substrings. A raw substring test matches inside any word, so
    /// "charity" could come back with tracks that merely contain those letters
    /// somewhere, while a real song called Charity ranked no higher than them.
    /// Matching is against whole words, or the start of one, which is what
    /// makes results predictable as you type.
    ///
    /// Every word of the query must match something, in any order, across the
    /// title, artist or album. What differs is how well: an exact word in the
    /// title is the best kind of match and the start of a word in an album name
    /// is the weakest, and the ranking below says so explicitly rather than
    /// hiding it in a score.
    ///
    /// A typo is tolerated only when a word matches nothing at all, only for
    /// words long enough for it to be meaningful, and only by a single edit.
    public func search(_ raw: String, limit: Int = 60) -> [Track] {
        let query = SearchKey.terms(raw: raw)
        guard !query.isEmpty else { return [] }

        // Cost per term, lowest is best. The gaps matter more than the values:
        // a title hit should always outrank an album hit.
        let titleExact = 0, titlePrefix = 2, artistExact = 4, artistPrefix = 6
        let albumExact = 8, albumPrefix = 10, typo = 20, noMatch = 1_000

        func cost(_ term: String, _ t: Terms) -> Int {
            var best = noMatch
            for w in t.title {
                if w == term { return titleExact }
                if w.hasPrefix(term) { best = min(best, titlePrefix) }
            }
            for w in t.artist {
                if w == term { best = min(best, artistExact) }
                else if w.hasPrefix(term) { best = min(best, artistPrefix) }
            }
            for w in t.album {
                if w == term { best = min(best, albumExact) }
                else if w.hasPrefix(term) { best = min(best, albumPrefix) }
            }
            guard best == noMatch, term.count >= 4 else { return best }
            // Nothing matched. One edit, against title words only.
            for w in t.title where EditDistance.within(term, w, limit: 1) <= 1 {
                return typo
            }
            return noMatch
        }

        // Rebuild if anything ever mutates the rows without going through
        // `replaceAll`. Searching against a stale index would return tracks
        // that have nothing to do with the query, which is impossible to
        // diagnose from the results. Under a barrier, because it writes.
        queue.sync(flags: .barrier) {
            if terms.count != storage.count { reindex() }
        }

        return queue.sync {
            var hits: [(i: Int, cost: Int)] = []
            for i in storage.indices {
                guard i < terms.count else { break }
                var total = 0
                var ok = true
                for term in query {
                    let c = cost(term, terms[i])
                    if c == noMatch { ok = false; break }
                    total += c
                }
                guard ok else { continue }
                // A shorter title that matched is usually the one meant: "Finger"
                // before "Fingertips".
                total += min(storage[i].meta.title.count / 8, 3)
                hits.append((i, total))
            }

            hits.sort {
                $0.cost != $1.cost
                    ? $0.cost < $1.cost
                    : storage[$0.i].meta.title.count < storage[$1.i].meta.title.count
            }

            // One row per song. A library collects duplicates, and ten copies
            // of the same track pushes everything else off the screen.
            var seen = Set<String>()
            var out: [Track] = []
            for h in hits {
                let t = storage[h.i]
                let key = "\(t.meta.artistKey)|\(t.meta.title.lowercased())"
                guard seen.insert(key).inserted else { continue }
                out.append(t)
                if out.count >= limit { break }
            }
            return out
        }
    }

    // MARK: - Persistence

    /// Save through `Store`, which keeps embeddings in a sidecar so a metadata
    /// schema change can never cost hours of analysis. See Store.swift.
    public func save(to dir: URL) throws {
        try Store.save(queue.sync { storage }, to: dir)
    }

    /// Load. Returns what happened so the app can tell the user when a library
    /// had to be recovered rather than silently showing an empty screen.
    @discardableResult
    public func load(from dir: URL) -> Store.LoadResult {
        let result = Store.load(from: dir)
        if case .loaded(let tracks, _) = result { replaceAll(tracks) }
        return result
    }

    /// Re-attach embeddings to freshly imported tracks by file path. Used after
    /// a recovery, where metadata was rebuilt but the vectors survived.
    public func attach(embeddings: [String: [Float]]) {
        queue.sync(flags: .barrier) {
            for i in storage.indices where storage[i].embedding == nil {
                storage[i].embedding = embeddings[storage[i].path]
            }
        }
    }
}
