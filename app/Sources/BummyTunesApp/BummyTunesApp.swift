import BummyTunesCore
import SwiftUI

@main
struct BummyTunesApp: App {
    @State private var app = AppModel()
    @State private var appearance = Appearance()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(appearance)
                .task {
                    // An analysis run that was cut short picks itself back up.
                    app.resumeAnalysisIfWanted()
                    // Covers fill in on their own while the app is open, and
                    // survive a relaunch through the on-disk cache.
                    app.warmArtwork()
                    // R6.6 — ride the audio background mode: whenever music is
                    // playing there is CPU to spare, so unanalysed tracks get
                    // worked through in the background at low priority.
                    app.player.onTrackChange = { track in
                        // Recolour from the new artwork when the ground follows
                        // the album. Artwork loads async, so try now and again
                        // shortly after, once the cache is warm.
                        appearance.adopt(from: track)
                        if let track {
                            app.recordPlay(track)
                            // A continuous radio re-seeds off whatever just
                            // started, so the queue keeps walking outward
                            // instead of orbiting the track you began with.
                            app.extendRadioIfNeeded(after: track)
                        }
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 700_000_000)
                            appearance.adopt(from: track)
                        }
                        guard track != nil else { return }
                        if app.analysedCount < app.tracks.count && !app.analysis.isRunning {
                            app.startAnalysis(trigger: .duringPlayback)
                        }
                    }
                }
        }
        .onChange(of: phase) { _, new in
            if new == .background { app.persistNow() }
            if new == .active {
                app.openLibraryAccess()
                app.resumeAnalysisIfWanted()
                app.warmArtwork()
            }
        }
    }
}
