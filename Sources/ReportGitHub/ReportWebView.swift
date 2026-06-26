import AppKit
import SwiftUI
import WebKit

/// Renders a report's Markdown the same way the sibling MDViewer app does:
/// swift-markdown → HTML (MarkdownRenderer) shown in a WKWebView with MDViewer's
/// "Native" theme. A few overrides adapt MDViewer's full-window document framing
/// (centred card, large padding, drop shadow) to this embedded pane.
struct ReportWebView: NSViewRepresentable {
    let markdown: String

    private var html: String {
        MarkdownRenderer.htmlDocument(markdown: markdown, title: "Report",
                                      stylesheet: ReportTheme.css)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.underPageBackgroundColor = .clear
        // Let the SwiftUI pane behind show through where the page doesn't paint.
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String?

        // Open external links in the user's browser; never navigate the pane.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

/// MDViewer's "Native" theme (its default), embedded verbatim, with embed
/// overrides appended: the report fills the pane as one uniform surface with
/// modest padding rather than a centred, shadowed document page.
enum ReportTheme {
    static let css = nativeTheme + "\n" + embedOverrides

    private static let embedOverrides = """
    :root { --page-bg: var(--content-bg); }
    .markdown-body {
      max-width: 100%;
      min-height: 0;
      margin: 0;
      padding: 18px 24px 32px;
      box-shadow: none;
    }
    """

    private static let nativeTheme = """
    :root {
      --page-bg: #f5f5f7;
      --content-bg: #ffffff;
      --text: #1d1d1f;
      --muted: #6e6e73;
      --border: #d8d8de;
      --accent: #0a63c7;
      --inline-code-bg: #f0f2f5;
      --code-bg: #f6f7f9;
      --quote-bg: #f8f8fa;
      --content-width: 860px;
      --content-padding: 54px 64px 78px;
      --body-font: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    }

    @media (prefers-color-scheme: dark) {
      :root {
        --page-bg: #1e1e20;
        --content-bg: #252529;
        --text: #f5f5f7;
        --muted: #aaaab2;
        --border: #3c3c42;
        --accent: #7ab7ff;
        --inline-code-bg: #313136;
        --code-bg: #1f1f23;
        --quote-bg: #2b2b30;
      }
    }

    body { background: var(--page-bg); }

    .markdown-body {
      background: var(--content-bg);
      box-shadow: 0 24px 90px rgb(0 0 0 / 0.08);
    }

    h1, h2, h3, h4, h5, h6 {
      line-height: 1.18;
      margin: 1.65em 0 0.55em;
      font-weight: 680;
      letter-spacing: 0;
    }

    h1 { margin-top: 0; font-size: 2.35rem; }

    h2 {
      padding-bottom: 0.28em;
      border-bottom: 1px solid var(--border);
      font-size: 1.62rem;
    }

    h3 { font-size: 1.24rem; }

    p, ul, ol, blockquote, pre, table { margin: 1em 0; }

    a {
      color: var(--accent);
      text-decoration-thickness: 0.08em;
      text-underline-offset: 0.16em;
    }

    hr {
      height: 1px;
      border: 0;
      margin: 2rem 0;
      background: var(--border);
    }

    blockquote {
      margin-left: 0;
      padding: 0.05rem 1.1rem;
      border-left: 4px solid var(--accent);
      border-radius: 0 8px 8px 0;
      background: var(--quote-bg);
      color: var(--muted);
    }

    code {
      padding: 0.12em 0.34em;
      border-radius: 5px;
      background: var(--inline-code-bg);
      font-family: "SF Mono", ui-monospace, Menlo, monospace;
      font-size: 0.9em;
    }

    pre {
      overflow: auto;
      padding: 1rem 1.1rem;
      border: 1px solid var(--border);
      border-radius: 8px;
      background: var(--code-bg);
    }

    pre code { padding: 0; background: transparent; }

    table { width: 100%; border-collapse: collapse; }

    th, td {
      padding: 0.56rem 0.7rem;
      border: 1px solid var(--border);
      text-align: left;
    }

    th {
      background: color-mix(in srgb, var(--inline-code-bg) 72%, transparent);
      font-weight: 650;
    }

    img { max-width: 100%; height: auto; border-radius: 8px; }
    """
}
