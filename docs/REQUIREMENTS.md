# BummyTunes — Required Features

Everything in this document is **required**, not optional. Sourced directly from
what Bar specified. Technical design lives in [SPEC.md](SPEC.md).

---

## R1. Platform and distribution

| # | Requirement |
|---|---|
| R1.1 | Written in **Swift**, native. Not Flutter, not React Native. |
| R1.2 | Runs on **iOS and macOS**. |
| R1.3 | Ships as a **public repo**. |
| R1.4 | Installs via **LiveContainer**, so no paid developer account and no App Store. Build output must be a LiveContainer-compatible bundle. |
| R1.5 | Must be tested with Xcode automation, simulator and build tooling, not just written and handed over. |

## R2. It is a real music player first

The AI features are additions to a complete player, not a replacement for one.
It should feel like any good music app.

| # | Requirement |
|---|---|
| R2.1 | Full local library playback: songs, albums, artists. |
| R2.2 | **Shuffle.** |
| R2.3 | **Repeat**, with off / all / one. |
| R2.4 | A **random button** that shuffles across albums or the whole library. |
| R2.5 | Search across the library. |
| R2.6 | Now-playing view with a persistent mini player. |
| R2.7 | Background audio and lock-screen controls. |

## R3. Queue, modelled on Finamp

Called out as one of the most important things.

| # | Requirement |
|---|---|
| R3.1 | **Long-press a song** to get queue actions. |
| R3.2 | **Play next**, inserting directly after the current track. |
| R3.3 | **Add to queue**, appending to the very end. |
| R3.4 | A visible queue screen. |
| R3.5 | Reorder and remove items in the queue. |

## R4. Context-sensitive tap behaviour

Tapping a song does different things depending on where you tapped it. This
distinction is required.

| # | Requirement |
|---|---|
| R4.1 | Tap a song **inside an album** → play it, then continue through the rest of that album from that position. |
| R4.2 | Tap a song **from search results** → automatically start a **radio** seeded on that track. |

## R5. Artist navigation

| # | Requirement |
|---|---|
| R5.1 | In the now-playing view the **artist name is tappable text** and navigates to that artist's page. |
| R5.2 | This is a specific gap being closed. VLC cannot do this well and that is part of the point. |

## R6. On-device sonic embeddings

| # | Requirement |
|---|---|
| R6.1 | Settings contains an **"Embed library"** action that analyses the entire local library. |
| R6.2 | Analysis runs **entirely on the device's own hardware**. No server, no Jellyfin, no cloud, no API calls. |
| R6.3 | Designed to run as a long job with the phone plugged in and awake. |
| R6.4 | Must be **resumable** and must not redo work already done. |
| R6.5 | Progress is visible to the user. |
| R6.6 | Analysis must be able to **run in the background**, not only while the user sits on the analysis screen. |
| R6.7 | Analysis must survive the app being backgrounded and must continue where it left off. |

### R6.6 under LiveContainer — how this actually has to work

LiveContainer guest apps **share LiveContainer's bundle identifier, entitlements
and Info.plist**. A guest app's own entitlements are not applied. iOS reads the
host's Info.plist, so BummyTunes cannot declare its own background capabilities
and expect them to take effect.

Consequences:

| Mechanism | Viability under LiveContainer |
|---|---|
| **Audio background mode** | Most likely available, since LiveContainer must already declare it to run media apps. While audio plays, the app gets sustained CPU time. |
| **BGProcessingTask** | Unreliable. `BGTaskSchedulerPermittedIdentifiers` lives in the host Info.plist, so arbitrary guest task identifiers will probably not be permitted. |

**Required design:** piggyback the analysis on playback. While music is playing
the app is alive under the audio background mode, so embedding runs on a
low-priority background queue during listening. Analysing your library becomes
something that happens while you use the app normally. Foreground analysis with
the screen on stays as the explicit fast path. `BGProcessingTask` is registered
as a best-effort bonus and the design must not depend on it firing.

Both assumptions need verifying on device against the installed LiveContainer
build before the analysis engine is finalised.

## R7. AudioMuse-AI features

