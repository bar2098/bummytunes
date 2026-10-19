import Foundation

/// Upgrade-safe persistence.
///
/// The app is meant to be replaced often: build a new IPA, drop it into
/// LiveContainer, keep going. LiveContainer preserves the data container across
/// a bundle replacement, so the risk is not the installer — it is this code.
///
/// Two rules make an upgrade safe:
///
///  1. **Embeddings never live in the same file as metadata.** Metadata is
///     cheap to rebuild (re-read tags, seconds). Embeddings cost hours of
///     on-device analysis. They go in a binary sidecar keyed by file path, with
///     a format that owes nothing to the Swift types, so no amount of model
///     churn can invalidate them.
///  2. **A failed decode never destroys anything.** The old file is kept, a
///     backup is taken before any write, and a library that cannot be read is
///     rebuilt from the folder while the embeddings are re-attached by path.
public enum Store {

    public static let metadataVersion = 1
    private static let embeddingMagic: UInt32 = 0x424D5945      // "BMYE"
    private static let embeddingVersion: UInt32 = 1

    // MARK: - Metadata

    /// Versioned envelope. New fields must be optional so an older file still
    /// decodes; a renamed or retyped field means bumping `version` and adding a
    /// migration below rather than silently failing.
    public struct Envelope: Codable {
        public var version: Int
        public var savedAt: Date
        public var tracks: [Track]
        public init(version: Int = Store.metadataVersion,
                    savedAt: Date = Date(), tracks: [Track]) {
            self.version = version; self.savedAt = savedAt; self.tracks = tracks
        }
    }

    public enum LoadResult {
        case loaded(tracks: [Track], version: Int)
        /// Metadata was unreadable. Embeddings that survived are returned so the
        /// caller can re-import the folder and re-attach them by path.
        case recovered(embeddings: [String: [Float]], reason: String)
        case empty
    }

