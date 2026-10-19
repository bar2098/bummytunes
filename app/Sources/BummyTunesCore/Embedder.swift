import COnnxRuntime
import Foundation

/// Runs MusiCNN over log-mel patches and produces one 200-d track vector.
///
/// The graph takes `(n, 187, 96)` float and returns `(n, 200)`. Patches are fed
/// in batches so a long track cannot spike memory, which matters on a phone
/// (R6.2): an 11-minute file is ~230 patches and feeding them at once is what
/// killed the first Python run.
public final class Embedder {

    public static let embeddingDim = 200
    /// Patches per inference call. Bounds peak memory on device.
    public static let batchSize = 32

    private let api: UnsafePointer<OrtApi>
    private var env: OpaquePointer?
    private var session: OpaquePointer?
    private var allocator: UnsafeMutablePointer<OrtAllocator>?
    private let inputName: String
    private let outputName: String

    public enum Failure: Error, CustomStringConvertible {
        case api(String)
        case tooShort
        public var description: String {
            switch self {
            case .api(let m): return "ONNX Runtime: \(m)"
            case .tooShort: return "audio too short for one 187-frame patch"
            }
        }
    }

    /// - Parameter useCoreML: route execution through the Neural Engine where
    ///   available. Falls back to CPU silently if the provider cannot attach.
    public init(modelPath: String, useCoreML: Bool = true) throws {
        guard let base = OrtGetApiBase(),
              let getApi = base.pointee.GetApi,
              let a = getApi(UInt32(ORT_API_VERSION)) else {
            throw Failure.api("could not obtain OrtApi")
        }
        api = a

        try Self.check(a, a.pointee.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "bummytunes", &env))

        var options: OpaquePointer?
        try Self.check(a, a.pointee.CreateSessionOptions(&options))
        defer { a.pointee.ReleaseSessionOptions(options) }
        _ = a.pointee.SetIntraOpNumThreads(options, 2)
        _ = a.pointee.SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL)

        #if os(iOS)
        if useCoreML {
            // Best effort. A failure here is not fatal; CPU still produces
            // identical numbers, just slower.
            _ = OrtSessionOptionsAppendExecutionProvider_CoreML(options, 0)
        }
        #endif

        try Self.check(a, a.pointee.CreateSession(env, modelPath, options, &session))
        try Self.check(a, a.pointee.GetAllocatorWithDefaultOptions(&allocator))

        // Names are read from the graph rather than hardcoded, because the
        // published model uses TensorFlow-style names like "model/Placeholder:0".
        var inPtr: UnsafeMutablePointer<CChar>?
        try Self.check(a, a.pointee.SessionGetInputName(session, 0, allocator, &inPtr))
        inputName = String(cString: inPtr!)

        var outPtr: UnsafeMutablePointer<CChar>?
        try Self.check(a, a.pointee.SessionGetOutputName(session, 0, allocator, &outPtr))
        outputName = String(cString: outPtr!)
    }

    deinit {
        if let s = session { api.pointee.ReleaseSession(s) }
        if let e = env { api.pointee.ReleaseEnv(e) }
    }

    private static func check(_ api: UnsafePointer<OrtApi>,
                              _ status: OpaquePointer?) throws {
        guard let st = status else { return }
        let msg = api.pointee.GetErrorMessage(st).map { String(cString: $0) } ?? "unknown error"
        api.pointee.ReleaseStatus(st)
        throw Failure.api(msg)
    }

    private func check(_ status: OpaquePointer?) throws {
        try Self.check(api, status)
    }

    /// Embed pre-computed patches.
    /// - Parameter patches: contiguous `(count, 187, 96)` float.
    /// - Returns: L2-normalised 200-d vector, mean-pooled across patches.
    public func embed(patches: [Float], count: Int) throws -> [Float] {
        guard count > 0 else { throw Failure.tooShort }

        let frames = MelSpectrogram.patchFrames
        let bands = MelSpectrogram.nMels
        let perPatch = frames * bands

        var sum = [Double](repeating: 0, count: Self.embeddingDim)
        var seen = 0

        var memInfo: OpaquePointer?
        try check(api.pointee.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memInfo))
        defer { api.pointee.ReleaseMemoryInfo(memInfo) }

        var start = 0
        while start < count {
            let n = min(Self.batchSize, count - start)
            var shape: [Int64] = [Int64(n), Int64(frames), Int64(bands)]
            var slice = Array(patches[(start * perPatch)..<((start + n) * perPatch)])

            var input: OpaquePointer?
            try slice.withUnsafeMutableBufferPointer { buf in
                try check(api.pointee.CreateTensorWithDataAsOrtValue(
                    memInfo,
                    buf.baseAddress,
                    buf.count * MemoryLayout<Float>.size,
                    &shape, shape.count,
                    ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
                    &input))
            }
            defer { api.pointee.ReleaseValue(input) }

            var output: OpaquePointer?
            try inputName.withCString { inC in
                try outputName.withCString { outC in
                    var inNames: [UnsafePointer<CChar>?] = [inC]
                    var outNames: [UnsafePointer<CChar>?] = [outC]
                    var ins: [OpaquePointer?] = [input]
                    try check(api.pointee.Run(session, nil,
                                              &inNames, &ins, 1,
                                              &outNames, 1, &output))
                }
            }
            defer { api.pointee.ReleaseValue(output) }

            var raw: UnsafeMutableRawPointer?
            try check(api.pointee.GetTensorMutableData(output, &raw))
            if let p = raw?.assumingMemoryBound(to: Float.self) {
                for r in 0..<n {
                    for d in 0..<Self.embeddingDim {
                        sum[d] += Double(p[r * Self.embeddingDim + d])
                    }
                }
                seen += n
            }
            start += n
        }

        guard seen > 0 else { throw Failure.tooShort }
        var vec = sum.map { Float($0 / Double(seen)) }
        var norm: Float = 0
        for v in vec { norm += v * v }
        norm = norm.squareRoot() + 1e-9
        for i in 0..<vec.count { vec[i] /= norm }
        return vec
    }

    /// Convenience: 16 kHz mono float samples straight to a track vector.
    public func embed(audio: [Float], mel: MelSpectrogram) throws -> [Float] {
        guard let (patches, n) = mel.patches(audio) else { throw Failure.tooShort }
        return try embed(patches: patches, count: n)
    }
}
