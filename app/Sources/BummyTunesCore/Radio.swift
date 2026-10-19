import Accelerate
import Foundation

/// Sonic similarity: radio and the music map (R7).
///
/// Vectors are unit length, so cosine similarity is a plain dot product and the
/// whole search is one matrix-vector multiply. On a few thousand tracks that is
/// microseconds, which is why this needs no approximate index.
public enum Radio {

    public struct Neighbour: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let similarity: Float
    }

    /// Nearest tracks to `seed`.
    /// - Parameter diversify: cap how many neighbours may come from any one
    ///   album. Without it a radio seeded inside an album mostly replays that
    ///   album, which measured at 40.8% same-album in the top 12.
    /// - Parameter maxPerArtist: cap how many may come from one artist. The
    ///   album cap alone is not enough: a prolific artist has many albums, and
    ///   a radio that plays six of its first ten tracks from the same person is
    ///   not a radio, it is that artist's discography in a strange order.
    public static func neighbours(of seed: Track,
                                  in tracks: [Track],
                                  count: Int = 25,
                                  maxPerAlbum: Int = 3,
                                  maxPerArtist: Int = 3,
                                  diversify: Bool = true) -> [Neighbour] {
        guard let q = seed.embedding else { return [] }

        // Score first, with nothing but indices and floats in play. The album
        // key needs Unicode folding, and doing that for every track on every
        // call is the expensive part of a radio: it runs on each song change
        // under a continuous radio.
        var idx: [Int] = []
        var sims: [Float] = []
        idx.reserveCapacity(tracks.count)
        sims.reserveCapacity(tracks.count)
        for (i, t) in tracks.enumerated() where t.id != seed.id {
            guard let e = t.embedding, e.count == q.count else { continue }
            var dot: Float = 0
            vDSP_dotpr(q, 1, e, 1, &dot, vDSP_Length(q.count))
            idx.append(i)
            sims.append(dot)
        }
        guard !idx.isEmpty else { return [] }

        // Ordering is over everything, because the caps below decide how far
        // down the list the answer actually lies. Truncating to a fixed
        // shortlist first was a mistake: a prolific artist with a lot of
        // similar tracks filled the entire shortlist, the caps then had only
        // three or four artists to choose between, and the backfill handed
        // half the radio back to the artist the caps were meant to limit.
        var order = Array(idx.indices)
        order.sort { sims[$0] > sims[$1] }

        guard diversify else {
            return order.prefix(count).map {
                Neighbour(id: tracks[idx[$0]].id, similarity: sims[$0])
            }
        }

        // The same song twice is not a recommendation. Libraries collect
        // duplicates: a single and the album track, two rips of one record,
        // a live version filed twice. They score identically, so without this
        // the seed itself comes back at 1.00 and its neighbours arrive in
        // pairs. Cheap comparison on purpose, this runs per candidate.
        func songKey(_ t: Track) -> String {
            "\(t.meta.artistKey)|\(t.meta.title.lowercased())"
        }
        var heard: Set<String> = [songKey(seed)]

        var perAlbum: [String: Int] = [:]
        var perArtist: [String: Int] = [:]
        var out: [Neighbour] = []
        var overflow: [Neighbour] = []
        out.reserveCapacity(count)
        for o in order {
            if out.count >= count { break }
            let t = tracks[idx[o]]
            guard heard.insert(songKey(t)).inserted else { continue }
            let artist = t.meta.artistKey
            let album = "\(artist)|\(SearchKey.fold(t.meta.album))"
            let a = perAlbum[album, default: 0]
            let r = perArtist[artist, default: 0]
            if a < maxPerAlbum && r < maxPerArtist {
                perAlbum[album] = a + 1
                perArtist[artist] = r + 1
                out.append(Neighbour(id: t.id, similarity: sims[o]))
            } else if overflow.count < count {
                // Only as many as could ever be needed to fill the shortfall.
                overflow.append(Neighbour(id: t.id, similarity: sims[o]))
            }
        }

        // Backfill from what the cap displaced rather than returning short.
        for n in overflow where out.count < count { out.append(n) }
        return out
    }

    /// The opening queue for a continuous radio.
    ///
    /// Not simply the nearest tracks. Taking the top twelve gives almost the
    /// same list as a similar radio, because both are reading off the same
    /// ranking, and the two modes then feel identical for the first ten
    /// minutes. This takes a wide, one-per-artist pool and fans out across it,
    /// so the first track is the closest match and each one after is further
    /// out. It starts travelling straight away, which is the whole point of
    /// the mode.
    public static func continuousOpening(seed: Track, in tracks: [Track],
                                         count: Int = 12) -> [UUID] {
        guard count > 0, seed.embedding != nil else { return [] }
        let pool = neighbours(of: seed, in: tracks, count: max(count * 12, 120),
                              maxPerAlbum: 1, maxPerArtist: 1)
        guard !pool.isEmpty else { return [] }
        let step = max(1, pool.count / count)
        var out: [UUID] = []
        var i = 0
        while out.count < count && i < pool.count {
            out.append(pool[i].id)
            i += step
        }
        return out
    }

    /// What a continuous radio should play next.
    ///
    /// The naive version of this asks for the nearest thirty tracks to the
    /// song now playing and drops anything already queued. That returns
    /// nothing almost immediately: the queue was built out of the neighbours
    /// of a song that sounds like this one, so the nearest thirty *are* the
    /// queue. A continuous radio would quietly stop extending and end.
    ///
    /// So the net is cast much wider, the per-album cap is tightened to keep
    /// it moving, and if everything close by really has been heard it jumps to
    /// an unplayed track rather than stopping.
    public static func continuation(seed: Track, in tracks: [Track],
                                    seen: Set<UUID>, count: Int = 8) -> [UUID] {
        guard count > 0 else { return [] }
        if seed.embedding != nil {
            let near = neighbours(of: seed, in: tracks, count: max(count * 50, 400),
                                  maxPerAlbum: 2, maxPerArtist: 2)
                .lazy
                .map(\.id)
                .filter { !seen.contains($0) }
                .prefix(count)
            if !near.isEmpty { return Array(near) }
        }
        // Nothing near is unheard. Keep going somewhere else entirely.
        let unheard = tracks.filter { $0.embedding != nil && !seen.contains($0.id) }
        guard let jump = unheard.randomElement() else { return [] }
        return [jump.id]
    }

    /// Coherence check (the measurable oracle from the Python prototype).
    /// Returns the fraction of each track's top-K neighbours sharing its album
    /// and artist, alongside the random baseline for the same library.
    public struct Coherence: Sendable {
        public let sameAlbum: Double, albumBaseline: Double
        public let sameArtist: Double, artistBaseline: Double
        public var albumLift: Double { albumBaseline > 0 ? sameAlbum / albumBaseline : 0 }
        public var artistLift: Double { artistBaseline > 0 ? sameArtist / artistBaseline : 0 }
    }

    public static func coherence(_ tracks: [Track], k: Int = 12) -> Coherence? {
        let analysed = tracks.filter { $0.embedding != nil }
        guard analysed.count > k + 1 else { return nil }

        let albumOf = analysed.map { "\($0.meta.artistKey)|\(SearchKey.fold($0.meta.album))" }
        let artistOf = analysed.map(\.meta.artistKey)
        var albumSizes: [String: Int] = [:], artistSizes: [String: Int] = [:]
        for a in albumOf { albumSizes[a, default: 0] += 1 }
        for a in artistOf { artistSizes[a, default: 0] += 1 }

        var albHits = 0.0, albN = 0.0, artHits = 0.0
        var albBase = 0.0, artBase = 0.0
        let n = analysed.count

        for i in 0..<n {
            guard let q = analysed[i].embedding else { continue }
            var scored: [(Int, Float)] = []
            scored.reserveCapacity(n)
            for j in 0..<n where j != i {
                guard let e = analysed[j].embedding else { continue }
                var dot: Float = 0
                vDSP_dotpr(q, 1, e, 1, &dot, vDSP_Length(q.count))
                scored.append((j, dot))
            }
            scored.sort { $0.1 > $1.1 }
            let top = scored.prefix(k)

            // Only judge album coherence where the album could fill the window.
            if albumSizes[albumOf[i], default: 0] > k {
                albHits += Double(top.filter { albumOf[$0.0] == albumOf[i] }.count) / Double(k)
                albBase += Double(albumSizes[albumOf[i]]! - 1) / Double(n - 1)
                albN += 1
            }
            artHits += Double(top.filter { artistOf[$0.0] == artistOf[i] }.count) / Double(k)
            artBase += Double(artistSizes[artistOf[i]]! - 1) / Double(n - 1)
        }

        return Coherence(
            sameAlbum: albN > 0 ? albHits / albN : 0,
            albumBaseline: albN > 0 ? albBase / albN : 0,
            sameArtist: artHits / Double(n),
            artistBaseline: artBase / Double(n))
    }
}