    public static func save(_ tracks: [Track], to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Embeddings first: if the process dies between the two writes, the
        // expensive half is already safe on disk.
        var vectors: [String: [Float]] = [:]
        for t in tracks where t.embedding != nil { vectors[t.path] = t.embedding }
        try writeEmbeddings(vectors, to: embeddingsURL(dir))

        // Metadata carries no embeddings; they would only duplicate the sidecar.
        var slim = tracks
        for i in slim.indices { slim[i].embedding = nil }

        let data = try JSONEncoder().encode(Envelope(tracks: slim))
        // Rotate the old file into place as the backup by renaming it, not by
        // copying it. On a seven-thousand-track library the metadata file is
        // tens of megabytes, and copying it doubled the cost of every save.
        // A rename is a directory operation, and the write below is atomic, so
        // the worst case is a moment where only the backup exists, which is
        // exactly what `load` falls back to.
        let url = metadataURL(dir)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: backupURL(dir))
            do { try FileManager.default.moveItem(at: url, to: backupURL(dir)) }
            catch { try? FileManager.default.copyItem(at: url, to: backupURL(dir)) }
        }
        try data.write(to: url, options: .atomic)
    }

    /// Write only the embedding sidecar.
    ///
    /// Used while analysis runs: metadata has not changed, and the sidecar is
    /// the half that is expensive to lose.
    public static func saveEmbeddings(_ tracks: [Track], to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var vectors: [String: [Float]] = [:]
        for t in tracks where t.embedding != nil { vectors[t.path] = t.embedding }
        try writeEmbeddings(vectors, to: embeddingsURL(dir))
    }

    public static func load(from dir: URL) -> LoadResult {
        let vectors = (try? readEmbeddings(from: embeddingsURL(dir))) ?? [:]

        for candidate in [metadataURL(dir), backupURL(dir)] {
            guard let data = try? Data(contentsOf: candidate) else { continue }
            do {
                var tracks: [Track]
                var version = metadataVersion

                if let env = try? JSONDecoder().decode(Envelope.self, from: data) {
                    tracks = env.tracks
                    version = env.version
                } else {
                    // Pre-envelope format: a bare array of tracks.
                    tracks = try JSONDecoder().decode([Track].self, from: data)
                    version = 0
                }

                // Re-attach embeddings by path, so a track keeps its vector even
                // if its id was regenerated by a re-import.
                //
                // And by album folder plus file name when the path has moved.
                // A container can be given a new name, which rewrites every
                // path in the library; if the sidecar and the metadata file are
                // ever written either side of that, matching on path alone
                // silently loses every vector and costs hours of analysis. The
                // tail survives the move, so it is the fallback.
                var byTail: [String: [Float]] = [:]
                byTail.reserveCapacity(vectors.count)
                for (path, vec) in vectors {
                    byTail[LibraryImporter.tailKey(forStoredPath: path)] = vec
                }
                for i in tracks.indices where tracks[i].embedding == nil {
                    if let v = vectors[tracks[i].path] {
                        tracks[i].embedding = v
                    } else {
                        tracks[i].embedding =
                            byTail[LibraryImporter.tailKey(forStoredPath: tracks[i].path)]
                    }
                }
                return .loaded(tracks: tracks, version: version)
            } catch {
                continue        // try the backup before giving up
            }
        }

        if !vectors.isEmpty {
            return .recovered(embeddings: vectors,
                              reason: "metadata unreadable; \(vectors.count) embeddings kept")
        }
        return .empty
    }

    // MARK: - Embedding sidecar

    /// Flat binary, deliberately not Codable:
    ///   magic u32 | version u32 | count u32 | dim u32
    ///   then per record: pathBytes u32 | path utf8 | dim × f32
    ///
    /// A format this dumb cannot be broken by renaming a Swift property, which
    /// is the entire point.
    public static func writeEmbeddings(_ vectors: [String: [Float]], to url: URL) throws {
        let dim = vectors.values.first?.count ?? Embedder.embeddingDim
        var out = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { out.append(contentsOf: $0) } }

        put(embeddingMagic.littleEndian)
        put(embeddingVersion.littleEndian)
        put(UInt32(vectors.count).littleEndian)
        put(UInt32(dim).littleEndian)

        for (path, vec) in vectors {
            guard vec.count == dim, let p = path.data(using: .utf8) else { continue }
            put(UInt32(p.count).littleEndian)
            out.append(p)
            vec.withUnsafeBufferPointer { out.append(contentsOf: UnsafeRawBufferPointer($0)) }
        }
        try out.write(to: url, options: .atomic)
    }

    /// Append new vectors to an existing sidecar.
    ///
    /// Rewriting the whole file between analysed tracks meant writing the
    /// entire set of vectors hundreds of times over a run, which on a large
    /// library is gigabytes of writes for a few kilobytes of new data. Records
    /// are sequential and the reader takes the last one for a given path, so
    /// appending is both cheap and correct.
    ///
    /// Returns false when there is no usable file yet, so the caller can fall
    /// back to writing one in full.
    @discardableResult
    public static func appendEmbeddings(_ vectors: [(path: String, vec: [Float])],
                                        toDirectory dir: URL) -> Bool {
        guard !vectors.isEmpty else { return true }
        let url = embeddingsURL(dir)
        guard let h = try? FileHandle(forUpdating: url) else { return false }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 16), head.count == 16 else { return false }

        func word(_ offset: Int) -> UInt32 {
            UInt32(littleEndian: head.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            })
        }
        guard word(0) == embeddingMagic, word(4) <= embeddingVersion else { return false }
        var count = word(8)
        let dim = Int(word(12))
        guard dim > 0, dim <= 4096 else { return false }

        var out = Data()
        var added: UInt32 = 0
        for (path, vec) in vectors {
            guard vec.count == dim, let p = path.data(using: .utf8) else { continue }
            withUnsafeBytes(of: UInt32(p.count).littleEndian) { out.append(contentsOf: $0) }
            out.append(p)
            vec.withUnsafeBufferPointer { out.append(contentsOf: UnsafeRawBufferPointer($0)) }
            added += 1
        }
        guard added > 0 else { return true }

        do {
            try h.seekToEnd()
            try h.write(contentsOf: out)
            count &+= added
            try h.seek(toOffset: 8)
            try h.write(contentsOf: withUnsafeBytes(of: count.littleEndian) { Data($0) })
        } catch {
            return false
        }
        return true
    }

    public static func readEmbeddings(from url: URL) throws -> [String: [Float]] {
        let data = try Data(contentsOf: url)
        var o = 0
        func take<T>(_ t: T.Type) -> T? {
            let n = MemoryLayout<T>.size
            guard o + n <= data.count else { return nil }
            defer { o += n }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: T.self) }
        }

        guard let magic = take(UInt32.self), UInt32(littleEndian: magic) == embeddingMagic,
              let ver = take(UInt32.self), UInt32(littleEndian: ver) <= embeddingVersion,
              let count = take(UInt32.self), let dimRaw = take(UInt32.self) else { return [:] }
        let dim = Int(UInt32(littleEndian: dimRaw))
        guard dim > 0, dim <= 4096 else { return [:] }

        var out: [String: [Float]] = [:]
        out.reserveCapacity(Int(UInt32(littleEndian: count)))

        for _ in 0..<Int(UInt32(littleEndian: count)) {
            guard let lenRaw = take(UInt32.self) else { break }
            let len = Int(UInt32(littleEndian: lenRaw))
            guard len > 0, len < 8192, o + len <= data.count else { break }
            let path = String(decoding: data[(data.startIndex + o)..<(data.startIndex + o + len)],
                              as: UTF8.self)
            o += len
            let bytes = dim * MemoryLayout<Float>.size
            guard o + bytes <= data.count else { break }
            var vec = [Float](repeating: 0, count: dim)
            _ = vec.withUnsafeMutableBytes { dst in
                data.copyBytes(to: dst,
                               from: (data.startIndex + o)..<(data.startIndex + o + bytes))
            }
            o += bytes
            out[path] = vec
        }
        return out
    }

    /// What is actually on disk, for the diagnostics panel. Silent persistence
    /// failures are the worst kind, so this makes the state visible instead of
    /// leaving "it re-read my tags" as a mystery.
    public struct Diagnosis: Sendable {
        public var metadataExists = false
        public var metadataBytes = 0
        public var metadataModified: Date?
        public var backupExists = false
        public var embeddingsExist = false
        public var embeddingsBytes = 0
        public var embeddingCount = 0
        public var decodedTracks: Int?
        public var decodeError: String?
        public var directory = ""
    }

    public static func diagnose(_ dir: URL) -> Diagnosis {
        var d = Diagnosis()
        d.directory = dir.path
        let fm = FileManager.default

        if let a = try? fm.attributesOfItem(atPath: metadataURL(dir).path) {
            d.metadataExists = true
            d.metadataBytes = (a[.size] as? Int) ?? 0
            d.metadataModified = a[.modificationDate] as? Date
        }
        d.backupExists = fm.fileExists(atPath: backupURL(dir).path)
        if let a = try? fm.attributesOfItem(atPath: embeddingsURL(dir).path) {
            d.embeddingsExist = true
            d.embeddingsBytes = (a[.size] as? Int) ?? 0
        }
        d.embeddingCount = ((try? readEmbeddings(from: embeddingsURL(dir))) ?? [:]).count

        if d.metadataExists, let data = try? Data(contentsOf: metadataURL(dir)) {
            do {
                if let env = try? JSONDecoder().decode(Envelope.self, from: data) {
                    d.decodedTracks = env.tracks.count
                } else {
                    d.decodedTracks = try JSONDecoder().decode([Track].self, from: data).count
                }
            } catch {
                d.decodeError = String(describing: error).prefix(160).description
            }
        }
        return d
    }

    // MARK: - Paths

    public static func metadataURL(_ dir: URL) -> URL { dir.appendingPathComponent("library.json") }
    public static func backupURL(_ dir: URL) -> URL { dir.appendingPathComponent("library.backup.json") }
    public static func embeddingsURL(_ dir: URL) -> URL { dir.appendingPathComponent("embeddings.bin") }
}
