import SwiftUI
import WebKit

/// Distraction-free reader. Extracts the page's main article with a
/// small density heuristic run inside the live web view, then renders
/// it into a DC-typeset HTML shell in a fresh, lightweight web view.
struct ReaderModeView: View {
    @Environment(BrowserEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    @State private var article: ReaderArticle?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if let article {
                    ReaderWebView(article: article)
                        .ignoresSafeArea(edges: .bottom)
                } else if failed {
                    ContentUnavailableView(
                        "No article found",
                        systemImage: "text.justify.left",
                        description: Text("This page doesn't have a "
                            + "readable article."))
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
            }
            .navigationTitle(article?.title ?? "Reader")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await extract() }
    }

    private func extract() async {
        guard let tab = engine.store.activeTab,
              let webView = engine.pool.existingView(for: tab.id) else {
            failed = true
            return
        }
        do {
            let result = try await webView.evaluateJavaScript(
                ReaderArticle.extractionScript)
            guard let dict = result as? [String: Any],
                  let html = dict["html"] as? String, !html.isEmpty else {
                failed = true
                return
            }
            article = ReaderArticle(
                title: dict["title"] as? String ?? tab.displayTitle,
                byline: dict["byline"] as? String ?? "",
                host: tab.url?.host() ?? "",
                bodyHTML: html)
        } catch {
            failed = true
        }
    }
}

struct ReaderArticle {
    let title: String
    let byline: String
    let host: String
    let bodyHTML: String

    /// Pick the densest text container: <article> if present, else the
    /// block element with the most paragraph text. Strips scripts, nav,
    /// asides, and forms from a clone before handing back its HTML.
    static let extractionScript = """
    (() => {
      const clean = (node) => {
        const clone = node.cloneNode(true);
        clone.querySelectorAll(
          'script,style,nav,aside,form,iframe,footer,header,' +
          'noscript,button,[role=navigation],[role=banner],' +
          '[aria-hidden=true]'
        ).forEach(el => el.remove());
        return clone.innerHTML;
      };
      let best = document.querySelector('article, [role=article], main');
      if (!best) {
        let bestScore = 0;
        document.querySelectorAll('div, section').forEach(el => {
          let score = 0;
          el.querySelectorAll(':scope > p, :scope > * > p').forEach(p => {
            score += p.innerText.length;
          });
          if (score > bestScore) { bestScore = score; best = el; }
        });
        if (bestScore < 400) best = null;
      }
      if (!best) return { html: '' };
      const byline = document.querySelector(
        '[rel=author], .byline, .author, [itemprop=author]');
      return {
        title: document.title,
        byline: byline ? byline.innerText.trim().slice(0, 120) : '',
        html: clean(best),
      };
    })()
    """

    /// DC-typeset shell: system serif-free stack, generous measure,
    /// monochrome, dark/light from the system.
    var pageHTML: String {
        """
        <!doctype html><html><head>
        <meta name="viewport"
              content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: light dark; }
          body {
            font: -apple-system-body, -apple-system, sans-serif;
            font-size: 19px; line-height: 1.6;
            max-width: 40em; margin: 0 auto;
            padding: 24px 20px 64px;
            color: #14161b; background: #F6F7F9;
          }
          @media (prefers-color-scheme: dark) {
            body { color: #F4F6F8; background: #0A0C0F; }
            a { color: #9AA1AC; }
          }
          h1 { font-size: 28px; line-height: 1.25;
               letter-spacing: -0.4px; margin: 0 0 4px; }
          .meta { font: 12px ui-monospace, monospace;
                  letter-spacing: 0.4px; text-transform: uppercase;
                  opacity: 0.5; margin-bottom: 32px; }
          img, video, svg { max-width: 100%; height: auto; }
          a { color: #5C636E; }
          pre { overflow-x: auto; font-size: 14px; }
          blockquote { margin: 0; padding-left: 16px;
                       border-left: 2px solid rgba(128,128,128,0.4);
                       opacity: 0.85; }
        </style></head><body>
        <h1>\(title.htmlEscaped)</h1>
        <div class="meta">\(byline.htmlEscaped)\(byline.isEmpty ? ""
            : " · ")\(host.htmlEscaped)</div>
        \(bodyHTML)
        </body></html>
        """
    }
}

private extension String {
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Minimal web view that renders the extracted article shell once.
struct ReaderWebView: UIViewRepresentable {
    let article: ReaderArticle

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.loadHTMLString(article.pageHTML, baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
