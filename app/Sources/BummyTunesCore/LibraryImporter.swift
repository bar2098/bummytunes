import Foundation

/// Folder import (R8).
///
/// The user picks a folder in the system file browser; this walks it, reads
/// metadata, and stores a security-scoped bookmark so access survives relaunch.
public enum LibraryImporter {

    /// Formats the platform can actually decode.
    ///
    /// Ogg Vorbis, Opus and WMA are left out on purpose: AVFoundation cannot
    /// open any of them, so importing them only puts tracks in the library
    /// that will never play and can never be analysed. On a 118,000-file
    /// library they numbered 59.
    public static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "alac"
    ]

    public struct ImportResult: Sendable {
        public var tracks: [Track]
        public var scanned: Int
        public var skipped: Int
        /// Bookmark to the folder the user picked, so its security scope can be
        /// held open for the life of the app rather than reopened per file.
        public var rootBookmark: Data?
    }

    /// Security scope for imported folders.
    ///
    /// iOS only lets a sandboxed app read a picked folder while its scope is
    /// open. Opening it per file works for playback but not for everything
    /// else: reading a directory to find cover.jpg came back empty unless a
    /// track happened to be playing, which is exactly why artwork appeared only
    /// after starting something. Holding the root open at launch makes reads
    /// behave the same whether or not audio is playing.
    public final class RootAccess: @unchecked Sendable {
        public static let shared = RootAccess()
        private var open: [URL] = []
        private let lock = NSLock()

        /// Resolve stored bookmarks and keep their scopes open.
        @discardableResult
        public func open(bookmarks: [Data]) -> Int {
            lock.lock(); defer { lock.unlock() }
            var count = 0
            for data in bookmarks {
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: data,
                                         options: resolutionOptions,
                                         relativeTo: nil,
                                         bookmarkDataIsStale: &stale) else { continue }
                if url.startAccessingSecurityScopedResource() {
                    open.append(url)
                    count += 1
                }
            }
            return count
        }

        public func closeAll() {
            lock.lock(); defer { lock.unlock() }
            for u in open { u.stopAccessingSecurityScopedResource() }
            open.removeAll()
        }

        private var resolutionOptions: URL.BookmarkResolutionOptions {
            #if os(iOS)
            return []
            #else
            return [.withSecurityScope]
            #endif
        }
    }

    /// Directories that hold machine-generated duplicates rather than music.
    ///
    /// Synology NAS shares scatter `@eaDir` folders containing thumbnail copies
    /// of every file, including playable duplicates of the audio. Importing
    /// those doubles the library with junk, and this library has them.
    static let junkDirectories: Set<String> = [
        "@eadir", ".ds_store", "__macosx", ".trash", "#recycle",
        ".spotlight-v100", ".fseventsd", "lost+found"
    ]

    /// Recursively collect audio files under `folder`.
    public static func audioFiles(in folder: URL) -> [URL] {
        var out: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .nameKey]
        guard let e = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }

        for case let url as URL in e {
            let name = url.lastPathComponent.lowercased()

            // Prune junk directories rather than walking into them.
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if junkDirectories.contains(name) { e.skipDescendants() }
                continue
            }
            guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            // Belt and braces: a path that passed through one anyway.
            if url.pathComponents.contains(where: {
                junkDirectories.contains($0.lowercased())
            }) { continue }

            if let vals = try? url.resourceValues(forKeys: Set(keys)),
               vals.isRegularFile == true {
                out.append(url)
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Build tracks for a picked folder.
    /// - Parameter folderBookmark: bookmark for the folder itself. Individual
    ///   file bookmarks are derived from it so each file can be reopened later.
    /// A key that survives the library moving.
    ///
    /// The container an app's files live in can be given a new path, and the
    /// absolute paths stored at import time then point nowhere. The album
    /// folder and the file name together still identify a track, which is what
    /// keeps a rescan from importing the entire library again as duplicates.
    public static func tailKey(for url: URL) -> String {
        let file = url.lastPathComponent.lowercased()
        let folder = url.deletingLastPathComponent().lastPathComponent.lowercased()
        return "\(folder)/\(file)"
    }

    public static func tailKey(forStoredPath path: String) -> String {
        let ns = path as NSString
        let file = ns.lastPathComponent.lowercased()
        let folder = (ns.deletingLastPathComponent as NSString).lastPathComponent.lowercased()
        return "\(folder)/\(file)"
    }

    /// - Parameter skipping: paths already in the library, and their tail keys.
    ///   Filtered out before any tags are read, so a rescan of a folder that
    ///   has gained a handful of files costs a directory walk rather than a
    ///   full re-import.
    public static func importFolder(_ folder: URL,
                                    skipping: Set<String> = [],
                                    progress: (@Sendable (Int, Int) -> Void)? = nil)
        async -> ImportResult {

        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }

        var files = audioFiles(in: folder)
        let scanned = files.count
        if !skipping.isEmpty {
            files = files.filter {
                !skipping.contains(Track.portablePath(for: $0))
                    && !skipping.contains(tailKey(for: $0))
            }
        }
        let built = await build(files, bookmarked: true, progress: progress)
        let tracks = built.tracks
        let skipped = built.skipped

        let rootBookmark = try? folder.bookmarkData(
            options: bookmarkCreationOptions,
            includingResourceValuesForKeys: nil, relativeTo: nil)
        return ImportResult(tracks: tracks, scanned: scanned,
                            skipped: skipped, rootBookmark: rootBookmark)
    }

    /// The app's own Documents folder.
    ///
    /// Fallback path for when the system document picker will not open, which
    /// happens under LiveContainer unless "Fix File Picker" is enabled for the
    /// guest app. This folder is visible in Files under On My iPhone, so music
    /// can be dropped in directly, and because it is the app's own container it
    /// needs no security scope and no bookmarks at all.
    public static var documentsFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// How many audio files are sitting in the app's own Documents folder.
    /// Used to offer the fallback only when there is something to import.
    public static func documentsAudioCount() -> Int {
        audioFiles(in: documentsFolder).count
    }

    /// Import from the app's own Documents folder. No picker, no bookmarks.
    public static func importDocumentsFolder(
        skipping: Set<String> = [],
        progress: (@Sendable (Int, Int) -> Void)? = nil) async -> ImportResult {
        var files = audioFiles(in: documentsFolder)
        let scanned = files.count
        if !skipping.isEmpty {
            files = files.filter {
                !skipping.contains(Track.portablePath(for: $0))
                    && !skipping.contains(tailKey(for: $0))
            }
        }
        // No bookmarks: these paths are inside our own container and stay valid.
        let built = await build(files, bookmarked: false, progress: progress)
        return ImportResult(tracks: built.tracks, scanned: scanned,
                            skipped: built.skipped)
    }

    /// Tag reading, async on both platforms so the two import paths share code.
    private static func readMeta(_ url: URL) async -> TrackMetadata {
        #if os(iOS)
        return await MetadataParser.metadata(for: url)
        #else
        return MetadataParser.metadata(for: url)
        #endif
    }

    /// Build tracks for a list of files.
    ///
    /// Reading tags means opening each file, which is dominated by waiting on
    /// storage rather than by CPU, so a handful of files are read at once.
    /// Serially, a large folder took as long as the sum of every read.
    /// Progress is reported in batches: one callback per file meant tens of
    /// thousands of hops to the main actor, which is its own kind of slow.
    private static func build(_ files: [URL], bookmarked: Bool,
                              progress: (@Sendable (Int, Int) -> Void)?)
        async -> (tracks: [Track], skipped: Int) {

        guard !files.isEmpty else { return ([], 0) }
        let lanes = min(6, files.count)
        var slots = [Track?](repeating: nil, count: files.count)
        var skipped = 0
        var done = 0
        var step = max(1, files.count / 200)
        if step > 50 { step = 50 }

        await withTaskGroup(of: (Int, Track?).self) { group in
            var next = 0
            func launch(_ i: Int) {
                group.addTask {
                    let url = files[i]
                    let meta = await readMeta(url)
                    // A zero-duration file is unreadable; keep it out.
                    guard meta.duration > 0 else { return (i, nil) }
                    let bookmark = bookmarked
                        ? try? url.bookmarkData(options: bookmarkCreationOptions,
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil)
                        : nil
                    var t = Track(path: Track.portablePath(for: url),
                                  bookmark: bookmark, meta: meta)
                    t.addedAt = Date()
                    return (i, t)
                }
            }
            while next < lanes { launch(next); next += 1 }
            for await (i, t) in group {
                slots[i] = t
                if t == nil { skipped += 1 }
                done += 1
                if done % step == 0 || done == files.count {
                    progress?(done, files.count)
                }
                if next < files.count { launch(next); next += 1 }
            }
        }
        return (slots.compactMap { $0 }, skipped)
    }

    private static var bookmarkCreationOptions: URL.BookmarkCreationOptions {
        #if os(iOS)
        // iOS has no .withSecurityScope; the minimal bookmark is scoped already.
        return [.minimalBookmark]
        #else
        return [.withSecurityScope]
        #endif
    }
}
