import Foundation
import BummyTunesCore

// Verification runner. Plain executable rather than XCTest so it does not
// depend on a test harness this toolchain may not ship. Exits non-zero on
// any failure so it works as a build gate.

var failures = 0
var checks = 0

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    checks += 1
    if ok {
        print("  PASS  \(name)\(detail.isEmpty ? "" : "  \(detail)")")
    } else {
        failures += 1
        print("  FAIL  \(name)\(detail.isEmpty ? "" : "  \(detail)")")
    }
}

func section(_ s: String) { print("\n\(s)\n" + String(repeating: "-", count: 66)) }

// ---------------------------------------------------------------- search ----
section("R12  script-aware search folding")

check("Portuguese accent folds",
      SearchKey.fold("Pois É") == SearchKey.fold("Pois E"),
      "'Pois É' -> '\(SearchKey.fold("Pois É"))'")
check("São folds to sao",
      SearchKey.fold("São Paulo") == "sao paulo",
      "-> '\(SearchKey.fold("São Paulo"))'")
check("case insensitive",
      SearchKey.fold("POIS É") == SearchKey.fold("pois e"))

// The bug this exists to prevent: naive folding turns ゴミ into コミ.
let japanese = ["ゴミ", "あなたがすき", "ハングドマン", "塵芥に沈んで", "ニュータイプ"]
for j in japanese {
    check("Japanese preserved: \(j)", SearchKey.fold(j) == j.lowercased(),
          "-> '\(SearchKey.fold(j))'")
}
// Control: what does Foundation's own folding actually do here? Apple's
// implementation is kana-aware, unlike the naive NFKD "strip every combining
// mark" approach, which does corrupt these. Printed rather than asserted so
// the record shows the real behaviour on this platform.
print("\n  [control] Foundation .diacriticInsensitive on the same inputs:")
var foundationCorrupts = 0
for j in japanese + ["ｹﾞｰﾑ", "が", "ぱ"] {
    let f = j.folding(options: [.diacriticInsensitive, .caseInsensitive,
                                .widthInsensitive], locale: nil)
    let changed = f != j.lowercased()
    if changed { foundationCorrupts += 1 }
    print("            \(j) -> \(f)  \(changed ? "CHANGED" : "same")")
}
check("our folding never corrupts kana (the property that matters)",
      japanese.allSatisfy { SearchKey.fold($0) == $0.lowercased() },
      "Foundation changed \(foundationCorrupts) of \(japanese.count + 3)")

check("Hebrew untouched", SearchKey.fold("גיאגיא") == "גיאגיא")
check("Thai untouched", SearchKey.fold("ชีวิตในกลางคืน") == "ชีวิตในกลางคืน")
check("substring match", SearchKey.matches("pois e", in: "02. Pois É"))
check("edit distance tolerates a typo",
      EditDistance.within("fotografia", "fotogafia", limit: 2) <= 2)
check("edit distance rejects far strings",
      EditDistance.within("fotografia", "king gizzard", limit: 2) > 2)

// ------------------------------------------------------------------ mel ----
section("R6  mel front-end vs Python golden reference")

let fixturesPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/Tests/BummyTunesCoreTests/Fixtures"
let fx = URL(fileURLWithPath: fixturesPath)

