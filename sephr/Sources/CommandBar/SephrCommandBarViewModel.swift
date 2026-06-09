import AppKit
import Combine
import CAL

@MainActor
final class SephrCommandBarViewModel: ObservableObject {

    @Published var results: [SephrSearchResult] = []
    @Published var query: String = ""

    private let omnibox: CALOmnibox
    private weak var targetWindowController: SephrWindowController?
    /// Debounce token for omnibox queries. Cmd-T → type "github.com"
    /// previously fired 11 concurrent CALOmnibox queries, one per
    /// keystroke. We coalesce on a short trailing edge so the user's
    /// typing rate doesn't backpressure Chromium's AutocompleteController.
    private var searchPending: DispatchWorkItem?
    private static let searchDebounce: TimeInterval = 0.08

    init(windowController: SephrWindowController? = nil) {
        let pid = SephrSpaceManager.shared.currentSpace.profileID
        self.omnibox = CALOmnibox(forProfile: pid)
        self.targetWindowController = windowController
        // No default seeding: the command bar opens as a single empty
        // search pill (Spotlight-style). Results only appear once the
        // user types.
    }

    func search(_ text: String) {
        query = text
        guard !text.isEmpty else {
            searchPending?.cancel()
            searchPending = nil
            results = []
            return
        }
        searchPending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performSearch(text)
        }
        searchPending = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.searchDebounce, execute: work)
    }

    private func performSearch(_ text: String) {
        searchPending = nil
        // The user may have kept typing — only the latest query's
        // results should land. Snapshot the query at dispatch time so
        // we can drop stale callbacks.
        let inflightQuery = text
        omnibox.queryText(text) { [weak self] raw in
            guard let self, self.query == inflightQuery else { return }
            self.searchInline(raw, text: text)
        }
    }

    /// Result-assembly body, untouched in behaviour from the pre-debounce
    /// version. Lifted into a helper so `performSearch` can call it after
    /// the in-flight-query guard.
    private func searchInline(_ raw: [CALOmniboxResult], text: String) {
        var out: [SephrSearchResult] = []
        let searchURL = SephrSearchEngines.queryURL(for: text)
            ?? omnibox.defaultSearchURL(forQuery: text)
        out.append(.init(kind: .search,
                         title: "Search for \"\(text)\"",
                         subtitle: SephrSearchEngines.current.displayName,
                         url: searchURL,
                         favicon: nil))
        for r in raw {
            let kind: SephrSearchResult.Kind
            switch r.type {
            case "history":  kind = .history
            case "bookmark": kind = .bookmark
            case "search":   kind = .search
            default:         kind = .url
            }
            out.append(.init(kind: kind,
                             title: r.text,
                             subtitle: r.resultDescription ?? r.url,
                             url: r.url,
                             favicon: r.favicon))
        }
        // Prepend open-tab matches (local model; free, no async).
        let space = SephrSpaceManager.shared.currentSpace
        for t in SephrTabModel.shared.tabs(in: space)
            where t.title.localizedCaseInsensitiveContains(text)
               || t.url.localizedCaseInsensitiveContains(text) {
            out.insert(.init(kind: .tab,
                             title: t.title.isEmpty ? t.url : t.title,
                             subtitle: t.url,
                             url: t.url,
                             favicon: nil), at: 0)
        }
        results = out
    }

    func activateFirst() {
        // Smarter dispatch: if the user typed a URL-shaped string, navigate
        // to it directly. Otherwise — and only otherwise — fall through to
        // the search engine. This is what every shipping browser does and
        // what users expect from a Cmd-T → type → Enter flow.
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let resolved = Self.resolveAsURL(trimmed) {
            openURL(resolved)
            return
        }
        if let first = results.first {
            activate(first)
            return
        }
        openURL(SephrSearchEngines.queryURL(for: query)
                ?? omnibox.defaultSearchURL(forQuery: query))
    }

    /// Returns the input as a navigable URL if it parses as one, otherwise
    /// nil. Heuristics roughly match Chromium's omnibox URL detection:
    ///   * any explicit scheme (`https://…`, `sephr://…`, `file://…`)
    ///   * a host containing a `.` with no whitespace and at least one
    ///     character on either side of the dot (e.g. `example.com`,
    ///     `127.0.0.1`, `localhost:3000`)
    ///   * IPv4 literals
    /// `https://` is prepended when no scheme is given.
    private static func resolveAsURL(_ input: String) -> String? {
        guard !input.isEmpty, !input.contains(" ") else { return nil }
        if input.hasPrefix("sephr://") { return input }
        if input.hasPrefix("http://") || input.hasPrefix("https://") {
            return URL(string: input) != nil ? input : nil
        }
        if input.hasPrefix("file://") {
            return URL(string: input) != nil ? input : nil
        }
        // host[:port]/... — needs a dot or "localhost".
        if input.hasPrefix("localhost") || input.contains(".") {
            // Reject things like "..foo" or trailing dots only.
            let candidate = "https://" + input
            if URL(string: candidate) != nil {
                return candidate
            }
        }
        return nil
    }

    func activate(_ result: SephrSearchResult) {
        guard let url = result.url else { return }
        openURL(url)
    }

    // MARK: — Private

    private func openURL(_ url: String) {
        // Command-palette / Cmd-T flow always opens a NEW tab — replacing
        // the current tab is what the inline sidebar URL bar does (Arc
        // convention), but the palette is the equivalent of "new tab"
        // and should never stomp the tab you were already on.
        let space = SephrSpaceManager.shared.currentSpace
        let tab = SephrTabModel.shared.newTab(in: space, url: url)
        targetWindowController?.showTab(tab)
    }
}
