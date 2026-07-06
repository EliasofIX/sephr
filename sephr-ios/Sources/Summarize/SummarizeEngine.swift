import Foundation
import UIKit
import WebKit

/// Runs one Summarize session: snapshot the visible page, extract its
/// body text, prompt the model, stream the answer into the session.
@MainActor
final class SummarizeEngine {

    private let model: ModelManager
    private var currentTask: Task<Void, Never>?

    init(model: ModelManager) { self.model = model }

    /// Begin summarizing the given web view. Returns a session
    /// immediately so the UI can attach the origami animation; the
    /// extraction + model stream run in the background.
    func start(webView: WKWebView,
               pageTitle: String,
               host: String,
               pageURL: URL?,
               snapshot: UIImage) -> SummarizeSession {
        cancel()
        let session = SummarizeSession(
            pageTitle: pageTitle, host: host,
            pageURL: pageURL, snapshot: snapshot)
        currentTask = Task { [weak self] in
            await self?.run(session: session, webView: webView)
        }
        return session
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    private func run(session: SummarizeSession,
                     webView: WKWebView) async {
        model.prepare()

        // 1. Reader-extract the live page into plain text.
        guard let extracted = await ReaderExtractor.extract(from: webView),
              !extracted.body.isEmpty else {
            session.fail("Nothing to summarize on this page.")
            return
        }

        // 2. Prompt the model.
        await model.waitUntilReady()
        session.startGenerating()
        let stream = model.answer(
            system: Prompts.summarizeSystem,
            user: Prompts.summarizeUserPrompt(
                pageTitle: session.pageTitle,
                host: session.host,
                bodyText: extracted.body))
        for await chunk in stream {
            guard !Task.isCancelled else { session.cancel(); return }
            session.appendSummaryChunk(chunk)
        }
        guard !Task.isCancelled else { session.cancel(); return }
        session.finishGenerating()
    }
}