func loadFloats(_ name: String) -> [Float]? {
    guard let d = try? Data(contentsOf: fx.appendingPathComponent(name)) else { return nil }
    return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

guard let audio = loadFloats("audio_f32.raw"),
      let goldMel = loadFloats("mel_f32.raw"),
      let goldPatches = loadFloats("patches_f32.raw") else {
    print("  FAIL  fixtures not found at \(fx.path)")
    exit(1)
}

let engine = MelSpectrogram()
guard let (mel, frames) = engine.melSpectrogram(audio) else {
    print("  FAIL  melSpectrogram returned nil"); exit(1)
}

check("frame count matches", mel.count == goldMel.count,
      "swift \(mel.count) (\(frames) frames)  python \(goldMel.count)")

if mel.count == goldMel.count {
    var maxRel: Float = 0, maxAbs: Float = 0
    for i in 0..<mel.count {
        let a = mel[i], b = goldMel[i]
        maxAbs = max(maxAbs, abs(a - b))
        maxRel = max(maxRel, abs(a - b) / max(abs(b), 1e-6))
    }
    check("mel matches Python within float tolerance", maxRel < 2e-3,
          String(format: "max rel %.2e  max abs %.2e", maxRel, maxAbs))
}

guard let (patches, nPatches) = engine.patches(audio) else {
    print("  FAIL  patches returned nil"); exit(1)
}
check("patch tensor shape matches", patches.count == goldPatches.count,
      "swift \(patches.count) (\(nPatches) patches)  python \(goldPatches.count)")

if patches.count == goldPatches.count {
    var maxRel: Float = 0
    for i in 0..<patches.count {
        maxRel = max(maxRel, abs(patches[i] - goldPatches[i])
                             / max(abs(goldPatches[i]), 1e-6))
    }
    check("log-mel patches match Python", maxRel < 2e-3,
          String(format: "max rel %.2e", maxRel))
}

// ------------------------------------------------------------ embedder ----
section("R6  full pipeline: audio -> 200-d vector, vs Python")

let modelPath = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : "../models/musicnn_embedding.onnx"

if let goldEmb = loadFloats("embedding_f32.raw") {
    do {
        let t0 = Date()
        let embedder = try Embedder(modelPath: modelPath, useCoreML: false)
        let vec = try embedder.embed(patches: patches, count: nPatches)
        let dt = Date().timeIntervalSince(t0)

        check("embedding dimension", vec.count == Embedder.embeddingDim,
              "\(vec.count)")
        check("unit norm", abs(vec.reduce(0) { $0 + $1 * $1 } - 1.0) < 1e-4)

        if vec.count == goldEmb.count {
            var dot: Double = 0
            for i in 0..<vec.count { dot += Double(vec[i]) * Double(goldEmb[i]) }
            check("cosine vs Python embedding", dot > 0.9999,
                  String(format: "%.8f  (%.0f ms)", dot, dt * 1000))
        }
    } catch {
        check("embedder ran", false, "\(error)")
    }
} else {
    check("golden embedding fixture present", false)
}

// ------------------------------------------------------------ metadata ----
section("R9  filename parsing and artist canonicalisation")

let shapes: [(String, String?, String?, String, Int?)] = [
    ("Art Dave - One Night In Manchester - 06 Seiya Kou Is A Boy",
     "Art Dave", "One Night In Manchester", "Seiya Kou Is A Boy", 6),
    ("02 - John Roseboro How To Pray", nil, nil, "John Roseboro How To Pray", 2),
    ("13. Chovendo Na Roseira", nil, nil, "Chovendo Na Roseira", 13),
    ("路傍の石 - mikgazer 2024 - 05 daydream", "路傍の石", "mikgazer 2024", "daydream", 5),
    ("גיאגיא - ילד נח - 03 למה איחרתי", "גיאגיא", "ילד נח", "למה איחרתי", 3),
    ("Yakuza Baka Mitai Female Version", nil, nil, "Yakuza Baka Mitai Female Version", nil),
]
for (stem, artist, album, title, track) in shapes {
    let p = MetadataParser.parseFilename(stem)
    let ok = p.artist == artist && p.album == album && p.title == title && p.track == track
    check("parse: \(stem.prefix(38))", ok,
          ok ? "" : "got artist=\(p.artist ?? "nil") album=\(p.album ?? "nil") title=\(p.title) track=\(p.track.map(String.init) ?? "nil")")
}

check("canonical artist collapses The and case",
      MetadataParser.canonicalArtist("The Botanicals")
        == MetadataParser.canonicalArtist("botanicals"))
check("canonical artist strips feat",
      MetadataParser.canonicalArtist("Art Dave feat. Luka")
        == MetadataParser.canonicalArtist("Art Dave"))
check("canonical artist keeps Japanese distinct",
      MetadataParser.canonicalArtist("路傍の石") != MetadataParser.canonicalArtist("kinoue64"))
check("accented artist folds to same key",
      MetadataParser.canonicalArtist("Elis Regina") == MetadataParser.canonicalArtist("ELIS REGINA"))

// ------------------------------------------ real library: radio + map ----
section("R7  radio and music map on the real 1,008-track library")

struct JSONRow: Decodable { let path: String; let name: String; let embedding: [Float] }

let jsonlPath = CommandLine.arguments.count > 3
    ? CommandLine.arguments[3] : "../prototype/embeddings.jsonl"

if let text = try? String(contentsOfFile: jsonlPath, encoding: .utf8) {
    let dec = JSONDecoder()
    var real: [Track] = []
    for line in text.split(separator: "\n") {
        guard let d = line.data(using: .utf8),
              let row = try? dec.decode(JSONRow.self, from: d) else { continue }
        let url = URL(fileURLWithPath: row.path)
        // Album/artist from the folder layout, matching the Python test.
        let album = url.deletingLastPathComponent().lastPathComponent
        let artist = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        let stem = url.deletingPathExtension().lastPathComponent
        let parsed = MetadataParser.parseFilename(stem)
        let meta = MetadataParser.assemble(title: parsed.title, artist: artist, album: album)
        real.append(Track(path: row.path, meta: meta, embedding: row.embedding))
    }
    check("loaded real embeddings", real.count > 900, "\(real.count) tracks")

    if let c = Radio.coherence(real, k: 12) {
        check("same-album lift reproduces Python's 21.2x", c.albumLift > 18,
              String(format: "%.1f%% vs %.1f%% random = %.1fx",
                     c.sameAlbum * 100, c.albumBaseline * 100, c.albumLift))
        check("same-artist lift reproduces Python's 5.1x", c.artistLift > 4,
              String(format: "%.1f%% vs %.1f%% random = %.1fx",
                     c.sameArtist * 100, c.artistBaseline * 100, c.artistLift))
    } else {
        check("coherence computed", false)
    }

    let t0 = Date()
    if let m = MusicMap.project(real) {
        let dt = Date().timeIntervalSince(t0)
        check("map projected every track", m.points.count == real.count,
              String(format: "%d points, PC1 %.1f%% PC2 %.1f%%, %.0f ms",
                     m.points.count, m.variance.0 * 100, m.variance.1 * 100, dt * 1000))
        let xs = m.points.map(\.x), ys = m.points.map(\.y)
        check("coordinates normalised into [-1,1]",
              xs.allSatisfy { abs($0) <= 1.001 } && ys.allSatisfy { abs($0) <= 1.001 })
        check("map actually spreads the library",
              (xs.max()! - xs.min()!) > 0.5 && (ys.max()! - ys.min()!) > 0.3,
              String(format: "x span %.2f  y span %.2f",
                     xs.max()! - xs.min()!, ys.max()! - ys.min()!))
    } else {
        check("map projected", false)
    }

    if let seed = real.first(where: { $0.meta.title.contains("Flamethrower") }) ?? real.first {
        let n = Radio.neighbours(of: seed, in: real, count: 8)
        check("radio returns neighbours", n.count == 8,
              "seed: \(seed.meta.title.prefix(40))")
        check("neighbours are sorted by similarity",
              zip(n, n.dropFirst()).allSatisfy { $0.similarity >= $1.similarity })
        check("album diversity cap applied", Set(n.map { id -> String in
            let t = real.first { $0.id == id.id }!
            return "\(t.meta.artistKey)|\(t.meta.album)"
        }).count >= 3, "\(Set(n.map { id in real.first { $0.id == id.id }!.meta.album }).count) distinct albums in top 8")
    }
} else {
    // The real-library fixture held the user's own track paths and derived
    // embeddings, so it was deleted. These checks run only when it is present.
    print("  SKIP  no real library fixture at \(jsonlPath)")
}

// ---------------------------------------------------------- grouping ----
section("R9  album grouping across compilations and folders")

do {
    func made(_ folder: String, _ album: String, _ artist: String,
              _ title: String, albumArtist: String? = nil, n: Int? = nil) -> Track {
        let m = MetadataParser.assemble(title: title, artist: artist, album: album,
                                        albumArtist: albumArtist, track: n,
                                        duration: 120,
                                        hadTitleTag: true, hadArtistTag: true)
        return Track(path: "\(folder)/\(title).mp3", meta: m)
    }

    // A compilation: one folder, one album title, a different artist per track
    // and no album artist tag. This used to come out as one album per artist.
    let comp = (1...5).map {
        made("/music/Various/Hydeout First Collection",
             "Hydeout Productions First Collection",
             "Artist \($0)", "Track \($0)", n: $0)
    }
    // A different record that happens to share nothing but the shelf.
    let other = (1...2).map {
        made("/music/Kurt Vile/Watch My Moves", "(Watch My Moves)",
             "Kurt Vile", "Song \($0)", n: $0)
    }
    // A two-disc album, tagged with an album artist, split across folders.
    let disc1 = made("/music/Band/Record/CD1", "Record", "Band", "One", albumArtist: "Band", n: 1)
    let disc2 = made("/music/Band/Record/CD2", "Record", "Band", "Two", albumArtist: "Band", n: 1)

    let s = LibraryStore()
    s.replaceAll(comp + other + [disc1, disc2])
    let albums = s.albums()

    let hydeout = albums.first { $0.title.hasPrefix("Hydeout") }
    check("a compilation is one album, not one per artist",
          hydeout?.trackIDs.count == 5, "\(hydeout?.trackIDs.count ?? 0) tracks")
    check("a compilation is credited to Various Artists",
          hydeout?.artist == "Various Artists", hydeout?.artist ?? "nil")
    check("a single-artist album keeps its artist",
          albums.first { $0.title == "(Watch My Moves)" }?.artist == "Kurt Vile")
    check("an album artist reunites discs in separate folders",
          albums.first { $0.title == "Record" }?.trackIDs.count == 2,
          "\(albums.first { $0.title == "Record" }?.trackIDs.count ?? 0) tracks")
    check("albums stay distinct", albums.count == 3, "\(albums.count) albums")
    // Duplicated ids make SwiftUI draw one row and leave a blank hole where
    // the other should be, which is what the gaps in the library list were.
    check("album ids are unique", Set(albums.map(\.id)).count == albums.count,
          "\(Set(albums.map(\.id)).count) ids for \(albums.count) albums")

    // Everyone on the compilation should see it on their own page.
    let artists = s.artists()
    let onComp = artists.filter { $0.albumIDs.contains(hydeout?.id ?? "") }.count
    check("every contributor lists the compilation", onComp == 5, "\(onComp) artists")

    // An album's id is what navigation and the artist pages are keyed on, so
    // two listings of the same library must agree on it. When contributors
    // tied, the busiest-contributor rule picked a different one each call.
    let idsA = Set(s.albums().map(\.id))
    let idsB = Set(s.albums().map(\.id))
    check("album ids are stable between listings", idsA == idsB,
          "\(idsA.count) vs \(idsB.count)")
}

// ------------------------------------------------------------ search ----
section("R12  search matches words in any order")

do {
    func song(_ title: String, _ artist: String, _ album: String) -> Track {
        Track(path: "/m/\(artist)/\(album)/\(title).mp3",
              meta: MetadataParser.assemble(title: title, artist: artist, album: album,
                                            hadTitleTag: true, hadArtistTag: true))
    }
    let lib = LibraryStore()
    lib.replaceAll([
        song("Finger", "Ty Segall", "Twins"),
        song("Fingertips", "The Brian Jonestown Massacre", "Methodrone"),
        song("Crazy Fingers", "The Grateful Dead", "Blues For Allah"),
        song("Pois É", "Marcos Valle", "Previsão do Tempo"),
        song("Manipulator", "Ty Segall", "Manipulator"),
    ])

    // The search that started this: a song and then its artist. Those words
    // are never adjacent, so a single substring match found neither.
    let a = lib.search("finger ty segall")
    check("a song plus its artist finds that song",
          a.first?.meta.title == "Finger", a.first?.meta.title ?? "nothing")
    check("it does not drag in unrelated matches", a.count == 1, "\(a.count) results")

    check("word order does not matter",
          lib.search("segall finger").first?.meta.title == "Finger")
    check("artist alone finds everything by them",
          lib.search("ty segall").count == 2, "\(lib.search("ty segall").count)")
    check("album words count too",
          lib.search("manipulator").count == 1)
    check("accents still fold", lib.search("pois e").first?.meta.title == "Pois É")
    check("a typo still falls through to fuzzy matching",
          lib.search("fingertps").first?.meta.title == "Fingertips",
          lib.search("fingertps").first?.meta.title ?? "nothing")
    check("nonsense finds nothing", lib.search("zzzqqqwww").isEmpty)

    // Terms, not substrings. A word has to match a whole word or the start of
    // one, so a query cannot land in the middle of an unrelated word.
    let lib2 = LibraryStore()
    lib2.replaceAll([
        song("Charity", "Courtney Barnett", "Tell Me How You Really Feel"),
        song("Você", "Antônio Carlos Jobim", "Terra Brasilis"),
        song("Coral", "Antônio Carlos Jobim", "Matita Perê"),
        song("Uncharitable", "Someone Else", "Whatever"),
        song("Luv(sic)", "Nujabes", "Modal Soul"),
    ])
    let ch = lib2.search("charity")
    check("a word matches the song actually called that",
          ch.first?.meta.title == "Charity", ch.first?.meta.title ?? "nothing")
    check("a word does not match inside another word",
          !ch.contains { $0.meta.title == "Uncharitable" }, "\(ch.count) results")
    check("unrelated titles stay out",
          !ch.contains { $0.meta.title == "Coral" || $0.meta.title == "Você" })
    check("punctuation splits into words",
          lib2.search("sic").first?.meta.title == "Luv(sic)",
          lib2.search("sic").first?.meta.title ?? "nothing")
    check("a prefix still matches while typing",
          lib2.search("char").first?.meta.title == "Charity")

    // Ranking: the title wins over the artist, which wins over the album.
    let lib3 = LibraryStore()
    lib3.replaceAll([
        song("Blue", "Someone", "Whatever"),
        song("Something", "Blue Band", "Whatever"),
        song("Another", "Someone", "Blue Album"),
    ])
    let ranked = lib3.search("blue").map(\.meta.title)
    check("title beats artist beats album",
          ranked == ["Blue", "Something", "Another"], "\(ranked)")

    // Duplicates collapse to one row.
    let lib4 = LibraryStore()
    lib4.replaceAll([
        song("Depreston", "Courtney Barnett", "Sometimes I Sit"),
        song("Depreston", "Courtney Barnett", "Live At The Forum"),
        song("Avant Gardener", "Courtney Barnett", "Sometimes I Sit"),
    ])
    check("the same song twice shows once",
          lib4.search("depreston").count == 1,
          "\(lib4.search("depreston").count) rows")
}

// ------------------------------------------------------------- radio ----
section("R7  a continuous radio keeps going")

do {
    // A library with clear structure: sixty tracks in six sonic clusters.
    var lib: [Track] = []
    for c in 0..<6 {
        for i in 0..<10 {
            var t = Track(path: "/music/c\(c)/t\(i).mp3",
                          meta: MetadataParser.assemble(title: "Track \(c)-\(i)",
                                                        artist: "Artist \(c)",
                                                        album: "Album \(c)"))
            var v = [Float](repeating: 0, count: 200)
            for d in 0..<200 {
                v[d] = Float(sin(Double(c * 31 + d) * 0.7)) + Float(i) * 0.001
            }
            let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
            t.embedding = v.map { $0 / norm }
            lib.append(t)
        }
    }

    // Walk a radio the way playback does: play one, top up when it runs low.
    var q = PlayQueue()
    let seed = lib[0]
    let opening = Radio.neighbours(of: seed, in: lib, count: 12).map(\.id)
    q.load([seed.id] + opening, startAt: seed.id,
           origin: .radio(seed: seed.id, title: seed.meta.title, mode: .continuous))

    var played = 0
    var ranDry = false
    for _ in 0..<55 {
        guard let now = q.current, let t = lib.first(where: { $0.id == now }) else { break }
        if q.upNext.count <= 4 {
            let more = Radio.continuation(seed: t, in: lib, seen: q.seen, count: 8)
            if more.isEmpty && q.upNext.isEmpty { ranDry = true; break }
            q.extend(more)
        }
        guard q.advance() != nil else { ranDry = true; break }
        played += 1
    }

    check("continuous radio plays past its opening queue", played >= 55,
          "\(played) tracks before it stopped")
    check("continuous radio never runs dry while tracks remain", !ranDry)
    check("continuous radio visits most of the library",
          Set(q.items).count >= 50, "\(Set(q.items).count) distinct of 60")

    // The failure that started this: asking only for the nearest few returns
    // tracks that are already queued.
    let alreadyQueued = Set(q.items)
    let again = Radio.continuation(seed: lib[0], in: lib, seen: alreadyQueued, count: 8)
    check("a fully heard library still returns something or nothing cleanly",
          again.allSatisfy { !alreadyQueued.contains($0) }, "\(again.count) picks")

    // A radio should not be one artist's discography. Six of the first ten
    // tracks used to come from whoever made the seed, because the album cap
    // does nothing against a prolific artist with many records.
    var wide: [Track] = []
    for a in 0..<8 {
        for alb in 0..<5 {
            for i in 0..<4 {
                var t = Track(path: "/m/a\(a)/alb\(alb)/t\(i).mp3",
                              meta: MetadataParser.assemble(title: "T\(a)-\(alb)-\(i)",
                                                            artist: "Artist \(a)",
                                                            album: "Album \(a)-\(alb)"))
                var v = [Float](repeating: 0, count: 200)
                for d in 0..<200 { v[d] = Float(sin(Double(d) * 0.11)) + Float(a) * 0.002 }
                let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
                t.embedding = v.map { $0 / n }
                wide.append(t)
            }
        }
    }
    let mix = Radio.neighbours(of: wide[0], in: wide, count: 12,
                               maxPerAlbum: 3, maxPerArtist: 2)
    var byArtist: [String: Int] = [:]
    for n in mix {
        if let t = wide.first(where: { $0.id == n.id }) {
            byArtist[t.meta.artistKey, default: 0] += 1
        }
    }
    check("no artist dominates a radio", (byArtist.values.max() ?? 0) <= 2,
          "busiest artist has \(byArtist.values.max() ?? 0) of \(mix.count)")

    // Continuous takes one per artist up front, so it leaves the seed's
    // record immediately rather than replaying it.
    // Eight artists exist, so ask for eight. Asking for more than the library
    // can supply under a cap of one correctly falls back to repeats.
    let strict = Radio.neighbours(of: wide[0], in: wide, count: 8,
                                  maxPerAlbum: 1, maxPerArtist: 1)
    var strictArtists = Set<String>()
    for n in strict {
        if let t = wide.first(where: { $0.id == n.id }) { strictArtists.insert(t.meta.artistKey) }
    }
    check("a continuous opening is one track per artist",
          strictArtists.count == strict.count,
          "\(strictArtists.count) artists across \(strict.count) tracks")

    // The complaint that started this: the two modes gave the same queue.
    // Both read off the same ranking, so taking the top twelve for each
    // produced near-identical lists. A library with real spread, so the two
    // have somewhere to diverge to.
    var spread: [Track] = []
    for a in 0..<40 {
        for i in 0..<6 {
            var t = Track(path: "/m/\(a)/\(i).mp3",
                          meta: MetadataParser.assemble(title: "S\(a)-\(i)",
                                                        artist: "Band \(a)",
                                                        album: "Rec \(a)"))
            var v = [Float](repeating: 0, count: 200)
            for d in 0..<200 { v[d] = Float(sin(Double(a) * 0.3 + Double(d) * 0.05)) }
            v[0] += Float(i) * 0.01
            let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
            t.embedding = v.map { $0 / n }
            spread.append(t)
        }
    }
    let seedT = spread[0]
    let similarQ = Radio.neighbours(of: seedT, in: spread, count: 12,
                                    maxPerAlbum: 3, maxPerArtist: 3).map(\.id)
    let continuousQ = Radio.continuousOpening(seed: seedT, in: spread, count: 12)
    let shared = Set(similarQ).intersection(Set(continuousQ)).count
    check("the two radio modes do not give the same queue", shared <= 4,
          "\(shared) of 12 tracks in common")
    check("a continuous opening fans out rather than clustering",
          Set(continuousQ).count == continuousQ.count, "\(continuousQ.count) picks")
}

// --------------------------------------------------------------- queue ----
section("R2 R3 R4  queue, shuffle, repeat")

let ids = (0..<6).map { _ in UUID() }
var q = PlayQueue()

// R4.1: tap a song inside an album, continue through the rest of it
q.load(ids, startAt: ids[2], origin: .album("Possession"))
check("album load starts on the tapped track", q.current == ids[2])
check("rest of album is queued after it", Array(q.upNext) == Array(ids[3...]))

q.advance()
check("advance moves to the next track", q.current == ids[3])

// R3.2 play next
q.playNext([ids[5]])
check("play next inserts right after current", q.items[q.currentIndex! + 1] == ids[5])

// R3.3 add to queue appends last
let tail = UUID()
q.addToQueue([tail])
check("add to queue appends to the end", q.items.last == tail)

// R2.3 repeat
var r = PlayQueue()
r.load(ids)
r.jump(to: ids.last!)
check("repeat off stops at the end", r.peekNext() == nil)
r.repeatMode = .all
check("repeat all wraps to the start", r.peekNext() == ids.first)
r.repeatMode = .one
check("repeat one stays put", r.peekNext() == ids.last)
check("skip forward overrides repeat one", { var c = r; return c.skipForward() == ids.first }())

// R2.2 shuffle
var s = PlayQueue()
s.load(ids, startAt: ids[3])
let before = s.current
s.setShuffled(true)
check("shuffle keeps the current track playing", s.current == before)
check("shuffle keeps every track", Set(s.items) == Set(ids))
s.setShuffled(false)
check("unshuffle restores the original order", s.items == ids)
check("unshuffle still on the same track", s.current == before)

// queue edits keep the pointer honest
var e = PlayQueue()
e.load(ids, startAt: ids[3])
e.remove(at: IndexSet(integer: 0))
check("removing an earlier track keeps current", e.current == ids[3])
e.move(from: IndexSet(integer: 0), to: 3)
check("reordering keeps current", e.current == ids[3])

// ------------------------------------------------- end-to-end, real files ----
section("End to end: real audio files through the Swift chain")

// Python decoded with ffmpeg; Swift decodes with AVAudioConverter. Different
// resamplers, so this will not be bit-identical. What must hold is that the
// resulting vectors still point the same way, and that a track is far closer to
// its own Python vector than to any other track's.
if let text = try? String(contentsOfFile: jsonlPath, encoding: .utf8) {
    struct Row: Decodable { let path: String; let name: String; let embedding: [Float] }
    let dec = JSONDecoder()
    var rows: [Row] = []
    for line in text.split(separator: "\n") {
        if let d = line.data(using: .utf8), let r = try? dec.decode(Row.self, from: d) {
            rows.append(r)
        }
    }

    // A handful spread across formats and languages.
    let picks = [rows.first(where: { $0.name.hasSuffix(".flac") }),
                 rows.first(where: { $0.name.hasSuffix(".mp3") }),
                 rows.first(where: { $0.name.hasSuffix(".m4a") }),
                 rows.first(where: { $0.name.contains("路傍") })]
        .compactMap { $0 }

    if picks.isEmpty {
        check("found real files to test", false)
    } else if let embedder = try? Embedder(modelPath: modelPath, useCoreML: false) {
        let engine = MelSpectrogram()
        var selfSims: [Float] = []
        var crossMax: Float = -1

        for pick in picks {
            let url = URL(fileURLWithPath: pick.path)
            guard FileManager.default.fileExists(atPath: pick.path) else {
                check("file present: \(pick.name.prefix(30))", false); continue
            }
            do {
                let t0 = Date()
                let audio = try AudioDecoder.decode(url: url)
                guard let (p, n) = engine.patches(audio) else {
                    check("patches from \(pick.name.prefix(26))", false); continue
                }
                let vec = try embedder.embed(patches: p, count: n)
                let dt = Date().timeIntervalSince(t0)

                var dot: Float = 0
                for i in 0..<min(vec.count, pick.embedding.count) {
                    dot += vec[i] * pick.embedding[i]
                }
                selfSims.append(dot)
                // Threshold is 0.93, not 0.99: Python decoded via ffmpeg's
                // swresample and Swift via AVAudioConverter, and the two
                // resamplers differ slightly. What matters for the app is that
                // every on-device vector comes from this one decoder, so the
                // library stays internally consistent.
                check("real file matches its Python vector: \(pick.name.prefix(26))",
                      dot > 0.93,
                      String(format: "cos %.4f  %d patches  %.0f ms  (%.0fx realtime)",
                             dot, n, dt * 1000,
                             (Double(audio.count) / 16000.0) / max(dt, 0.001)))

                // Rank every Python vector against this Swift vector. The file's
                // own vector should be at or near the top; exact duplicates in
                // the library legitimately tie with it.
                var ranked: [(String, Float)] = []
                for other in rows {
                    var d: Float = 0
                    for i in 0..<min(vec.count, other.embedding.count) {
                        d += vec[i] * other.embedding[i]
                    }
                    ranked.append((other.path, d))
                    if other.path != pick.path { crossMax = max(crossMax, d) }
                }
                ranked.sort { $0.1 > $1.1 }
                let rank = (ranked.firstIndex { $0.0 == pick.path } ?? 999) + 1
                let aboveAreDuplicates = ranked.prefix(rank - 1).allSatisfy { $0.1 > 0.999 }
                check("its own vector ranks first (ties only from duplicates)",
                      rank == 1 || aboveAreDuplicates,
                      "rank \(rank) of \(ranked.count)")
            } catch {
                check("decode+embed \(pick.name.prefix(26))", false, "\(error)")
            }
        }

        if let worstSelf = selfSims.min(), let bestSelf = selfSims.max() {
            check("all real files agree with the reference",
                  worstSelf > 0.93,
                  String(format: "worst %.4f  best %.4f across %d files",
                         worstSelf, bestSelf, selfSims.count))
            // Not an assertion: crossMax hits 1.0 because the library really does
            // contain the same recording filed under two albums, which the
            // embedding correctly identifies as identical.
            print(String(format: "  [note] closest non-self vector: %.4f (duplicate audio in library)",
                         crossMax))
        }
    } else {
        check("embedder available for end-to-end", false)
    }
}

// ------------------------------------------------------- upgrade safety ----
section("Upgrade: a new build must find the existing library")

do {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bummy-upgrade-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }

    // A library as it would exist after a long analysis run.
    func makeTracks(_ n: Int) -> [Track] {
        (0..<n).map { i in
            var t = Track(path: "/music/track\(i).flac",
                          meta: MetadataParser.assemble(title: "Track \(i)",
                                                        artist: "Artist \(i % 4)",
                                                        album: "Album \(i % 3)"))
            t.embedding = (0..<200).map { d in
                Float(sin(Double(i * 200 + d)) )
            }
            return t
        }
    }
    let original = makeTracks(40)
    let store = LibraryStore()
    store.replaceAll(original)
    try store.save(to: tmp)

    check("save produced a metadata file and an embedding sidecar",
          FileManager.default.fileExists(atPath: Store.metadataURL(tmp).path)
          && FileManager.default.fileExists(atPath: Store.embeddingsURL(tmp).path))

    // 1. Plain reinstall: same code, existing data.
    let reload = LibraryStore()
    let r1 = reload.load(from: tmp)
    if case .loaded(let tracks, _) = r1 {
        check("reinstall keeps every track", tracks.count == original.count,
              "\(tracks.count)/\(original.count)")
        check("reinstall keeps every embedding",
              tracks.allSatisfy { $0.isAnalysed },
              "\(tracks.filter(\.isAnalysed).count) analysed")
        let a = tracks.first(where: { $0.path == original[7].path })?.embedding ?? []
        let b = original[7].embedding ?? []
        check("embeddings survive byte-exact",
              a.count == b.count && zip(a, b).allSatisfy { $0 == $1 })
    } else {
        check("reinstall loaded", false)
    }

    // 2. The dangerous case: a schema change makes metadata undecodable.
    //    The analysis must not be lost.
    try Data("{\"version\":99,\"totally\":\"different\"}".utf8)
        .write(to: Store.metadataURL(tmp))
    try? FileManager.default.removeItem(at: Store.backupURL(tmp))

    let broken = LibraryStore()
    switch broken.load(from: tmp) {
    case .recovered(let embeddings, _):
        check("broken metadata still yields every embedding",
              embeddings.count == original.count,
              "\(embeddings.count) vectors recovered")
        // Re-import rebuilds metadata; vectors re-attach by path.
        let reimported = original.map {
            Track(path: $0.path, meta: $0.meta)      // no embedding
        }
        broken.replaceAll(reimported)
        broken.attach(embeddings: embeddings)
        check("re-import re-attaches analysis by path",
              broken.tracks.allSatisfy { $0.isAnalysed },
              "\(broken.tracks.filter(\.isAnalysed).count)/\(original.count) re-attached")
    default:
        check("broken metadata recovered its embeddings", false)
    }

    // 3. A file written by an older build (bare array, no envelope) still loads.
    let legacyDir = tmp.appendingPathComponent("legacy")
    try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
    var slim = original
    for i in slim.indices { slim[i].embedding = nil }
    try JSONEncoder().encode(slim).write(to: Store.metadataURL(legacyDir))
    try Store.writeEmbeddings(
        Dictionary(uniqueKeysWithValues: original.map { ($0.path, $0.embedding!) }),
        to: Store.embeddingsURL(legacyDir))

    let legacy = LibraryStore()
    if case .loaded(let tracks, let version) = legacy.load(from: legacyDir) {
        check("pre-envelope file still loads", tracks.count == original.count,
              "version reported \(version)")
        check("legacy load re-attaches embeddings",
              tracks.allSatisfy { $0.isAnalysed })
    } else {
        check("pre-envelope file loads", false)
    }

    // 4. A corrupt primary falls back to the backup rather than losing data.
    let bakDir = tmp.appendingPathComponent("bak")
    try FileManager.default.createDirectory(at: bakDir, withIntermediateDirectories: true)
    let s2 = LibraryStore(); s2.replaceAll(original)
    try s2.save(to: bakDir)                 // writes primary
    try s2.save(to: bakDir)                 // second save creates the backup
    try Data("garbage".utf8).write(to: Store.metadataURL(bakDir))
    let fromBackup = LibraryStore()
    if case .loaded(let tracks, _) = fromBackup.load(from: bakDir) {
        check("corrupt primary falls back to the backup",
              tracks.count == original.count, "\(tracks.count) tracks")
    } else {
        check("corrupt primary falls back to the backup", false)
    }
    // 5. The container gets renamed and every path in the library changes.
    //    The vectors must survive that, because they are the only part that
    //    costs hours to rebuild.
    let movedDir = tmp.appendingPathComponent("moved")
    try FileManager.default.createDirectory(at: movedDir, withIntermediateDirectories: true)
    let before = makeTracks(24)
    let s3 = LibraryStore(); s3.replaceAll(before)
    try s3.save(to: movedDir)

    // Rewrite the metadata as if the whole library had moved, leaving the
    // sidecar keyed on the old paths.
    if let data = try? Data(contentsOf: Store.metadataURL(movedDir)),
       var env = try? JSONDecoder().decode(Store.Envelope.self, from: data) {
        for i in env.tracks.indices {
            let name = (env.tracks[i].path as NSString).lastPathComponent
            env.tracks[i].path = "/somewhere/else/music/\(name)"
        }
        try JSONEncoder().encode(env).write(to: Store.metadataURL(movedDir))
    }

    let moved = LibraryStore()
    if case .loaded(let tracks, _) = moved.load(from: movedDir) {
        check("a moved library keeps its embeddings",
              tracks.allSatisfy { $0.isAnalysed },
              "\(tracks.filter(\.isAnalysed).count) of \(tracks.count) still analysed")
    } else {
        check("a moved library loads", false)
    }

    // 6. Appending vectors keeps every earlier one and supersedes a repeat.
    //    This is the path analysis takes between tracks, so a mistake here
    //    costs hours of work rather than a redraw.
    let appDir = tmp.appendingPathComponent("append")
    try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
    let dim = Embedder.embeddingDim
    var seedVectors: [String: [Float]] = [:]
    for i in 0..<3 {
        seedVectors["/seed/\(i).mp3"] = (0..<dim).map { _ in Float(i) }
    }
    try Store.writeEmbeddings(seedVectors, to: Store.embeddingsURL(appDir))

    let appended: [(path: String, vec: [Float])] = [
        ("/fresh/a.mp3", [Float](repeating: 9, count: dim)),
        ("/fresh/b.mp3", [Float](repeating: 8, count: dim)),
        ("/seed/1.mp3",  [Float](repeating: 7, count: dim)),   // supersedes
    ]
    let ok = Store.appendEmbeddings(appended, toDirectory: appDir)
    check("append reports success", ok)

    let back = try Store.readEmbeddings(from: Store.embeddingsURL(appDir))
    check("append keeps every earlier vector",
          back["/seed/0.mp3"]?.first == 0 && back["/seed/2.mp3"]?.first == 2,
          "\(back.count) records")
    check("append adds the new vectors",
          back["/fresh/a.mp3"]?.first == 9 && back["/fresh/b.mp3"]?.first == 8)
    check("a repeated path takes the appended value",
          back["/seed/1.mp3"]?.first == 7,
          "got \(back["/seed/1.mp3"]?.first ?? -1)")
    check("append leaves no other rows behind", back.count == 5, "\(back.count)")

    // Appending to a file that does not exist must report failure, not crash,
    // so the caller knows to write a whole one.
    let missing = tmp.appendingPathComponent("nowhere")
    check("append to a missing sidecar reports failure",
          Store.appendEmbeddings(appended, toDirectory: missing) == false)
} catch {
    check("upgrade-safety suite ran", false, "\(error)")
}

// ---------------------------------------------------------------- result ----
print("\n" + String(repeating: "=", count: 66))
print("\(checks - failures)/\(checks) checks passed")
if failures > 0 { print("FAILED"); exit(1) }
print("ALL PASS")
