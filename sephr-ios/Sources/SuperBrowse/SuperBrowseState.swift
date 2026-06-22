import Foundation
import Observation

/// One Run of a SuperBrowse query — owned by `BrowserEngine`, observed by
/// `SuperBrowseHeroView` / `SuperBrowseResultView`. Each query gets a
/// fresh session; cancelling SuperBrowse just cancels the session's task.
@Observable @MainActor
final class SuperBrowseSession {

    enum Phase: Equatable {
        case fetchingSerp                  // hitting DDG
        case readingPages                  // scraping the top N results
        case generating                    // streaming the answer from the model
        case done                          // model finished
        case cancelled
        case error(message: String)
    }

    let question: String

    /// What the user sees in the loading hero — populated as DDG returns,
    /// then trimmed as each page either parses or fails.
    private(set) var hostsBeingRead: [String] = []

    /// What gets fed to the model. Same order as the [N] citations.
    private(set) var sources: [SuperBrowseSource] = []

    /// Streaming answer Markdown.
    private(set) var answerMarkdown: String = ""

    /// Cited [N] indices in first-appearance order.
    private(set) var citedIndices: [Int] = []

    /// Current phase; setter is fileprivate.
    var phase: Phase = .fetchingSerp

    init(question: String) { self.question = question }

    // MARK: — Mutations (called from SuperBrowseEngine)

    func setSerpCandidates(_ hosts: [String]) {
        hostsBeingRead = hosts
        phase = .readingPages
    }

    func appendSource(_ source: SuperBrowseSource) {
        sources.append(source)
    }

    func startGenerating() {
        phase = .generating
    }

    func appendAnswerChunk(_ chunk: String) {
        answerMarkdown += chunk
    }

    func finishGenerating() {
        citedIndices = CitationValidator.citedIndices(
            in: answerMarkdown, sourceCount: sources.count)
        phase = .done
    }

    func fail(_ message: String) {
        phase = .error(message: message)
    }

    func cancel() {
        phase = .cancelled
    }
}