/// The music map (R7.1): a 2D projection of the 200-d space.
///
/// PCA via power iteration on the covariance, rather than a full SVD, because
/// it needs only the top two components and runs in milliseconds on device
/// with no linear-algebra dependency beyond Accelerate.
public enum MusicMap {

    public struct Point: Sendable { public let id: UUID; public let x: Float; public let y: Float }

    /// Groups the map colours by.
    ///
    /// Genre tags where the library has them, otherwise k-means over the
    /// embeddings themselves. The fallback matters: a library with no genre
    /// tags would otherwise render as one flat colour, and the sonic clusters
    /// are what the map is actually showing anyway.
    public struct Grouping: Sendable {
        /// Track id to group index.
        public let group: [UUID: Int]
        /// Display name per group index.
        public let names: [String]
        /// True when these came from real genre tags.
        public let fromTags: Bool
        /// Index of the group holding tracks with no genre at all, if any.
        /// Drawn in a neutral colour, because painting the majority of a
        /// library a bright colour makes the map look like one genre.
        public var untaggedIndex: Int?

        public init(group: [UUID: Int], names: [String], fromTags: Bool,
                    untaggedIndex: Int? = nil) {
            self.group = group; self.names = names
            self.fromTags = fromTags; self.untaggedIndex = untaggedIndex
        }
    }

