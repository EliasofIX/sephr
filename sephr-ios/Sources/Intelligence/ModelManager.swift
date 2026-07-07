import Foundation
import Observation
import os
import UIKit
#if canImport(LeapSDK)
@preconcurrency import LeapSDK
#endif

/// Observable wrapper around the on-device LFM2-VL-450M F16 runtime,
/// served by Liquid AI's unified LEAP SDK.
///
/// Two responsibilities: (a) drive the first-run download via LEAP's
/// `Leap.load(model:quantization:options:)`, and report progress to the
/// Settings UI; (b) expose a streaming `answer(...)` API the feature
/// engines call.
///
/// LEAP integration runs behind `#if canImport(LeapSDK)` so the rest of
/// the app builds even before the SwiftPM dependency is resolved — the
/// `MockBackend` returns a useful diagnostic stream in that case.
@Observable @MainActor
final class ModelManager {

    enum State: Equatable {
        case missing
        case downloading(progress: Double)
        case warming
        case ready
        case error(message: String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    /// Liquid AI's model identifier in the LEAP model library. The
    /// quantization string maps to the GGUF variant LEAP downloads.
    /// F16 is the full-precision GGUF variant — bigger (~711 MB) but
    /// materially better than Q4_0 on the kind of long-context grounded
    /// synthesis SuperBrowse asks for. LEAP's manifest keys are F16,
    /// Q8_0, and Q4_0 (not BF16).
    static let modelName = "LFM2-VL-450M"
    static let quantization = "F16"

    private static let log =
        Logger(subsystem: "com.sephr.ios", category: "ModelManager")

    #if canImport(LeapSDK)
    private let inferenceWorker = InferenceWorker()
    #endif

    private(set) var state: State = .missing
    private var preparation: Task<Void, Never>?

    init() {}

    // MARK: — Lifecycle

    /// Ensure weights are local and the runtime is loaded. Idempotent —
    /// concurrent callers share the same in-flight Task.
    func prepare() {
        if state.isReady { return }
        if preparation != nil { return }
        preparation = Task { [weak self] in
            await self?.runPreparation()
        }
    }

    /// Wait until the model is ready (or failed). Call before generation
    /// so prefill never races a still-warming runner.
    func waitUntilReady() async {
        prepare()
        _ = await preparation?.value
    }

    private func runPreparation() async {
        #if canImport(LeapSDK)
        state = .downloading(progress: 0)
        let (progressStream, continuation) =
            AsyncStream<Double>.makeStream(of: Double.self)
        let watcher = Task { @MainActor [weak self] in
            for await progress in progressStream {
                guard let self else { break }
                if progress >= 1.0 {
                    self.state = .warming
                } else {
                    self.state = .downloading(progress: progress)
                }
            }
        }
        let progressHandler: @Sendable (Double, Int64) -> Void
            = { progress, _ in
                continuation.yield(progress)
            }
        let cacheDir = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("leap-kv-cache", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: cacheDir, withIntermediateDirectories: true)
        // Match the 8 K soft prompt ceiling — a 32 K KV slot on F16 was
        // blowing the memory budget right when SuperBrowse starts prefill.
        let loadOptions = LiquidInferenceEngineManifestOptions(
            cacheOptions: .enabled(path: cacheDir.path),
            contextSize: 8_192)
        do {
            let runner = try await Leap.shared.load(
                model: Self.modelName,
                quantization: Self.quantization,
                options: loadOptions,
                progress: progressHandler)
            continuation.finish()
            _ = await watcher.value
            await inferenceWorker.install(runner)
            state = .ready
            Self.log.info("LEAP runner ready (F16, 8K context, KV cache on)")
        } catch {
            continuation.finish()
            _ = await watcher.value
            state = .error(message: error.localizedDescription)
        }
        preparation = nil
        #else
        try? await Task.sleep(for: .milliseconds(200))
        state = .ready
        preparation = nil
        #endif
    }

    /// Drop the in-memory runner and retry the load. With LEAP's default
    /// cache the next prepare() usually hits the local copy rather than
    /// re-downloading.
    func resetAndRedownload() {
        preparation?.cancel()
        preparation = nil
        #if canImport(LeapSDK)
        Task { await inferenceWorker.clear() }
        #endif
        state = .missing
        prepare()
    }

    // MARK: — Inference

    /// Streaming text-only answer. Yields incremental Markdown chunks.
    func answer(system: String, user: String) -> AsyncStream<String> {
        answer(system: system, user: user, image: nil)
    }

    /// Streaming answer with an optional vision input. The image is a
    /// JPEG-encoded `Data` blob (≤512×512 per LFM2-VL's native window —
    /// callers downsample before calling).
    func answer(system: String, user: String,
                image: Data?) -> AsyncStream<String> {
        #if canImport(LeapSDK)
        guard state.isReady else {
            return AsyncStream { continuation in
                continuation.yield(
                    "Model is not ready yet. Open Settings to retry.")
                continuation.finish()
            }
        }
        let started = Date()
        let metricsLog = Logger(
            subsystem: "com.sephr.ios", category: "Inference")
        return AsyncStream<String>(bufferingPolicy: .unbounded) {
            continuation in
            let task = Task {
                let stream = await inferenceWorker.streamAnswer(
                    system: system,
                    user: user,
                    image: image) {
                        let ttft = Date().timeIntervalSince(started)
                        metricsLog.info(
                            "TTFT \(ttft, format: .fixed(precision: 3))s")
                    }
                for await chunk in stream {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        #else
        return AsyncStream<String>(bufferingPolicy: .unbounded) {
            continuation in
            Task { @MainActor in
                await MockBackend.stream(
                    into: continuation, system: system, user: user)
            }
        }
        #endif
    }
}

#if !canImport(LeapSDK)
/// Deterministic stand-in until LEAP is wired. Lets the UI flow be
/// exercised without a real model — every answer is the same diagnostic.
private enum MockBackend {
    @MainActor
    static func stream(into continuation:
                       AsyncStream<String>.Continuation,
                       system: String, user: String) async {
        let body = """
        - **Mock backend active.** This build was compiled without LeapSDK; \
        the on-device model is not running.
        - **Wire LEAP via project.yml.** Resolve `LeapSDK` SwiftPM dep, then \
        rebuild so `canImport(LeapSDK)` lights up.
        - **Prompt received.** \(user.prefix(140))…
        """
        for piece in body.split(separator: " ", omittingEmptySubsequences: false) {
            continuation.yield(piece + " ")
            try? await Task.sleep(for: .milliseconds(15))
        }
        continuation.finish()
    }
}
#endif
