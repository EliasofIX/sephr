import Foundation
import Observation
import UIKit
#if canImport(LeapSDK)
import LeapSDK
#endif

/// Observable wrapper around the on-device LFM2-VL-450M Q4_0 runtime,
/// served by Liquid AI's LEAP iOS SDK.
///
/// Two responsibilities: (a) drive the first-run download via LEAP's
/// `Leap.load(model:quantization:downloadProgressHandler:)`, and report
/// progress to the Settings UI; (b) expose a streaming `answer(...)` API
/// the feature engines call.
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
    /// BF16 is the full-precision weights Liquid trained on — bigger
    /// (~711 MB) but materially better than Q4_0 on the kind of
    /// long-context grounded synthesis SuperBrowse asks for.
    static let modelName = "LFM2-VL-450M"
    static let quantization = "BF16"

    /// Liquid's published sampling defaults for LFM2-VL, plus an
    /// explicit 32 K sequence length (the model's full native context
    /// window) and a 2 K output cap so we never let the model loop into
    /// the runtime ceiling.
    private static let vlGenerationOptions = makeGenerationOptions()

    #if canImport(LeapSDK)
    private static func makeGenerationOptions() -> GenerationOptions {
        GenerationOptions(
            temperature: 0.3,
            minP: 0.15,
            repetitionPenalty: 1.1,
            sequenceLength: 32_768,
            maxOutputTokens: 2_048)
    }
    #else
    private static func makeGenerationOptions() -> Int { 0 }
    #endif

    private(set) var state: State = .missing
    private var preparation: Task<Void, Never>?

    #if canImport(LeapSDK)
    private var runner: (any ModelRunner)?
    #endif

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

    private func runPreparation() async {
        #if canImport(LeapSDK)
        // LEAP handles the download itself — including caching to
        // Application Support — and streams progress 0..1. We bridge
        // its non-isolated progress callback into our @MainActor state
        // via an AsyncStream so the callback closure captures only the
        // continuation (Sendable) and not `self`.
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
        do {
            let runner = try await Leap.load(
                model: Self.modelName,
                quantization: Self.quantization,
                options: nil,
                downloadProgressHandler: progressHandler)
            continuation.finish()
            _ = await watcher.value
            self.runner = runner
            state = .ready
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
    /// re-downloading — use `LeapModelDownloader.removeModel(...)` if a
    /// true purge is needed (separate SwiftPM product).
    func resetAndRedownload() {
        preparation?.cancel()
        preparation = nil
        #if canImport(LeapSDK)
        runner = nil
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
        AsyncStream { continuation in
            Task { [weak self] in
                guard let self else { continuation.finish(); return }
                guard self.state.isReady else {
                    continuation.yield(
                        "Model is not ready yet. Open Settings to retry.")
                    continuation.finish()
                    return
                }

                #if canImport(LeapSDK)
                guard let runner = self.runner else {
                    continuation.finish(); return
                }
                let systemMessage = ChatMessage(
                    role: .system, content: [.text(system)])
                var userContent: [ChatMessageContent] = []
                if let image {
                    userContent.append(.fromJPEGData(image))
                }
                userContent.append(.text(user))
                let userMessage = ChatMessage(
                    role: .user, content: userContent)

                let conversation = Conversation(
                    modelRunner: runner,
                    history: [systemMessage])
                do {
                    let stream = conversation.generateResponse(
                        message: userMessage,
                        generationOptions: Self.vlGenerationOptions)
                    for try await response in stream {
                        switch response {
                        case let .chunk(text):
                            continuation.yield(text)
                        case .reasoningChunk:
                            continue
                        case .complete:
                            continuation.finish()
                            return
                        @unknown default:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.yield(
                        "\n\nGeneration failed: \(error.localizedDescription)")
                    continuation.finish()
                }
                #else
                await MockBackend.stream(into: continuation,
                                         system: system, user: user)
                #endif
            }
        }
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
