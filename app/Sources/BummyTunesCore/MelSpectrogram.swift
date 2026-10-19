import Accelerate
import Foundation

/// MusiCNN front-end, ported from AudioMuse-AI's librosa pipeline.
///
/// Must match exactly, or embeddings computed on device will not be comparable
/// with anything else:
///   n_fft 512, hop 256, n_mels 96, periodic hann, center=false, power 2.0,
///   slaney mel scale with slaney normalisation, then log10(1 + 10000 * mel),
///   sliced into non-overlapping 187-frame patches shaped (n, 187, 96).
public final class MelSpectrogram {

    public static let sampleRate = 16000
    public static let nFFT = 512
    public static let hop = 256
    public static let nMels = 96
    public static let patchFrames = 187

    private static let bins = nFFT / 2 + 1          // 257
    private static let log2n = vDSP_Length(9)       // 2^9 = 512

    private let fftSetup: FFTSetup
    private let window: [Float]
    /// Row-major (nMels x bins).
    private let filterbank: [Float]

    public init() {
        guard let setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup failed")
        }
        fftSetup = setup

        // librosa's 'hann' is periodic: hanning(N+1)[:-1]
        var w = [Float](repeating: 0, count: Self.nFFT)
        for i in 0..<Self.nFFT {
            w[i] = 0.5 - 0.5 * cos(2.0 * Float.pi * Float(i) / Float(Self.nFFT))
        }
        window = w
        filterbank = Self.slaneyFilterbank()
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    // MARK: - Mel scale (slaney, htk=false)

    private static func hzToMel(_ f: Double) -> Double {
        let fSp = 200.0 / 3.0, minLogHz = 1000.0
        let minLogMel = minLogHz / fSp
        let logstep = log(6.4) / 27.0
        return f < minLogHz ? f / fSp : minLogMel + log(f / minLogHz) / logstep
    }

    private static func melToHz(_ m: Double) -> Double {
        let fSp = 200.0 / 3.0, minLogHz = 1000.0
        let minLogMel = minLogHz / fSp
        let logstep = log(6.4) / 27.0
        return m < minLogMel ? fSp * m : minLogHz * exp(logstep * (m - minLogMel))
    }

    /// librosa.filters.mel(sr, n_fft, n_mels, htk=False, norm='slaney')
    private static func slaneyFilterbank() -> [Float] {
        let nyquist = Double(sampleRate) / 2.0
        var fftFreqs = [Double](repeating: 0, count: bins)
        for i in 0..<bins { fftFreqs[i] = nyquist * Double(i) / Double(bins - 1) }

        let melMin = hzToMel(0), melMax = hzToMel(nyquist)
        var hz = [Double](repeating: 0, count: nMels + 2)
        for i in 0..<(nMels + 2) {
            let m = melMin + (melMax - melMin) * Double(i) / Double(nMels + 1)
            hz[i] = melToHz(m)
        }

        var fb = [Float](repeating: 0, count: nMels * bins)
        for i in 0..<nMels {
            let lowDiff = hz[i + 1] - hz[i]
            let highDiff = hz[i + 2] - hz[i + 1]
            // slaney normalisation: equal area per filter
            let enorm = 2.0 / (hz[i + 2] - hz[i])
            for j in 0..<bins {
                let lower = (fftFreqs[j] - hz[i]) / lowDiff
                let upper = (hz[i + 2] - fftFreqs[j]) / highDiff
                let v = max(0.0, min(lower, upper))
                fb[i * bins + j] = Float(v * enorm)
            }
        }
        return fb
    }

    // MARK: - Spectrogram

    /// Power spectrogram, column-major by frame: `bins` values per frame.
    private func powerSpectrogram(_ audio: [Float], frames: Int) -> [Float] {
        var out = [Float](repeating: 0, count: Self.bins * frames)
        let half = Self.nFFT / 2

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var windowed = [Float](repeating: 0, count: Self.nFFT)

        audio.withUnsafeBufferPointer { src in
            for f in 0..<frames {
                let offset = f * Self.hop
                vDSP_vmul(src.baseAddress! + offset, 1, window, 1, &windowed, 1,
                          vDSP_Length(Self.nFFT))

                real.withUnsafeMutableBufferPointer { rp in
                  imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!,
                                                imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                          capacity: half) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, Self.log2n,
                                  FFTDirection(FFT_FORWARD))

                    // vDSP packs DC in realp[0] and Nyquist in imagp[0], and
                    // scales the transform by 2, so undo that here.
                    let s: Float = 0.5
                    let base = f * Self.bins
                    let dc = rp[0] * s, nyq = ip[0] * s
                    out[base] = dc * dc
                    out[base + Self.bins - 1] = nyq * nyq
                    for k in 1..<half {
                        let re = rp[k] * s, im = ip[k] * s
                        out[base + k] = re * re + im * im
                    }
                  }
                }
            }
        }
        return out
    }

    /// Mel spectrogram, row-major (nMels x frames).
    public func melSpectrogram(_ audio: [Float]) -> (mel: [Float], frames: Int)? {
        guard audio.count >= Self.nFFT else { return nil }
        let frames = 1 + (audio.count - Self.nFFT) / Self.hop
        guard frames > 0 else { return nil }

        let power = powerSpectrogram(audio, frames: frames)
        var mel = [Float](repeating: 0, count: Self.nMels * frames)

        // mel = filterbank (nMels x bins) * power^T (bins x frames).
        // `power` is frames-major, so treat it as (frames x bins) and multiply
        // transposed via cblas, which avoids materialising the transpose.
        filterbank.withUnsafeBufferPointer { fb in
            power.withUnsafeBufferPointer { pw in
                mel.withUnsafeMutableBufferPointer { mp in
                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                                Int32(Self.nMels), Int32(frames), Int32(Self.bins),
                                1.0,
                                fb.baseAddress!, Int32(Self.bins),
                                pw.baseAddress!, Int32(Self.bins),
                                0.0,
                                mp.baseAddress!, Int32(frames))
                }
            }
        }
        return (mel, frames)
    }

    // MARK: - Patches

    /// Non-overlapping 187-frame patches as `(n, 187, 96)` contiguous float.
    /// Returns nil when the audio is too short for even one patch.
    public func patches(_ audio: [Float]) -> (data: [Float], count: Int)? {
        guard let (mel, frames) = melSpectrogram(audio) else { return nil }
        let n = frames / Self.patchFrames
        guard n >= 1 else { return nil }

        var out = [Float](repeating: 0, count: n * Self.patchFrames * Self.nMels)
        // mel is (nMels x frames) row-major; output wants (patch, frame, band).
        for p in 0..<n {
            let f0 = p * Self.patchFrames
            for t in 0..<Self.patchFrames {
                let dst = (p * Self.patchFrames + t) * Self.nMels
                let f = f0 + t
                for b in 0..<Self.nMels {
                    let v = mel[b * frames + f]
                    out[dst + b] = log10(1.0 + 10000.0 * max(v, 0))
                }
            }
        }
        return (out, n)
    }
}
