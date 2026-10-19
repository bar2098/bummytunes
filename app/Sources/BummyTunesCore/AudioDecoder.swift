import AVFoundation
import Accelerate
import Foundation

/// Decodes any AVFoundation-readable file to the 16 kHz mono float the model
/// expects, streaming rather than loading the whole track.
///
/// Streaming matters: an 11-minute file at 16 kHz is 10.5M samples, and the
/// first Python run was killed for memory by materialising whole-file
/// intermediates. A phone has far less headroom than that Mac did.
public enum AudioDecoder {

    public enum Failure: Error, CustomStringConvertible {
        case noAudioTrack, converterUnavailable, readFailed(String)
        public var description: String {
            switch self {
            case .noAudioTrack: return "file has no audio track"
            case .converterUnavailable: return "could not build an audio converter"
            case .readFailed(let m): return "read failed: \(m)"
            }
        }
    }

    /// Resample target. Channel count deliberately matches the source.
    ///
    /// Letting the converter downmix is wrong here. Core Audio and swresample
    /// both do a power-preserving mix, scaling each channel by 1/sqrt(2), while
    /// librosa (and therefore AudioMuse, and therefore the reference vectors)
    /// takes a plain mean. Because the model sees log10(1 + 10000 * mel), that
    /// gain difference is not linear and does move the embedding: measured on a
    /// stereo FLAC it dropped agreement with the reference to cosine 0.92.
    /// So resample at the source channel count and average manually below.
    static func resampleFormat(channels: AVAudioChannelCount) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: Double(MelSpectrogram.sampleRate),
                      channels: channels,
                      interleaved: false)
    }

    /// Decode to a sample buffer.
    /// - Parameter maxSeconds: stop after this much audio. Analysing the first
    ///   few minutes is enough to characterise a track and bounds worst-case
    ///   work on very long files.
    public static func decode(url: URL, maxSeconds: Double = 300) throws -> [Float] {
        try autoreleasepool {
            try decodeInner(url: url, maxSeconds: maxSeconds)
        }
    }

    /// Five minutes rather than ten.
    ///
    /// The buffers scale with it: ten minutes of audio is 38 MB of samples,
    /// another 14 MB of mel bins and 14 MB of patches, all live at once. Most
    /// songs are shorter than five minutes and so are unaffected, and for the
    /// ones that are not, the embedding is a mean over patches, so the first
    /// five minutes characterises them perfectly well.
    private static func decodeInner(url: URL, maxSeconds: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        let channels = inFormat.channelCount
        guard let outFormat = resampleFormat(channels: channels),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw Failure.converterUnavailable
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        let readFrames: AVAudioFrameCount = 16384
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: readFrames) else {
            throw Failure.converterUnavailable
        }
        // Output capacity must cover the worst-case ratio change.
        let ratio = outFormat.sampleRate / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(readFrames) * max(ratio, 1.0)) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            throw Failure.converterUnavailable
        }

        // Reserve for what this file actually holds. Reserving the full cap
        // every time asked for 38 MB up front on a two-minute song, which on a
        // phone is the difference between analysing in the background and
        // being killed for it.
        let sourceSeconds = inFormat.sampleRate > 0
            ? Double(file.length) / inFormat.sampleRate : maxSeconds
        var samples = [Float]()
        samples.reserveCapacity(Int(min(sourceSeconds, maxSeconds) * outFormat.sampleRate) + 1024)
        let limit = Int(maxSeconds * outFormat.sampleRate)
        var reachedEnd = false

        while samples.count < limit && !reachedEnd {
            var error: NSError?
            let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
                do {
                    inBuf.frameLength = 0
                    try file.read(into: inBuf, frameCount: readFrames)
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuf.frameLength == 0 {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuf
            }

            if let error { throw Failure.readFailed(error.localizedDescription) }
            if status == .endOfStream || outBuf.frameLength == 0 { reachedEnd = true }

            if outBuf.frameLength > 0, let ch = outBuf.floatChannelData {
                let n = Int(outBuf.frameLength)
                if channels == 1 {
                    samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
                } else {
                    // Plain mean across channels, matching librosa.
                    var mixed = [Float](repeating: 0, count: n)
                    for c in 0..<Int(channels) {
                        vDSP_vadd(mixed, 1, ch[c], 1, &mixed, 1, vDSP_Length(n))
                    }
                    var scale = 1.0 / Float(channels)
                    vDSP_vsmul(mixed, 1, &scale, &mixed, 1, vDSP_Length(n))
                    samples.append(contentsOf: mixed)
                }
                outBuf.frameLength = 0
            }
            if status == .error { break }
        }

        if samples.count > limit { samples.removeSubrange(limit...) }
        return samples
    }
}
