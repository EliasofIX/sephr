import Foundation
import WebKit

/// Orchestrates one SuperBrowse query end-to-end:
///
/// 1. Fetch the DDG SERP in a hidden WKWebView.
/// 2. Extract the top six result candidates.
/// 3. Fan-out fetch each candidate in parallel; reader-extract its body.
/// 4. Build the grounded prompt and stream the model's answer.
///
/// All of (1–3) runs while the loading hero is visible; (4) starts as
/// soon as we have any usable sources.
@MainActor
final class SuperBrowseEngine {

    private let model: ModelManager
    private var currentTask: Task<Void, Never>?

    /// Maximum top-N from the SERP we'll actually read. Six is the same
    /// number Arc's leaked prompt allocates.
    private let maxSources = 6

    /// Don't even try to call the model with fewer than this many
    /// successfully-read sources.
    private let minSources = 1

    init(model: ModelManager) { self.model = model }

    /// Kick off a session for the given question. Returns the session so
    /// the UI can subscribe immediately; cancellation is via `cancel()`.
    func start(question: String) -> SuperBrowseSession {
        cancel()
        let session = SuperBrowseSession(question: question)
        currentTask = Task { [weak self] in
            await self?.run(session)
        }
        return session
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: — Pipeline

    private func run(_ session: SuperBrowseSession) async {
        // Make sure the model is at least warming. SuperBrowse can run the
        // SERP fetch + page reads in parallel with the download/warm so
        // first-token latency is hidden under network time.
        model.prepare()

        // 1. SERP — walk through the endpoint fallback list until one
        // returns parseable results. Each candidate gets one try; we
        // stop as soon as parsing yields something.
        let serpURLs = DDGSerpParser.serpURLs(for: session.question)
        guard !serpURLs.isEmpty else {
            session.fail("Couldn't build a search URL.")
            return
        }
        let fleet = HiddenWebViewFleet()
        var candidates: [DDGSerpParser.Result] = []
        var lastDiagnostic = ""
        for serpURL in serpURLs {
            guard !Task.isCancelled else { session.cancel(); return }
            let outcome = await fleet.fetch(serpURL)
            guard case let .loaded(serpView) = outcome else {
                lastDiagnostic =
                    "SERP fetch failed at \(serpURL.host ?? "?")"
                continue
            }
            let rawSerp = try? await serpView.evaluateJavaScript(
                DDGSerpParser.extractionScript)
            serpView.stopLoading()
            serpView.navigationDelegate = nil
            let parsed = DDGSerpParser.parse(rawSerp)
            if !parsed.isEmpty {
                candidates = Array(parsed.prefix(maxSources))
                break
            }
            lastDiagnostic =
                "Empty SERP from \(serpURL.host ?? "?")"
        }
        guard !candidates.isEmpty else {
            session.fail("DuckDuckGo returned no usable results. "
                         + (lastDiagnostic.isEmpty
                            ? "" : "(\(lastDiagnostic))"))
            return
        }
        session.setSerpCandidates(candidates.map { $0.host })

        // 2. Fan-out reads — two at a time so six hidden WKWebViews never
        // share the heap with the F16 runner at the ingestion handoff.
        for batchStart in stride(from: 0, to: candidates.count, by: 2) {
            guard !Task.isCancelled else { session.cancel(); return }
            let batchEnd = min(batchStart + 2, candidates.count)
            let batch = Array(candidates[batchStart..<batchEnd])
            await withTaskGroup(of: (Int, SuperBrowseSource?).self) { group in
                for (offset, candidate) in batch.enumerated() {
                    let index = batchStart + offset
                    group.addTask { @MainActor [weak self] in
                        let source = await self?.read(
                            candidate: candidate, fleet: fleet)
                        return (index, source)
                    }
                }
                var indexed: [(Int, SuperBrowseSource)] = []
                for await (index, source) in group {
                    guard !Task.isCancelled else { return }
                    if let source { indexed.append((index, source)) }
                }
                for (_, source) in indexed.sorted(by: { $0.0 < $1.0 }) {
                    session.appendSource(source)
                }
            }
        }
        guard !Task.isCancelled else { session.cancel(); return }
        guard session.sources.count >= minSources else {
            session.fail("Couldn't read any of the top results.")
            return
        }

        // 3. Stream the answer
        await model.waitUntilReady()
        session.startGenerating()
        let stream = model.answer(
            system: Prompts.superBrowseSystem,
            user: Prompts.superBrowseUserPrompt(
                question: session.question,
                sources: session.sources))
        for await chunk in stream {
            guard !Task.isCancelled else { session.cancel(); return }
            session.appendAnswerChunk(chunk)
        }
        guard !Task.isCancelled else { session.cancel(); return }
        session.finishGenerating()
    }

    /// One source's lifecycle: fetch with the fleet → reader-extract →
    /// build a `SuperBrowseSource`. Nil for any failure step.
    private func read(candidate: DDGSerpParser.Result,
                      fleet: HiddenWebViewFleet) async -> SuperBrowseSource? {
        let outcome = await fleet.fetch(candidate.url)
        guard case let .loaded(view) = outcome else { return nil }
        defer {
            view.stopLoading()
            view.navigationDelegate = nil
        }
        guard let extracted = await ReaderExtractor.extract(from: view) else {
            // Fallback: take just the SERP snippet so the source isn't lost
            // entirely. Better a thin source than a missing one.
            guard !candidate.snippet.isEmpty else { return nil }
            return SuperBrowseSource(
                url: candidate.url,
                title: candidate.title,
                host: candidate.host,
                markdown: candidate.snippet)
        }
        let title = extracted.title.isEmpty ? candidate.title : extracted.title
        return SuperBrowseSource(
            url: candidate.url,
            title: title,
            host: candidate.host,
            markdown: extracted.body)
    }
}
