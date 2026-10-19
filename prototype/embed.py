#!/usr/bin/env python3
"""
BummyTunes embedding prototype.

Reference implementation of AudioMuse-AI's MusiCNN track embedding, written
without librosa so every step maps 1:1 onto what the Swift/vDSP port has to do.

Pipeline (matches AudioMuse tasks/analysis/song.py):
  decode -> 16 kHz mono f32
  mel spectrogram: n_fft=512, hop=256, n_mels=96, hann, center=False,
                   power=2.0, slaney mel scale, slaney norm
  log_mel = log10(1 + 10000 * mel)
  patches of 187 frames, non-overlapping, shaped (N, 187, 96)
  musicnn_embedding.onnx -> (N, 200)
  mean-pool over patches, L2 normalise -> one 200-d vector per track

Memory and resume (R6.4): frames are built in bounded blocks rather than one
giant array, everything stays float32, and each finished track is appended to
embeddings.jsonl immediately so an interrupted run resumes instead of restarting.
"""
import json
import subprocess
import sys
from pathlib import Path

import numpy as np
import onnxruntime as ort

SR = 16000
N_FFT = 512
HOP = 256
N_MELS = 96
FRAME = 187
BLOCK = 2048          # frames per STFT block; caps peak memory

ROOT = Path(__file__).resolve().parent.parent
MODEL = ROOT / "models" / "musicnn_embedding.onnx"
OUT = ROOT / "prototype" / "embeddings.jsonl"


# ----------------------------------------------------------------- mel ----
def hz_to_mel_slaney(f):
    f = np.atleast_1d(np.asarray(f, dtype=np.float64)).copy()
    f_sp, min_log_hz = 200.0 / 3.0, 1000.0
    min_log_mel = min_log_hz / f_sp
    logstep = np.log(6.4) / 27.0
    mel = f / f_sp
    hi = f >= min_log_hz
    mel[hi] = min_log_mel + np.log(f[hi] / min_log_hz) / logstep
    return mel


def mel_to_hz_slaney(m):
    m = np.atleast_1d(np.asarray(m, dtype=np.float64)).copy()
    f_sp, min_log_hz = 200.0 / 3.0, 1000.0
    min_log_mel = min_log_hz / f_sp
    logstep = np.log(6.4) / 27.0
    freqs = f_sp * m
    hi = m >= min_log_mel
    freqs[hi] = min_log_hz * np.exp(logstep * (m[hi] - min_log_mel))
    return freqs


def mel_filterbank(sr=SR, n_fft=N_FFT, n_mels=N_MELS):
    """librosa.filters.mel(htk=False, norm='slaney') equivalent."""
    fft_freqs = np.linspace(0, sr / 2.0, 1 + n_fft // 2)
    mel_min = float(hz_to_mel_slaney(0.0)[0])
    mel_max = float(hz_to_mel_slaney(sr / 2.0)[0])
    hz_pts = mel_to_hz_slaney(np.linspace(mel_min, mel_max, n_mels + 2))

    fdiff = np.diff(hz_pts)
    ramps = hz_pts[:, None] - fft_freqs[None, :]
    weights = np.zeros((n_mels, len(fft_freqs)))
    for i in range(n_mels):
        weights[i] = np.maximum(0, np.minimum(-ramps[i] / fdiff[i],
                                              ramps[i + 2] / fdiff[i + 1]))
    weights *= (2.0 / (hz_pts[2:n_mels + 2] - hz_pts[:n_mels]))[:, None]
    return weights.astype(np.float32)


_MELFB = mel_filterbank()
_WINDOW = np.hanning(N_FFT + 1)[:-1].astype(np.float32)   # librosa 'hann' is periodic


def melspectrogram(audio):
    """center=False, power=2.0, computed in bounded blocks."""
    n = 1 + (len(audio) - N_FFT) // HOP
    if n <= 0:
        return None
    cols = []
    for start in range(0, n, BLOCK):
        cnt = min(BLOCK, n - start)
        idx = np.arange(N_FFT)[None, :] + HOP * (start + np.arange(cnt))[:, None]
        frames = audio[idx] * _WINDOW
        spec = np.fft.rfft(frames, n=N_FFT, axis=1)
        power = (spec.real ** 2 + spec.imag ** 2).astype(np.float32).T
        cols.append(_MELFB @ power)
        del idx, frames, spec, power
    return np.concatenate(cols, axis=1)


def prepare_patches(audio):
    mel = melspectrogram(audio)
    if mel is None:
        return None
    log_mel = np.log10(1.0 + 10000.0 * np.maximum(mel, 0.0, out=mel))
    n = (log_mel.shape[1] // FRAME)
    if n < 1:
        return None
    patches = log_mel[:, : n * FRAME].reshape(N_MELS, n, FRAME)
    return np.ascontiguousarray(patches.transpose(1, 2, 0), dtype=np.float32)


# --------------------------------------------------------------- audio ----
def decode(path):
    """ffmpeg -> 16 kHz mono float32."""
    p = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path),
         "-f", "f32le", "-ac", "1", "-ar", str(SR), "-"],
        capture_output=True, timeout=600,
    )
    if p.returncode != 0 or not p.stdout:
        return None
    return np.frombuffer(p.stdout, dtype=np.float32)


# ----------------------------------------------------------------- run ----
def main():
    if len(sys.argv) > 2 and sys.argv[1] == "--list":
        files = [Path(l) for l in Path(sys.argv[2]).read_text().splitlines() if l.strip()]
    else:
        files = [Path(a) for a in sys.argv[1:]]
    if not files:
        print("usage: embed.py --list <file-of-paths>")
        return 1

    done = set()
    if OUT.exists():
        for line in OUT.read_text().splitlines():
            try:
                done.add(json.loads(line)["path"])
            except Exception:
                pass
        print(f"resuming: {len(done)} already embedded")

    todo = [f for f in files if str(f) not in done]
    print(f"{len(todo)} to go\n", flush=True)

    sess = ort.InferenceSession(str(MODEL), providers=["CPUExecutionProvider"])
    inp, out = sess.get_inputs()[0].name, sess.get_outputs()[0].name

    with OUT.open("a") as fh:
        for k, f in enumerate(todo, 1):
            try:
                audio = decode(f)
                if audio is None or audio.size < SR:
                    print(f"  SKIP  {f.name[:50]}", flush=True); continue
                patches = prepare_patches(audio)
                del audio
                if patches is None:
                    print(f"  SKIP  {f.name[:50]} (too short)", flush=True); continue

                # batch inference so one long track cannot spike memory
                acc = np.zeros(200, dtype=np.float64); cnt = 0
                for s in range(0, patches.shape[0], 64):
                    e = sess.run([out], {inp: patches[s:s + 64]})[0]
                    acc += e.sum(axis=0); cnt += e.shape[0]
                npatch = int(patches.shape[0]); del patches

                vec = acc / max(cnt, 1)
                vec = vec / (np.linalg.norm(vec) + 1e-9)
                fh.write(json.dumps({"path": str(f), "name": f.name,
                                     "patches": npatch,
                                     "embedding": [round(float(x), 6) for x in vec]}) + "\n")
                fh.flush()
                print(f"  {k}/{len(todo)}  {f.name[:52]}", flush=True)
            except Exception as ex:
                print(f"  FAIL  {f.name[:44]}: {type(ex).__name__}", flush=True)

    print(f"\ndone -> {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
