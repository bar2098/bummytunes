import Foundation

/// Playback queue (R2, R3, R4).
///
/// Pure value logic with no AVFoundation, so every rule here is testable on
/// macOS: what "play next" inserts, where "add to queue" appends, how shuffle
/// preserves the current track, and how repeat wraps.
public struct PlayQueue: Sendable, Equatable {

    public enum RepeatMode: String, Codable, Sendable, CaseIterable {
        case off, all, one
        public var next: RepeatMode {
            switch self { case .off: return .all; case .all: return .one; case .one: return .off }
        }
    }

    /// How a radio picks what comes next.
    ///
    /// Mirrors the two behaviours Jellyfin clients expose. `similar` orbits one
    /// seed: everything in the queue is a neighbour of the track you started
    /// from, so it stays close to that sound. `continuous` re-seeds off each
    /// track as it plays, so the selection drifts and walks across the library
    /// instead of circling one point.
    public enum RadioMode: String, Codable, Sendable, CaseIterable {
        case similar, continuous
        public var label: String { self == .similar ? "SIMILAR" : "CONTINUOUS" }
        public var blurb: String {
            self == .similar ? "Everything close to one track"
                             : "Drifts, re-seeding on each song"
        }
        public var next: RadioMode { self == .similar ? .continuous : .similar }
    }

    /// Where a queue came from, so the UI can say "Radio from X" or "Album Y".
    public enum Origin: Equatable, Sendable {
        case none
        case album(String)
        case artist(String)
        case radio(seed: UUID, title: String, mode: RadioMode)
        case shuffleAll
        case search
    }

    /// True when this queue is a radio that should keep extending itself.
    public var isContinuousRadio: Bool {
        if case .radio(_, _, let mode) = origin { return mode == .continuous }
        return false
    }

    /// Everything already queued, so a continuous radio does not repeat itself.
    public var seen: Set<UUID> { Set(items) }

    /// Append tracks a continuous radio has drifted onto.
    public mutating func extend(_ ids: [UUID]) {
        let known = seen
        items.append(contentsOf: ids.filter { !known.contains($0) })
        unshuffled = items
    }

    /// Drop already-played history so a long continuous radio does not grow
    /// without bound. Keeps a short tail so Previous still works.
    public mutating func trimHistory(keeping tail: Int = 20) {
        guard let i = currentIndex, i > tail else { return }
        let drop = i - tail
        items.removeFirst(drop)
        unshuffled = items
        currentIndex = i - drop
    }

    /// The playing order. Under shuffle this is the shuffled order, so the
    /// queue you see is always the queue that plays.
    public private(set) var items: [UUID] = []
    /// Index into `items`, or nil when nothing is loaded.
    public private(set) var currentIndex: Int?
    public var repeatMode: RepeatMode = .off
    public private(set) var isShuffled = false
    /// Original order, kept so turning shuffle off restores it.
    private var unshuffled: [UUID] = []
    public var origin: Origin = .none

    public init() {}

    public var current: UUID? {
        guard let i = currentIndex, items.indices.contains(i) else { return nil }
        return items[i]
    }
    public var count: Int { items.count }
    public var upNext: ArraySlice<UUID> {
        guard let i = currentIndex, i + 1 < items.count else { return [] }
        return items[(i + 1)...]
    }

    // MARK: - Loading

    /// Replace the queue and start at `startAt`.
    ///
    /// This is R4.1: tapping a song inside an album loads the whole album and
    /// starts there, so playback continues through the rest of it.
    public mutating func load(_ ids: [UUID], startAt: UUID? = nil, origin: Origin = .none) {
        unshuffled = ids
        items = ids
        isShuffled = false
        self.origin = origin
        currentIndex = startAt.flatMap { ids.firstIndex(of: $0) } ?? (ids.isEmpty ? nil : 0)
    }

    /// Load already-shuffled, keeping `first` at the front. Used by the random
    /// button (R2.4) and by shuffle-all.
    public mutating func loadShuffled(_ ids: [UUID], first: UUID? = nil,
                                      origin: Origin = .shuffleAll) {
        var rest = ids.shuffled()
        if let f = first {
            rest.removeAll { $0 == f }
            rest.insert(f, at: 0)
        }
        unshuffled = ids
        items = rest
        isShuffled = true
        self.origin = origin
        currentIndex = rest.isEmpty ? nil : 0
    }

