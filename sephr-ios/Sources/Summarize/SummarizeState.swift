import Foundation
import UIKit
import Observation

/// One Summarize session — created on pinch-in, lives until the user
/// dismisses the overlay. The snapshot we capture at the moment of the
/// gesture is what we fold and what stays visible at the top of the
/// summary card.
@Observable @MainActor
final class SummarizeSession {

    enum Phase: Equatable {
        case folding
        case generating
        case done
        case cancelled
        case error(message: String)
    }

    let pageTitle: String
    let host: String
    let pageURL: URL?
    let snapshot: UIImage

    private(set) var phase: Phase = .folding
    private(set) var summaryMarkdown: String = ""

    init(pageTitle: String, host: String, pageURL: URL?,
         snapshot: UIImage) {
        self.pageTitle = pageTitle
        self.host = host
        self.pageURL = pageURL
        self.snapshot = snapshot
    }

    func startGenerating() { phase = .generating }
    func appendSummaryChunk(_ chunk: String) { summaryMarkdown += chunk }
    func finishGenerating()  { phase = .done }
    func fail(_ message: String) { phase = .error(message: message) }
    func cancel() { phase = .cancelled }
}
