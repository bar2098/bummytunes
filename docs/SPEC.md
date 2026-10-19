# BummyTunes

Native iOS/macOS music player with on-device sonic embeddings and smart radio.
Ports AudioMuse-AI's analysis to run locally on the phone, no server, no Jellyfin.

Target install: **LiveContainer** (unsigned sideload, no paid dev account).

## Why

Local music on iPhone has no vector embeddings, so nothing can build smart radios
from the tracks you already own. AudioMuse-AI does this but needs a server and a
Jellyfin/Navidrome library. This does it on-device against the local library.

## Core engine (VALIDATED, see prototype/)

MusiCNN embedding, extracted from AudioMuse-AI v5.0.0-model release.

| Stage | Parameters |
|---|---|
| Decode | 16 kHz, mono, float32 |
| STFT | n_fft 512, hop 256, hann (periodic), center=False |
| Mel | 96 bands, slaney scale, slaney norm, power 2.0 |
| Compress | `log10(1 + 10000 * mel)` |
| Patches | 187 frames, non-overlapping → `(N, 187, 96)` |
| Model | `musicnn_embedding.onnx`, 3.1 MB |
| Output | `(N, 200)` → mean-pool → L2 normalise → one 200-d vector |

Similarity is cosine, which on unit vectors is a plain dot product.

Verified: pure-numpy mel matches librosa at cosine **1.00000000**, so there is no
librosa dependency and the whole chain ports to vDSP/Accelerate.

On-device runtime: ONNX Runtime with **CoreMLExecutionProvider** (confirmed
available), or convert the 3.1 MB graph to CoreML directly.

## Features

### Playback
- Tap a song in an **album** → plays that song, then the rest of the album from there
- Tap a song from **search** → starts a radio automatically from that track
- Shuffle, repeat (off / all / one)
- Random button to shuffle across albums or the whole library

### Queue (model it on Finamp)
- Long-press a song → "Play next" and "Add to queue" (append last)
- Reorderable queue view
- Now-playing bar → full player

### Navigation
- In the now-playing view, the **artist name is tappable text** → jumps to artist page
  (VLC cannot do this; it is a specific gap we are closing)

### First run: pick the library folder
- On first launch the app asks the user to add a library
- Opens the system file browser via `UIDocumentPickerViewController` in folder
  mode, so the user browses the iPhone's Files and selects the folder holding
  their music
- Access must persist across launches via **security-scoped bookmarks**
  (`startAccessingSecurityScopedResource` + bookmark data in storage)
- **RISK TO VERIFY:** LiveContainer runs guest apps inside its own container and
  app identity, so security-scoped bookmarks may not round-trip the way they do
  for a normally-installed app. Needs testing on device early, because the whole
  library model depends on it. Fallback if bookmarks fail under LiveContainer is
  to copy or hard-link the selected folder into the app's own Documents
  directory on import.

### Intelligence
- Settings → "Embed library": runs the analysis over the whole local library,
  on-device, resumable, designed to run with the phone plugged in and awake
- **Music map**: 2D visual map of the library (most important feature)
- Radio from any track by sonic similarity

## Design
- iOS-native feel, modelled on Finamp's layout and information hierarchy
- Palette: **purple and yellow**
- SwiftUI

## Repos studied
- `AudioMuse-AI/` — NeptuneHub, AGPL-3.0. Source of the algorithm and models.
- `finamp/` — jmshrv, Flutter. Design and queue-behaviour reference only.

## Licensing note
The MusiCNN model comes from [musicnn](https://github.com/jordipons/musicnn)
(ISC). The ONNX file is AudioMuse-AI's conversion of those weights. The Swift
pipeline is a reimplementation of the same preprocessing, not a copy of
AudioMuse-AI's code. BummyTunes itself is PolyForm Noncommercial 1.0.0.