    // MARK: - Queue edits (R3)

    /// Insert directly after the current track.
    public mutating func playNext(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let at = (currentIndex.map { $0 + 1 }) ?? items.count
        items.insert(contentsOf: ids, at: min(at, items.count))
        unshuffled.append(contentsOf: ids)
    }

    /// Append to the very end.
    public mutating func addToQueue(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        items.append(contentsOf: ids)
        unshuffled.append(contentsOf: ids)
        if currentIndex == nil { currentIndex = 0 }
    }

    // Implemented directly rather than via the SwiftUI collection helpers, so
    // the core stays free of any UI framework and builds on every platform.

    public mutating func remove(at offsets: IndexSet) {
        let currentID = currentIndex.flatMap { items.indices.contains($0) ? items[$0] : nil }
        for i in offsets.sorted(by: >) where items.indices.contains(i) {
            items.remove(at: i)
        }
        if items.isEmpty {
            currentIndex = nil
        } else if let c = currentID, let i = items.firstIndex(of: c) {
            currentIndex = i                       // still present, follow it
        } else {
            currentIndex = min(currentIndex ?? 0, items.count - 1)
        }
    }

    public mutating func move(from source: IndexSet, to destination: Int) {
        let currentID = currentIndex.flatMap { items.indices.contains($0) ? items[$0] : nil }
        let moving = source.sorted().compactMap { items.indices.contains($0) ? items[$0] : nil }
        // Where the block lands once the moved items are pulled out.
        let removedBefore = source.filter { $0 < destination }.count
        for i in source.sorted(by: >) where items.indices.contains(i) {
            items.remove(at: i)
        }
        let insertAt = max(0, min(destination - removedBefore, items.count))
        items.insert(contentsOf: moving, at: insertAt)
        currentIndex = currentID.flatMap { items.firstIndex(of: $0) } ?? currentIndex
    }

    // MARK: - Shuffle (R2.2)

    /// Toggling shuffle never changes what is playing now, only what follows.
    public mutating func setShuffled(_ on: Bool) {
        guard on != isShuffled else { return }
        let currentID = current
        if on {
            if unshuffled.isEmpty { unshuffled = items }
            var rest = items.shuffled()
            if let c = currentID {
                rest.removeAll { $0 == c }
                rest.insert(c, at: 0)
            }
            items = rest
            currentIndex = currentID == nil ? (items.isEmpty ? nil : 0) : 0
        } else {
            items = unshuffled.isEmpty ? items : unshuffled
            currentIndex = currentID.flatMap { items.firstIndex(of: $0) }
                ?? (items.isEmpty ? nil : 0)
        }
        isShuffled = on
    }

    // MARK: - Transport (R2.3)

    /// The track that follows, honouring repeat. Nil means playback stops.
    public func peekNext() -> UUID? {
        guard let i = currentIndex, !items.isEmpty else { return nil }
        if repeatMode == .one { return items[i] }
        if i + 1 < items.count { return items[i + 1] }
        return repeatMode == .all ? items.first : nil
    }

    @discardableResult
    public mutating func advance() -> UUID? {
        guard let i = currentIndex, !items.isEmpty else { return nil }
        if repeatMode == .one { return items[i] }
        if i + 1 < items.count { currentIndex = i + 1; return items[i + 1] }
        if repeatMode == .all { currentIndex = 0; return items.first }
        return nil
    }

    /// Skipping forward ignores repeat-one: the user asked for a different track.
    @discardableResult
    public mutating func skipForward() -> UUID? {
        guard let i = currentIndex, !items.isEmpty else { return nil }
        if i + 1 < items.count { currentIndex = i + 1; return items[i + 1] }
        if repeatMode != .off { currentIndex = 0; return items.first }
        return nil
    }

    @discardableResult
    public mutating func skipBackward() -> UUID? {
        guard let i = currentIndex, !items.isEmpty else { return nil }
        if i > 0 { currentIndex = i - 1; return items[i - 1] }
        if repeatMode == .all { currentIndex = items.count - 1; return items.last }
        currentIndex = 0
        return items.first
    }

    public mutating func jump(to id: UUID) {
        if let i = items.firstIndex(of: id) { currentIndex = i }
    }
}
