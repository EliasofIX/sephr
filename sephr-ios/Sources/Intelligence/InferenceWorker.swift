import Foundation
import os
#if canImport(LeapSDK)
@preconcurrency import LeapSDK
#endif

#if canImport(LeapSDK)
/// Owns the loaded `ModelRunner` and runs generation off the main actor so
/// long prefill passes do not contend with SwiftUI layout.
actor InferenceWorker {

    private static let log =
        Logger(subsystem: "com.sephr.ios", category: "Inference")

    /// Soft ceiling from empirical SuperBrowse/Summarize runs in
    /// `Prompts.swift` — not the 32 K runtime window.
    private static let softPromptTokenCeiling = 8_192

    private static let generationOptions = GenerationOptions()
        .with(temperature: 0.3)
        .with(minP: 0.15)
        .with(repetitionPenalty: 1.1)
        .with(maxTokens: 2_048)

    private var runner: (any ModelRunner)?

    func install(_ runner: any ModelRunner) {
        self.runner = runner
    }

    func clear() {
        runner = nil
    }

    /// Stream an answer. `onFirstChunk` fires once when the first text token
    /// arrives — used for TTFT metrics.
    func streamAnswer(
        system: String,
        user: String,
        image: Data?,
        onFirstChunk: (@Sendable () -> Void)? = nil
    ) -> AsyncStream<String> {
        AsyncStream<String>(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                await self.pumpAnswer(
                    system: system,
                    user: user,
                    image: image,
                    onFirstChunk: onFirstChunk,
                    continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func pumpAnswer(
        system: String,
        user: String,
        image: Data?,
        onFirstChunk: (@Sendable () -> Void)?,
        continuation: AsyncStream<String>.Continuation
    ) async {
        guard let runner = self.runner else {
            continuation.finish()
            return
        }
        do {
            let trimmedUser = try await trimUserPrompt(
                system: system,
                user: user)
            let conversation =
                runner.createConversation(systemPrompt: system)
            var userContent: [ChatMessageContent] = []
            if let image {
                userContent.append(try .fromJPEGData(image))
            }
            userContent.append(.text(trimmedUser))
            let userMessage = ChatMessage_withArray(
                role: .user, content: userContent)

            let stream = conversation.generateResponse(
                message: userMessage,
                generationOptions: Self.generationOptions)
            var sawFirstChunk = false
            for try await response in stream {
                if Task.isCancelled {
                    continuation.finish()
                    return
                }
                switch onEnum(of: response) {
                case let .chunk(chunk):
                    if !sawFirstChunk {
                        sawFirstChunk = true
                        onFirstChunk?()
                    }
                    continuation.yield(chunk.text)
                case .reasoningChunk:
                    continue
                case let .complete(completion):
                    if let stats = completion.stats {
                        let cached = stats.cachedPromptTokens
                        let prompt = stats.promptTokens
                        let hitRate = prompt > 0
                            ? Double(cached) / Double(prompt) : 0
                        Self.log.info(
                            """
                            prefill prompt=\(prompt) \
                            cached=\(cached) hitRate=\(hitRate, format: .fixed(precision: 2)) \
                            completion=\(stats.completionTokens) \
                            tok/s=\(stats.tokenPerSecond, format: .fixed(precision: 1))
                            """)
                    }
                    continuation.finish()
                    return
                case .error, .functionCalls, .audioSample:
                    continue
                }
            }
            continuation.finish()
        } catch {
            continuation.yield(
                "\n\nGeneration failed: \(error.localizedDescription)")
            continuation.finish()
        }
    }

    private func trimUserPrompt(
        system: String,
        user: String
    ) async throws -> String {
        guard let runner = self.runner else { return user }
        let normalized = ReaderExtractor.normalizeForModel(user)
        let systemMessage = ChatMessage_withArray(
            role: .system, content: [.text(system)])
        let systemTokens = Int(
            try await runner.getPromptTokensSize(
                messages: [systemMessage],
                addBosToken: true).intValue)
        let userBudget = max(
            512, Self.softPromptTokenCeiling - systemTokens)

        var candidate = normalized
        var userMessage = ChatMessage_withArray(
            role: .user, content: [.text(candidate)])
        var total = Int(
            try await runner.getPromptTokensSize(
                messages: [systemMessage, userMessage],
                addBosToken: true).intValue)

        guard total > Self.softPromptTokenCeiling else { return candidate }

        var paragraphs = candidate
            .components(separatedBy: "\n\n")
            .filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

        while paragraphs.count > 1, total > Self.softPromptTokenCeiling {
            paragraphs.removeLast()
            candidate = paragraphs.joined(separator: "\n\n")
            userMessage = ChatMessage_withArray(
                role: .user, content: [.text(candidate)])
            total = Int(
                try await runner.getPromptTokensSize(
                    messages: [systemMessage, userMessage],
                    addBosToken: true).intValue)
        }

        if total > Self.softPromptTokenCeiling {
            let charBudget = max(256, userBudget * 35 / 10)
            return ReaderExtractor.truncate(candidate, to: charBudget)
        }
        return candidate
    }
}
#endif
