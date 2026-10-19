# BummyTunes

A native music player for iPhone and Mac with smart radio built from your own
local library. Every track gets a sonic embedding computed on the device, so
radio, "sounds like this" and the music map work offline with no server.

The analysis is a port of [AudioMuse-AI](https://github.com/NeptuneHub/AudioMuse-AI)
(MusiCNN embeddings) to Swift, running on Accelerate and ONNX Runtime with
CoreML.

More about why it exists, plus a demo video:
**[BummyTunes, BummyWAVES, and a Dying CPU Fan](https://levibar.com/blogs/bummytunes-and-bummywaves/)**

---

## Features

- Full local library playback: songs, albums, artists, search
- Queue modeled on Finamp: long press for **Play next** / **Add to queue**
- Shuffle, repeat (off / all / one), random across albums or the whole library
- **Embed library**: on-device analysis of every track, resumable, meant to run
  with the phone plugged in
- **Radio** from any track by sonic similarity, either similar or continuous
- **Music map**: the whole library laid out in 2D by sound, colored by genre
- **Cover Flow**: turn the phone sideways and flick through album covers like
  the old iPod, tap the middle one to flip it to its track list
- Persona 5 inspired UI in purple, with an album mode where the background
  takes its color from the cover that's playing
- Background audio and lock screen controls

---

## Install on iPhone

BummyTunes installs through [LiveContainer](https://github.com/LiveContainer/LiveContainer),
so you don't need the App Store or a paid developer account.

1. Build the `.ipa` (below), or grab one from Releases.
2. Open LiveContainer on the phone and install `BummyTunes.ipa`.
3. On first launch, pick the folder in Files that holds your music.
4. Settings → **Embed library**, plug the phone in, and let it run.

---

## Building

Builds run from the command line with the swift.org toolchain. **Xcode is not
required.**

### Prerequisites

| What | Where |
|---|---|
| Mac with Apple Silicon | |
| Swift 6.3.1 toolchain | [swift.org/install/macos](https://www.swift.org/install/macos/). It installs to `~/Library/Developer/Toolchains/swift-6.3.1-RELEASE.xctoolchain`. |
| `lld` and `onnxruntime` | `brew install lld onnxruntime` |
| iPhoneOS 26.5 SDK | [xybp888/iOS-SDKs](https://github.com/xybp888/iOS-SDKs) |
| macOS 15.5 SDK | From Xcode, or [joseluisq/macosx-sdks](https://github.com/joseluisq/macosx-sdks/releases/tag/15.5) |
| ONNX Runtime 1.23.0 for iOS | [pod-archive-onnxruntime-c-1.23.0.zip](https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.23.0.zip) |

The SDKs and the iOS ONNX Runtime go in `toolchain/`, which is git-ignored
because it's over a gigabyte:

```
toolchain/
├── iOS-SDKs/iPhoneOS26.5.sdk
├── MacOSX15.5.sdk
└── ort/onnxruntime.xcframework
```

One way to set it up:

```bash
mkdir -p toolchain && cd toolchain

# iOS SDK (sparse clone, only the one SDK)
git clone --filter=blob:none --sparse https://github.com/xybp888/iOS-SDKs.git
git -C iOS-SDKs sparse-checkout set iPhoneOS26.5.sdk

# macOS SDK
curl -L https://github.com/joseluisq/macosx-sdks/releases/download/15.5/MacOSX15.5.sdk.tar.xz | tar xJ

# ONNX Runtime for iOS
curl -LO https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.23.0.zip
mkdir ort && unzip -q pod-archive-onnxruntime-c-1.23.0.zip -d ort && rm pod-archive-onnxruntime-c-1.23.0.zip

cd ..
```

### iPhone

```bash
./build-ios.sh
```

Output: `build/BummyTunes.ipa`, unsigned, ready for LiveContainer.

### Mac

```bash
./build-mac.sh
open build-mac/BummyTunes.app
```

The Mac build uses the same SwiftUI views as iOS, so it's also the quickest
way to look at UI changes without a phone.

### Verify the engine

`bummy-verify` checks the whole analysis chain against golden fixtures
generated from the Python reference (mel spectrogram, patches, embedding), plus
queue, radio and library storage behavior.

```bash
cd app
SDKROOT="$PWD/../toolchain/MacOSX15.5.sdk" \
  ~/Library/Developer/Toolchains/swift-6.3.1-RELEASE.xctoolchain/usr/bin/swift run bummy-verify
```

### Screenshots

```bash
./build-mac.sh && ./shots.sh
```

Renders every screen to PNGs in `/tmp/shots`.

---

## How the embeddings work

| Stage | Parameters |
|---|---|
| Decode | 16 kHz, mono, float32 |
| STFT | n_fft 512, hop 256, periodic Hann, no centering |
| Mel | 96 bands, Slaney scale and norm, power 2.0 |
| Compress | `log10(1 + 10000 * mel)` |
| Patches | 187 frames, non-overlapping |
| Model | `models/musicnn_embedding.onnx` (3.1 MB, from AudioMuse-AI) |
| Output | 200-d per patch → mean-pool → L2 normalize → one vector per track |

Similarity is cosine, which on unit vectors is a dot product. The Swift mel
spectrogram matches librosa at cosine 1.00000000.

---

## Repo layout

```
app/Sources/BummyTunesCore/   engine: decode, mel, embed, library, queue, radio
app/Sources/BummyTunesApp/    SwiftUI app (iOS and macOS)
app/Sources/BummyVerify/      verification runner
app/Sources/BummyShots/       renders screens to PNG
app/Sources/COnnxRuntime/     ONNX Runtime C headers
app/Tests/.../Fixtures/       golden data for bummy-verify
models/                       MusiCNN embedding model
prototype/                    Python reference implementation
icon/                         app icons
docs/SPEC.md                  technical design
docs/REQUIREMENTS.md          feature requirements
```

---

## Credits and licensing

- **[AudioMuse-AI](https://github.com/NeptuneHub/AudioMuse-AI)** by NeptuneHub
  (AGPL-3.0): the analysis approach and the MusiCNN model weights in `models/`.
- **[Finamp](https://github.com/jmshrv/finamp)** by jmshrv: queue behavior and
  layout reference.
- **[ONNX Runtime](https://github.com/microsoft/onnxruntime)** by Microsoft (MIT):
  the headers in `app/Sources/COnnxRuntime/include`.
