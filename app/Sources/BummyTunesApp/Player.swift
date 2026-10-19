import AVFoundation
import BummyTunesCore
import Foundation
import Observation
#if os(iOS)
import MediaPlayer
#endif

/// Playback engine (R2).
///
/// Feeds `MPNowPlayingInfoCenter`, which is what puts the track in the Dynamic
/// Island, on the lock screen and in Control Center. That presentation is a
/// system behaviour for any app holding an audio session, not a Live Activity,
/// so it works under LiveContainer where widget extensions do not.
@Observable
@MainActor
public final class Player {

    public private(set) var queue = PlayQueue()
    public private(set) var isPlaying = false
    public private(set) var currentTime: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var nowPlaying: Track?

    /// Set by the app so the player can resolve ids and read artwork.
    public var resolve: ((UUID) -> Track?)?
    /// Called when a track starts, so the app can update the map highlight.
    public var onTrackChange: ((Track?) -> Void)?

    private var player: AVAudioPlayer?
    private var ticker: Timer?
    private var scopedURL: URL?
    /// Bumped on every start. The finish callback carries the value it was
    /// created with, so a player that ends while the next track is already
    /// starting cannot advance the queue a second time and skip a song.
    private var playToken = 0

    /// Downmix stereo to mono on output.
    ///
    /// `AVAudioPlayer` has no downmix of its own, but the session can be asked
    /// for a single output channel, which makes the system fold the stereo image
    /// down for us. Falls back silently on hardware that will not take it.
    public var mono: Bool {
        get { UserDefaults.standard.bool(forKey: "audio.mono") }
        set {
            UserDefaults.standard.set(newValue, forKey: "audio.mono")
            applyMono()
        }
    }

    private func applyMono() {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        try? s.setPreferredOutputNumberOfChannels(mono ? 1 : s.maximumOutputNumberOfChannels)
        #endif
    }

    public init() {
        configureSession()
        configureRemoteCommands()
        applyMono()
    }

    // MARK: - Session

    private func configureSession() {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        // .playback keeps audio alive when the screen locks, which is also what
        // grants CPU time for analysis during playback (R6.6).
        try? s.setCategory(.playback, mode: .default, options: [])
        try? s.setActive(true)
        observeSession()
        #endif
    }

    /// Make the session current, and say whether it took.
    ///
    /// Called before every track rather than once at launch. A phone call, a
    /// video in another app, or the media server restarting all leave the
    /// session inactive, and `AVAudioPlayer.play()` then quietly returns false:
    /// the app looks like it is playing and no sound comes out.
    @discardableResult
    private func activateSession() -> Bool {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        if s.category != .playback {
            try? s.setCategory(.playback, mode: .default, options: [])
        }
        do { try s.setActive(true) } catch { return false }
        return true
        #else
        return true
        #endif
    }

    #if os(iOS)
    private func observeSession() {
        let nc = NotificationCenter.default
        let s = AVAudioSession.sharedInstance()

        nc.addObserver(forName: AVAudioSession.interruptionNotification,
                       object: s, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in
                guard let self else { return }
                switch type {
                case .began:
                    self.isPlaying = false
                    self.stopTicker()
                    self.updateNowPlayingInfo()
                default:
                    let opts = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    if AVAudioSession.InterruptionOptions(rawValue: opts).contains(.shouldResume) {
                        self.activateSession()
                        self.resume()
                    }
                }
            }
        }