| # | Requirement |
|---|---|
| R7.1 | **Music map** — a 2D visual map of the library. Explicitly called the most important feature. |
| R7.2 | **Radio** from any track, by sonic similarity to the songs you already own. |
| R7.3 | Further AudioMuse features are wanted over time, such as instant playlists from a text description. |

## R8. Library import and file system access

| # | Requirement |
|---|---|
| R8.1 | On **first launch** the app prompts the user to add a library. |
| R8.2 | That opens the **system file browser**, so the user can navigate the iPhone's Files. |
| R8.3 | The user selects the **folder** containing their music, not individual files. |
| R8.4 | Access must survive app restarts. |
| R8.5 | Must be verified to work **through LiveContainer**, which is a real risk and not assumed. See [SPEC.md](SPEC.md) for the fallback. |

## R9. Metadata and artist parsing

Called out as a most-important item. The library is messy because music
collected from many sources is never consistently named.

| # | Requirement |
|---|---|
| R9.1 | A proper **metadata database**, not filename display. |
| R9.2 | Read **embedded tags first** when present and sane. |
| R9.3 | Fall back to **parsing the filename** when tags are missing or empty. |
| R9.4 | Handle track numbers appearing **before or after** the title. |
| R9.5 | Handle many separator and layout conventions across a messy library. |
| R9.6 | **Canonicalise artists**, so one artist written several ways collapses to a single artist entity rather than appearing many times. |
| R9.7 | Parse multi-artist and featured-artist forms. |
| R9.8 | Full **Unicode** support. The library already contains Japanese, Hebrew right-to-left, Thai and Latin. No ASCII assumptions anywhere. |

### Evidence from the real library

Measured against 1,009 real files on the Mac, not hypothetical.

**Tag coverage:** 10 of 12 sampled files carried usable artist and title tags.
Tags must therefore lead. Two untagged files were loose recordings named
`amsterdam.wav` and `house.mp3`.

**Tags beat filenames.** `02 - O Ganso.mp3` has a useless filename but tags
correctly to Luiz Bonfa & Eumir Deodato. `11. Fotografia.flac` tags to Elis
Regina e Tom Jobim. A filename-first parser would get both wrong.

**Filename shapes actually present:**

| Shape | Example |
|---|---|
| `Artist - Album - NN Track` | `Art Dave - One Night In Manchester - 06 Seiya Kou Is A Boy.mp3` |
| `NN - Track` | `02 - John Roseboro How To Pray.mp3` |
| `NN. Track` | `13. Chovendo Na Roseira.flac` |
| Bare title | `Yakuza Baka Mitai Female Version.mp3` |
| Meaningless | `untitled.mp3`, `1.wav`, `justajob.mp3` |

**Multi-artist separators seen:** `&` as in King Gizzard & The Lizard Wizard,
and `e` as in Elis Regina e Tom Jobim. Portuguese "e" means "and", so separator
handling cannot be English-only.

**Version suffixes to preserve, not strip blindly:** `(Solaria Version)`,
`(Acoustic Version)`, `(Luka Demo Version)`, `(Live in Maine '24)`,
`(Kasane Teto Version)`. These distinguish real distinct tracks.

**Non-Latin artists and albums present:** 路傍の石, גיאגיא, Takuto Kinoshita,
with Thai track titles such as ชีวิตในกลางคืน.

## R12. Search — must be forgiving

Called out as most important. You will type what you remember, not what is
stored, and it still has to find the track.

| # | Requirement |
|---|---|
| R12.1 | **Diacritic-insensitive.** Typing a plain `E` must match a stored `É`. `Pois E` finds `Pois É`. |
| R12.2 | **Case-insensitive**, across all scripts. |
| R12.3 | **Width-insensitive**, so full-width and half-width CJK forms match. |
| R12.4 | Matches against **track title, artist, album** together. |
| R12.5 | **Substring and prefix** matching, not exact-equality only. |
| R12.6 | **Typo tolerant.** A wrong or missing letter should still surface the track. |
| R12.7 | Works across **every script in the library**: Latin, Hebrew, Japanese, Thai. |
| R12.8 | Fast enough to filter as you type on a library of thousands. |

| R12.9 | Folding must be **script-aware**. It must never corrupt Japanese. |

**Implementation.** Store a folded search key next to every track, artist and
album at import time, and index it. Fold once on write, never on read. Typo
tolerance layers on top with edit distance over the folded keys.

