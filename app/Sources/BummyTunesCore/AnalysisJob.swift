import Foundation

/// Library analysis (R6).
///
/// Resumable by construction: every finished track is persisted immediately, so
/// being killed costs one track rather than the whole run. That is not a
/// theoretical concern; the first Python pass over this library was killed for
/// memory at 883 of 1,009 and lost everything because it only wrote at the end.
public actor AnalysisJob {

    enum Failure: Error { case unusableAudio }

    public struct Progress: Sendable, Equatable {
        public var done: Int
        public var total: Int
        public var failed: Int
        public var currentTitle: String?
        public var isRunning: Bool
        public var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }

        public init(done: Int = 0, total: Int = 0, failed: Int = 0,
                    currentTitle: String? = nil, isRunning: Bool = false) {
            self.done = done; self.total = total; self.failed = failed
            self.currentTitle = currentTitle; self.isRunning = isRunning
        }
    }

    public enum Trigger: Sendable {
        /// User is watching the progress screen.
        case foreground
        /// Riding the audio background mode while music plays (R6.6). Runs at
        /// low priority with pauses, so analysis never starves playback.
        case duringPlayback
    }

    private let modelPath: String
    private let store: LibraryStore
    /// Full save, used once at the end of a run.
    private let persist: @Sendable () -> Void
    /// Flush of just the vectors produced since the last call. Analysis
    /// changes nothing but embeddings, and rewriting the whole library file
    /// between tracks was hundreds of megabytes of writes over a run.
    private let persistVectors: @Sendable ([(path: String, vec: [Float])]) -> Void
    private var embedder: Embedder?
    private let mel = MelSpectrogram()

    private var running = false
    private var cancelled = false
    private(set) public var progress = Progress(done: 0, total: 0, failed: 0,
                                                currentTitle: nil, isRunning: false)
    private var onProgress: (@Sendable (Progress) -> Void)?

    public init(modelPath: String, store: LibraryStore,
                persist: @escaping @Sendable () -> Void,
                persistVectors: (@Sendable ([(path: String, vec: [Float])]) -> Void)? = nil) {
        self.modelPath = modelPath
        self.store = store
        self.persist = persist
        self.persistVectors = persistVectors ?? { _ in persist() }
    }

    public func setProgressHandler(_ h: @escaping @Sendable (Progress) -> Void) {
        onProgress = h
    }

    public func cancel() { cancelled = true }

    /// Analyse everything that has no embedding yet.
    public func run(trigger: Trigger = .foreground) async {
        guard !running else { return }
        running = true
        cancelled = false

        do {
            if embedder == nil {
                embedder = try Embedder(modelPath: modelPath, useCoreML: true)
            }
        } catch {
            running = false
            return
        }

        let pending = store.tracks.filter { !$0.isAnalysed }
        progress = Progress(done: 0, total: pending.count, failed: 0,
                            currentTitle: nil, isRunning: true)
        onProgress?(progress)

        var fresh: [(path: String, vec: [Float])] = []
        var sinceSave = 0
        for track in pending {
            if cancelled { break }
            progress.currentTitle = track.meta.title
            onProgress?(progress)

            // Access the security-scoped resource for just this file (R8.4).
            var scoped: URL?
            if let data = track.bookmark {
                var stale = false
                if let u = try? URL(resolvingBookmarkData: data,
                                    options: bookmarkResolutionOptions,
                                    relativeTo: nil, bookmarkDataIsStale: &stale),
                   u.startAccessingSecurityScopedResource() {
                    scoped = u
                }
            }
            defer { scoped?.stopAccessingSecurityScopedResource() }

            do {
                let url = scoped ?? track.url
                // Everything for one track inside a pool.
                //
                // Decoding uses AVFoundation, which hands back autoreleased
                // objects, and a long-running Swift loop has no pool of its own
                // to drain them into. Over thousands of tracks that is a slow
                // climb in memory with no ceiling, which is how an overnight
                // run dies part way through and needs the app relaunched.
                let vec: [Float] = try autoreleasepool {
                    let audio = try AudioDecoder.decode(url: url)
                    guard let (patches, n) = mel.patches(audio) else {
                        throw Failure.unusableAudio
                    }
                    return try embedder!.embed(patches: patches, count: n)
                }
                store.setEmbedding(vec, for: track.id)
                fresh.append((track.path, vec))
                progress.done += 1
                sinceSave += 1
            } catch {
                progress.failed += 1
                progress.done += 1
            }

            // Persist often so a kill costs almost nothing.
            if sinceSave >= 10 {
                persistVectors(fresh)
                fresh.removeAll(keepingCapacity: true)
                sinceSave = 0
            }
            onProgress?(progress)

            if trigger == .duringPlayback {
                // Yield generously; playback owns the device.
                try? await Task.sleep(nanoseconds: 150_000_000)
            } else {
                await Task.yield()
            }
        }

        if !fresh.isEmpty { persistVectors(fresh) }
        persist()
        progress.isRunning = false
        progress.currentTitle = nil
        onProgress?(progress)
        running = false
    }

    private var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(iOS)
        return []
        #else
        return [.withSecurityScope]
        #endif
    }
}