        // Headphones pulled out: stop, the way every other player does.
        nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                       object: s, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
            else { return }
            Task { @MainActor in self?.pause() }
        }

        // The media server can restart underneath the app, which invalidates
        // the player and the session together.
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                       object: s, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                try? AVAudioSession.sharedInstance()
                    .setCategory(.playback, mode: .default, options: [])
                self.activateSession()
                self.applyMono()
                if self.isPlaying { self.startCurrent() }
            }
        }
    }
    #endif

    private func configureRemoteCommands() {
        #if os(iOS)
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }; return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }; return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }; return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }; return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }; return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in self?.seek(to: e.positionTime) }
            return .success
        }
        #endif
    }

    // MARK: - Transport

    public func play(queue newQueue: PlayQueue) {
        queue = newQueue
        startCurrent()
    }

    public func jump(to id: UUID) {
        queue.jump(to: id)
        startCurrent()
    }

    /// Start whatever the queue points at, skipping anything that will not open.
    ///
    /// A loop rather than recursion, and bounded by the queue length. The old
    /// version called itself on every failure, so a queue of files the phone
    /// cannot decode, or one file failing under repeat, span without end.
    private func startCurrent() {
        var attempts = 0
        let limit = max(queue.count, 1)

        while attempts < limit {
            attempts += 1
            guard let id = queue.current, let track = resolve?(id) else { stop(); return }

            if openAndPlay(track) { return }

            // Could not open or could not start: move on rather than stall.
            guard queue.skipForward() != nil else { stop(); return }
        }
        stop()
    }

    /// Open one track and start it. False means try the next one.
    private func openAndPlay(_ track: Track) -> Bool {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil

        var url = track.url
        if let data = track.bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: data, options: [],
                                       relativeTo: nil, bookmarkDataIsStale: &stale),
               resolved.startAccessingSecurityScopedResource() {
                url = resolved
                scopedURL = resolved
            }
        }

        // The session has to be current before the player is asked to start.
        activateSession()

        guard let p = try? AVAudioPlayer(contentsOf: url) else { return false }
        player?.stop()
        playToken &+= 1
        let token = playToken
        p.prepareToPlay()
        p.delegate = PlayerDelegateBox.shared
        PlayerDelegateBox.shared.onFinish = { [weak self] in
            Task { @MainActor in
                guard let self, self.playToken == token else { return }
                self.trackFinished()
            }
        }

        // `play()` returns false when the session is not active. Reactivating
        // and trying once more is what turns a silent no-op into playback.
        var started = p.play()
        if !started {
            activateSession()
            started = p.play()
        }
        guard started else { return false }

        player = p
        duration = p.duration
        currentTime = 0
        nowPlaying = track
        isPlaying = true
        startTicker()
        updateNowPlayingInfo()
        onTrackChange?(track)
        // Warm the artwork so the Dynamic Island and lock screen get it.
        Task { @MainActor in
            if await Artwork.load(for: track) != nil,
               self.nowPlaying?.id == track.id {
                self.updateNowPlayingInfo()
            }
        }
        return true
    }

    private func trackFinished() {
        if queue.advance() != nil { startCurrent() } else { stop() }
    }

    public func toggle() { isPlaying ? pause() : resume() }

    public func resume() {
        guard let p = player else {
            if queue.current != nil { startCurrent() }
            return
        }
        activateSession()
        if !p.play() {
            // The player is stale, usually after an interruption. Reopen it.
            startCurrent()
            return
        }
        isPlaying = true; startTicker(); updateNowPlayingInfo()
    }

    public func pause() {
        player?.pause(); isPlaying = false; stopTicker(); updateNowPlayingInfo()
    }

    public func next() { if queue.skipForward() != nil { startCurrent() } else { stop() } }

    public func previous() {
        // Match every music player: restart the track unless already near the top.
        if currentTime > 3 { seek(to: 0); return }
        if queue.skipBackward() != nil { startCurrent() }
    }

    public func seek(to t: Double) {
        guard let p = player else { return }
        p.currentTime = max(0, min(t, p.duration))
        currentTime = p.currentTime
        updateNowPlayingInfo()
    }

    public func stop() {
        playToken &+= 1              // orphan any pending finish callback
        player?.stop(); player = nil
        isPlaying = false; currentTime = 0; duration = 0
        nowPlaying = nil
        stopTicker()
        scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = nil
        #if os(iOS)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #endif
        onTrackChange?(nil)
    }

    // MARK: - Queue controls

    public func setShuffled(_ on: Bool) { queue.setShuffled(on) }
    public func cycleRepeat() { queue.repeatMode = queue.repeatMode.next }
    public func playNext(_ ids: [UUID]) { queue.playNext(ids) }
    public func addToQueue(_ ids: [UUID]) {
        let wasEmpty = queue.current == nil
        queue.addToQueue(ids)
        if wasEmpty { startCurrent() }
    }
    public func removeFromQueue(at offsets: IndexSet) { queue.remove(at: offsets) }
    /// Append tracks a continuous radio drifted onto, then trim stale history.
    public func extendQueue(_ ids: [UUID]) {
        queue.extend(ids)
        queue.trimHistory()
    }
    public func moveInQueue(from s: IndexSet, to d: Int) { queue.move(from: s, to: d) }

    // MARK: - Now Playing (Dynamic Island, lock screen, Control Center)

    private func updateNowPlayingInfo() {
        #if os(iOS)
        guard let t = nowPlaying else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.meta.title,
            MPMediaItemPropertyArtist: t.meta.artist,
            MPMediaItemPropertyAlbumTitle: t.meta.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let n = t.meta.trackNumber { info[MPMediaItemPropertyAlbumTrackNumber] = n }
        if let art = Artwork.image(for: t) {
            info[MPMediaItemPropertyArtwork] =
                MPMediaItemArtwork(boundsSize: art.size) { _ in art }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif
    }

    private func startTicker() {
        stopTicker()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player else { return }
                self.currentTime = p.currentTime
            }
        }
        // `.common` rather than the default mode. A timer scheduled the plain
        // way stops firing while a list is being scrolled, which froze the
        // progress bar and the elapsed time whenever the user touched a list.
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }
    private func stopTicker() { ticker?.invalidate(); ticker = nil }
}

/// AVAudioPlayerDelegate must be an NSObject, which `@Observable` classes are
/// not, so the callback is bounced through this box.
final class PlayerDelegateBox: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    static let shared = PlayerDelegateBox()
    var onFinish: (() -> Void)?
    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully: Bool) {
        onFinish?()
    }
}