    public static func grouping(_ tracks: [Track], maxGroups: Int = 16) -> Grouping {
        let analysed = tracks.filter { $0.embedding != nil }
        guard !analysed.isEmpty else { return Grouping(group: [:], names: [], fromTags: false) }

        // A track with no genre tag inherits its album's, decided by whichever
        // genre its album-mates carry most often. Most rips tag some tracks of
        // a record and not others, and without this every one of those lands in
        // a single "Other" bucket that then dominates the map.
        var albumVotes: [String: [String: Int]] = [:]
        for t in analysed {
            guard let g = t.meta.genre?.trimmingCharacters(in: .whitespaces), !g.isEmpty
            else { continue }
            let album = "\(t.meta.artistKey)|\(SearchKey.fold(t.meta.album))"
            albumVotes[album, default: [:]][normalise(g), default: 0] += 1
        }
        var albumGenre: [String: String] = [:]
        for (album, votes) in albumVotes {
            albumGenre[album] = votes.sorted {
                $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
            }.first?.key
        }
        func genre(of t: Track) -> String? {
            if let g = t.meta.genre?.trimmingCharacters(in: .whitespaces), !g.isEmpty {
                return normalise(g)
            }
            return albumGenre["\(t.meta.artistKey)|\(SearchKey.fold(t.meta.album))"]
        }

        var counts: [String: Int] = [:]
        for t in analysed {
            guard let g = genre(of: t) else { continue }
            counts[g, default: 0] += 1
        }
        let tagged = counts.values.reduce(0, +)
        // A fifth, not a third. Analysis works through the library in import
        // order, so the tagged fraction moves as it goes, and a tight threshold
        // made the map flip between genres and clusters part way through a run.
        if tagged * 5 >= analysed.count {
            // Sorted by count, then by name. Ties used to be broken by
            // dictionary order, which meant a different set of genres and a
            // different colour for each of them on every recompute.
            let top = counts.sorted {
                $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
            }.prefix(maxGroups - 1).map(\.key)
            // Two buckets at the end, not one: tracks with a genre that did
            // not make the list, and tracks with no genre anywhere. Lumping
            // them together painted most of the map a single bright colour.
            var names = top
            names.append("Other")
            names.append("Untagged")
            let otherIndex = names.count - 2
            let untagged = names.count - 1
            let index = Dictionary(uniqueKeysWithValues: top.enumerated().map { ($1, $0) })
            var map: [UUID: Int] = [:]
            var untaggedCount = 0
            for t in analysed {
                if let g = genre(of: t) {
                    map[t.id] = index[g] ?? otherIndex
                } else {
                    map[t.id] = untagged
                    untaggedCount += 1
                }
            }
            if untaggedCount == 0 { names.removeLast() }
            return Grouping(group: map, names: names, fromTags: true,
                            untaggedIndex: untaggedCount > 0 ? untagged : nil)
        }

        // No usable tags: cluster the vectors instead.
        return cluster(analysed, k: min(maxGroups, max(2, analysed.count / 40)))
    }