**The obvious approach is wrong.** Plain diacritic-insensitive folding strips
*all* combining marks, which destroys Japanese. The dakuten and handakuten
(U+3099, U+309A) are combining marks, but they are not accents. They change the
consonant, so か and が are different sounds and different words. Measured on
this library, naive folding corrupts:

| Original | Naive folding | Result |
|---|---|---|
| ゴミ | コミ | wrong word |
| あなたがすき | あなたかすき | wrong word |
| ハングドマン | ハンクトマン | wrong word |
| 塵芥に沈んで | 塵芥に沈んて | wrong word |

109 titles in the library carry combining marks and most of them are Japanese,
so this would have silently broken search across a large part of the collection.

**Correct implementation.** Strip only the Latin combining-diacritic range and
preserve kana voicing:

```swift
extension String {
    var searchKey: String {
        let decomposed = self.decomposedStringWithCompatibilityMapping
        let kept = decomposed.unicodeScalars.filter { s in
            if s.value == 0x3099 || s.value == 0x309A { return true }  // kana voicing
            return !(0x0300...0x036F).contains(s.value)                // Latin accents
        }
        return String(String.UnicodeScalarView(kept))
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }
}
```

**Verified against the real library.** Portuguese folds as required, `Pois É`
and `Pois E` both yield `pois e`, and `São Paulo` yields `sao paulo`. Japanese
round-trips unchanged. Hebrew and Thai are untouched.

### Later: true semantic search

AudioMuse also ships `clap_text_model.onnx`, a CLAP text encoder that embeds a
text description into the same space as the audio. That is what powers its
"instant playlist from a description" feature and would allow queries by feel
rather than by name. Out of scope for v1, in scope for the roadmap under R7.3.

## R10. Design

The split that makes this coherent: **Finamp supplies the structure, Persona
supplies the skin.** Information architecture and interaction patterns come from
Finamp and iOS convention, so the app stays usable and familiar. The visual
language is Persona 5 / Persona 3, retuned from P5's red-and-black to purple and
yellow.

| # | Requirement |
|---|---|
| R10.1 | SwiftUI. |
| R10.2 | **Structure** modelled on Finamp: layout, information hierarchy, navigation, queue patterns. |
| R10.3 | **iOS-native interaction**: tab bar, standard navigation, swipe gestures, long-press menus, lock-screen controls. Nothing that fights the platform. |
| R10.4 | **Visual style: Persona 5 / Persona 3, mixed with modern.** Bold and kinetic, not a flat stock iOS skin. |
| R10.5 | Colour scheme is **purple and yellow**, standing in for P5's red and black. |

### What "Persona style" means concretely

| Element | Treatment |
|---|---|
| Shapes | Angular and diagonal. Slashed corners, skewed cards, asymmetric crops rather than uniform rounded rectangles. |
| Motion | Kinetic. Elements slide in on angles, stagger rather than fade together, snap rather than ease. Transitions are part of the identity. |
| Typography | Bold condensed display faces for headers and track titles, with high contrast against body text. Occasional italic skew. |
| Texture | Halftone dots and hard-edged shapes as accents, used sparingly on backgrounds and behind art. |
| Now-playing | The signature screen. Full-bleed art on a skewed frame, oversized title, the tappable artist text as a deliberate design element. |
| Music map | Where the style earns its keep. A P5-styled visual map is far more striking than a plain scatter plot. |

### What "mixed with modern" means

Persona styling is applied as a **skin over conventional structure**, never at the
cost of usability. Hit targets stay standard. Lists stay scannable. Text stays
legible at accessibility sizes. Animation respects Reduce Motion. The boldness
lives in colour, shape, type and transition, not in making things hard to find.

The rule when the two conflict: **structure wins, style bends.**

## R11. Proof before shipping

| # | Requirement |
|---|---|
| R11.1 | The embedding must be demonstrated on the loose music already on the Mac. |
| R11.2 | Radios must be shown actually working, not just described. |

**Status on R11:** Met in prototype. Mel pipeline validated against librosa at
cosine 1.00000000. Radio on real files ranked produced music at 0.73 while
pushing spoken-word voice memos down to 0.36.
