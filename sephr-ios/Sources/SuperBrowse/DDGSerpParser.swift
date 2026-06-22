import Foundation

/// Talks to html.duckduckgo.com — the HTML-only DDG endpoint that returns
/// clean, scraper-friendly markup without anti-bot games.
///
/// We don't run an HTML parser in Swift; we load the SERP into a hidden
/// WKWebView and let the in-page JS extract results. This module owns the
/// URL builder and the extraction JS.
enum DDGSerpParser {

    /// One result row off the SERP. `url` has already been unwrapped from
    /// DDG's `/l/?uddg=…` redirect if present.
    struct Result: Equatable {
        let title: String
        let url: URL
        let snippet: String
        var host: String { url.host() ?? "" }
    }

    /// Ordered list of SERP endpoints to try. We start with the standard
    /// `duckduckgo.com/html/` mirror (most permissive for a fresh visit),
    /// then fall back to the bare-bones `lite.duckduckgo.com/lite/` and
    /// only last to `html.duckduckgo.com` (which often serves an empty
    /// shell to unverified clients).
    static func serpURLs(for query: String) -> [URL] {
        let escaped = query.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? query
        return [
            URL(string: "https://duckduckgo.com/html/?q=" + escaped),
            URL(string: "https://lite.duckduckgo.com/lite/?q=" + escaped),
            URL(string: "https://html.duckduckgo.com/html/?q=" + escaped),
        ].compactMap { $0 }
    }

    /// JS that runs inside the loaded SERP webview. Returns an Array of
    /// `{ title, href, snippet }`. Tries the modern HTML-mirror selectors
    /// first, then the lite-mirror table layout, then a last-ditch sweep
    /// of any external-link anchor on the page.
    static let extractionScript: String = """
    (() => {
      const out = [];
      const seen = new Set();
      const isRealHref = (h) => {
        if (!h) return false;
        if (h.startsWith('javascript:') || h.startsWith('#')) return false;
        if (h.includes('duckduckgo.com/?q=')) return false;
        return true;
      };
      const push = (title, href, snippet) => {
        title = (title || '').replace(/\\s+/g, ' ').trim();
        href = (href || '').trim();
        if (!title || !isRealHref(href)) return;
        if (seen.has(href)) return;
        seen.add(href);
        out.push({ title, href, snippet: (snippet || '').trim() });
      };

      // Pass 1 — duckduckgo.com/html/ and html.duckduckgo.com layout.
      document.querySelectorAll('.result, .web-result').forEach(row => {
        if (row.classList.contains('result--ad') ||
            row.classList.contains('result--ad-light') ||
            row.classList.contains('result--spelling')) return;
        const a = row.querySelector('a.result__a, a.result__url');
        if (!a) return;
        const snippet = row.querySelector('.result__snippet');
        push(a.innerText, a.getAttribute('href'),
             snippet ? snippet.innerText : '');
      });

      // Pass 2 — lite.duckduckgo.com table layout.
      if (out.length === 0) {
        document.querySelectorAll('a.result-link, td.result-link a, ' +
                                  'a[rel="nofollow"]').forEach(a => {
          // Lite snippets live in the next-sibling row.
          const row = a.closest('tr');
          let snippet = '';
          if (row) {
            const next = row.nextElementSibling;
            if (next && next.querySelector) {
              const sn = next.querySelector('.result-snippet, td');
              if (sn) snippet = sn.innerText || '';
            }
          }
          push(a.innerText, a.getAttribute('href'), snippet);
        });
      }

      // Pass 3 — desperate fallback: any external anchor in the doc.
      if (out.length === 0) {
        document.querySelectorAll('a[href]').forEach(a => {
          const h = a.getAttribute('href') || '';
          if (h.startsWith('http://') || h.startsWith('https://')
              || h.startsWith('//duckduckgo.com/l/')) {
            push(a.innerText, h, '');
          }
        });
      }

      return out.slice(0, 12);
    })()
    """

    /// Convert the raw `[{title,href,snippet}]` payload from the JS into
    /// `Result`s, unwrapping DDG redirects and dropping anything we can't
    /// resolve to an http(s) URL.
    static func parse(_ raw: Any?) -> [Result] {
        guard let array = raw as? [[String: Any]] else { return [] }
        var results: [Result] = []
        for entry in array {
            guard let title = entry["title"] as? String,
                  let href = entry["href"] as? String,
                  let url = resolve(href: href) else { continue }
            let snippet = entry["snippet"] as? String ?? ""
            results.append(Result(title: title, url: url, snippet: snippet))
        }
        return results
    }

    /// Resolve a DDG href that may be a `/l/?uddg=ENCODED_URL` redirect
    /// into the underlying target URL.
    private static func resolve(href: String) -> URL? {
        // Already absolute: keep it.
        if let url = URL(string: href),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return url
        }
        // Relative DDG redirect: prepend the host so URLComponents parses it.
        let base = href.hasPrefix("//")
            ? "https:" + href
            : "https://duckduckgo.com" + (href.hasPrefix("/") ? href : "/" + href)
        guard let components = URLComponents(string: base) else { return nil }
        if let target = components.queryItems?
            .first(where: { $0.name == "uddg" })?.value,
           let decoded = target.removingPercentEncoding,
           let url = URL(string: decoded),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return url
        }
        return components.url
    }
}