    /// Collapse genre spellings so "Hip-Hop", "hip hop" and "HipHop" agree.
    private static func normalise(_ g: String) -> String {
        let folded = SearchKey.fold(g)
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "/", with: " ")
        let first = folded.split(separator: ";").first
            ?? folded.split(separator: ",").first
            ?? Substring(folded)
        return first.trimmingCharacters(in: .whitespaces).capitalized
    }

    /// Plain k-means over the unit vectors. Deterministic seeding so the map
    /// does not recolour itself every launch.
    private static func cluster(_ tracks: [Track], k: Int, iterations: Int = 12) -> Grouping {
        guard k >= 2, let dim = tracks.first?.embedding?.count else {
            return Grouping(group: [:], names: [], fromTags: false)
        }
        var centroids: [[Float]] = (0..<k).map { i in
            tracks[(i * tracks.count / k) % tracks.count].embedding!
        }
        var assign = [Int](repeating: 0, count: tracks.count)

        for _ in 0..<iterations {
            var moved = false
            for (i, t) in tracks.enumerated() {
                guard let e = t.embedding else { continue }
                var best = 0; var bestDot: Float = -2
                for (c, cen) in centroids.enumerated() {
                    var dot: Float = 0
                    vDSP_dotpr(e, 1, cen, 1, &dot, vDSP_Length(dim))
                    if dot > bestDot { bestDot = dot; best = c }
                }
                if assign[i] != best { assign[i] = best; moved = true }
            }
            var sums = [[Float]](repeating: [Float](repeating: 0, count: dim), count: k)
            var counts = [Int](repeating: 0, count: k)
            for (i, t) in tracks.enumerated() {
                guard let e = t.embedding else { continue }
                vDSP_vadd(sums[assign[i]], 1, e, 1, &sums[assign[i]], 1, vDSP_Length(dim))
                counts[assign[i]] += 1
            }
            for c in 0..<k where counts[c] > 0 {
                var inv = 1.0 / Float(counts[c])
                vDSP_vsmul(sums[c], 1, &inv, &sums[c], 1, vDSP_Length(dim))
                var n: Float = 0
                vDSP_svesq(sums[c], 1, &n, vDSP_Length(dim))
                n = n.squareRoot()
                if n > 1e-6 {
                    var s = 1 / n
                    vDSP_vsmul(sums[c], 1, &s, &sums[c], 1, vDSP_Length(dim))
                    centroids[c] = sums[c]
                }
            }
            if !moved { break }
        }

        var map: [UUID: Int] = [:]
        for (i, t) in tracks.enumerated() { map[t.id] = assign[i] }

        // Name each cluster after the genre most common inside it. Even when
        // too few tracks are tagged to group by genre outright, enough usually
        // are to say what a cluster is, which beats "Cluster 7" on a legend.
        var perCluster = [[String: Int]](repeating: [:], count: k)
        for (i, t) in tracks.enumerated() {
            let raw = t.meta.genre?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !raw.isEmpty else { continue }
            perCluster[assign[i]][normalise(raw), default: 0] += 1
        }
        var used = Set<String>()
        var names: [String] = []
        for c in 0..<k {
            let best = perCluster[c].sorted {
                $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
            }.first?.key
            var name = best ?? "Cluster \(c + 1)"
            if !used.insert(name).inserted { name = "\(name) \(c + 1)" }
            names.append(name)
        }
        return Grouping(group: map, names: names, fromTags: false)
    }
    public struct Result: Sendable {
        public let points: [Point]
        /// Fraction of total variance each axis explains.
        public let variance: (Float, Float)
    }

    public static func project(_ tracks: [Track], iterations: Int = 128) -> Result? {
        let analysed = tracks.filter { $0.embedding != nil }
        guard analysed.count >= 3, let dim = analysed.first?.embedding?.count else { return nil }
        let n = analysed.count

        // Centre the data.
        var mean = [Float](repeating: 0, count: dim)
        for t in analysed { vDSP_vadd(mean, 1, t.embedding!, 1, &mean, 1, vDSP_Length(dim)) }
        var inv = Float(1.0 / Float(n))
        vDSP_vsmul(mean, 1, &inv, &mean, 1, vDSP_Length(dim))

        var X = [Float](repeating: 0, count: n * dim)
        for (i, t) in analysed.enumerated() {
            vDSP_vsub(mean, 1, t.embedding!, 1, &X[i * dim], 1, vDSP_Length(dim))
        }

        func project(_ v: [Float]) -> [Float] {           // X * v
            var out = [Float](repeating: 0, count: n)
            X.withUnsafeBufferPointer { xp in
                cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(n), Int32(dim),
                            1.0, xp.baseAddress!, Int32(dim), v, 1, 0.0, &out, 1)
            }
            return out
        }
        func backproject(_ s: [Float]) -> [Float] {       // X^T * s
            var out = [Float](repeating: 0, count: dim)
            X.withUnsafeBufferPointer { xp in
                cblas_sgemv(CblasRowMajor, CblasTrans, Int32(n), Int32(dim),
                            1.0, xp.baseAddress!, Int32(dim), s, 1, 0.0, &out, 1)
            }
            return out
        }
        func normalise(_ v: inout [Float]) -> Float {
            var norm: Float = 0
            vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
            norm = norm.squareRoot()
            guard norm > 1e-9 else { return 0 }
            var s = 1.0 / norm
            vDSP_vsmul(v, 1, &s, &v, 1, vDSP_Length(v.count))
            return norm
        }

        // Power iteration for the leading component.
        var v1 = (0..<dim).map { Float(sin(Double($0) * 0.37) ) }   // deterministic seed
        _ = normalise(&v1)
        for _ in 0..<iterations {
            var next = backproject(project(v1))
            if normalise(&next) == 0 { break }
            v1 = next
        }

        // Deflate, then iterate again for the second component.
        let s1 = project(v1)
        for i in 0..<n {
            var c = -s1[i]
            var row = Array(X[(i * dim)..<((i + 1) * dim)])
            vDSP_vsma(v1, 1, &c, row, 1, &row, 1, vDSP_Length(dim))
            X.replaceSubrange((i * dim)..<((i + 1) * dim), with: row)
        }
        var v2 = (0..<dim).map { Float(cos(Double($0) * 0.61)) }
        _ = normalise(&v2)
        for _ in 0..<iterations {
            var next = backproject(project(v2))
            if normalise(&next) == 0 { break }
            v2 = next
        }
        let s2 = project(v2)

        // Total variance for the explained-variance readout.
        var total: Float = 0
        for (i, t) in analysed.enumerated() {
            var d = [Float](repeating: 0, count: dim)
            vDSP_vsub(mean, 1, t.embedding!, 1, &d, 1, vDSP_Length(dim))
            var sq: Float = 0
            vDSP_svesq(d, 1, &sq, vDSP_Length(dim))
            total += sq
            _ = i
        }
        var e1: Float = 0, e2: Float = 0
        vDSP_svesq(s1, 1, &e1, vDSP_Length(n))
        vDSP_svesq(s2, 1, &e2, vDSP_Length(n))

        // Normalise into [-1, 1] for drawing. Centre on the data's own midpoint
        // rather than zero: the projection is rarely symmetric, and dividing by
        // a raw max leaves the cloud shoved into one corner with dead canvas
        // around it. One shared scale keeps the two axes comparable, so
        // distances on screen still mean something.
        let x0 = s1.min() ?? 0, x1 = s1.max() ?? 0
        let y0 = s2.min() ?? 0, y1 = s2.max() ?? 0
        let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2
        let scale = max((x1 - x0) / 2, (y1 - y0) / 2, 1e-6)
        let pts = (0..<n).map {
            Point(id: analysed[$0].id,
                  x: (s1[$0] - cx) / scale,
                  y: (s2[$0] - cy) / scale)
        }
        return Result(points: pts,
                      variance: (total > 0 ? e1 / total : 0, total > 0 ? e2 / total : 0))
    }
}
