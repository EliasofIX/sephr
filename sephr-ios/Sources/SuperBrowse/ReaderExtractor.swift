import Foundation
import WebKit

/// Loads a page in a hidden WKWebView and runs an in-page reader script
/// to return a clean Markdown-ish body the model can chew on. Used by
/// SuperBrowse to populate the per-source `markdown` field on
/// `SuperBrowseSource`.
@MainActor
enum ReaderExtractor {

    /// Per-source character budget. LFM2-VL has a 32 768-token window;
    /// at ~3.5 chars/token, each source can carry ~16 000 chars and the
    /// six together still leave ~6 K tokens for system prompt + output.
    /// We sit at 14 K to keep a comfortable margin.
    static let perSourceCharacterBudget = 14_000

    /// Summarize-mode budget — one page, no fan-out, so we can spend
    /// the whole window on it. 80 K chars ≈ 22 K input tokens, leaving
    /// ~10 K for system + bullets.
    static let summarizePageCharacterBudget = 80_000

    /// Output from one extraction attempt. `body` is empty if the page
    /// had no readable article.
    struct Extracted: Equatable {
        let title: String
        let body: String
    }

    /// The extraction JS. Picks the densest article-like container (same
    /// heuristic as `ReaderArticle.extractionScript`), strips boilerplate,
    /// then returns the title + a paragraph-separated plain-text body.
    /// Returning plain text instead of HTML keeps the token budget honest
    /// and avoids leaking tag noise into the model's input.
    static let extractionScript: String = """
    (() => {
      const clean = (node) => {
        const clone = node.cloneNode(true);
        clone.querySelectorAll(
          'script,style,nav,aside,form,iframe,footer,header,' +
          'noscript,button,[role=navigation],[role=banner],' +
          '[aria-hidden=true],figure'
        ).forEach(el => el.remove());
        return clone;
      };
      let best = document.querySelector('article, [role=article], main');
      if (!best) {
        let bestScore = 0;
        document.querySelectorAll('div, section').forEach(el => {
          let score = 0;
          el.querySelectorAll(':scope > p, :scope > * > p').forEach(p => {
            score += (p.innerText || '').length;
          });
          if (score > bestScore) { bestScore = score; best = el; }
        });
        if (bestScore < 400) best = null;
      }
      if (!best) return { title: document.title || '', body: '' };
      const cleaned = clean(best);
      // Flatten to paragraph-separated plain text.
      const parts = [];
      cleaned.querySelectorAll(
        'h1, h2, h3, h4, p, li, blockquote, pre'
      ).forEach(el => {
        const t = (el.innerText || '').trim();
        if (!t) return;
        if (el.tagName === 'H1' || el.tagName === 'H2'
            || el.tagName === 'H3' || el.tagName === 'H4') {
          parts.push('\\n## ' + t);
        } else if (el.tagName === 'LI') {
          parts.push('- ' + t);
        } else {
          parts.push(t);
        }
      });
      return {
        title: document.title || '',
        body: parts.join('\\n\\n')
      };
    })()
    """

    /// Run the extraction script against an already-loaded WKWebView.
    /// Returns nil if the page has no readable article.
    static func extract(from webView: WKWebView) async -> Extracted? {
        do {
            let raw = try await webView.evaluateJavaScript(extractionScript)
            guard let dict = raw as? [String: Any],
                  let body = dict["body"] as? String,
                  !body.isEmpty else { return nil }
            let title = (dict["title"] as? String) ?? ""
            return Extracted(title: title,
                             body: truncate(body, to: perSourceCharacterBudget))
        } catch {
            return nil
        }
    }

    /// Cap a string at `n` characters at the last whitespace boundary,
    /// appending an ellipsis if it had to be cut.
    static func truncate(_ text: String, to n: Int) -> String {
        guard text.count > n else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: n)
        let head = text[..<endIndex]
        if let lastSpace = head.lastIndex(where: { $0.isWhitespace }) {
            return String(text[..<lastSpace]) + "…"
        }
        return String(head) + "…"
    }
}
