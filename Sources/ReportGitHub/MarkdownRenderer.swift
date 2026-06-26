import Foundation
import Markdown

// Ported from the sibling MDViewer app so ReportGitHub renders Markdown
// identically: swift-markdown (cmark-gfm) parses the document, a MarkupWalker
// emits escaped HTML, and the result is wrapped with MDViewer's base CSS plus a
// theme stylesheet. Safe-by-default — text, raw HTML, and code are all escaped,
// so report content can never inject live markup into the WebView.

struct MarkdownHeading: Identifiable, Equatable {
    let id: String
    let level: Int
    let title: String
}

struct RenderedMarkdown: Equatable {
    let html: String
    let headings: [MarkdownHeading]
}

struct MarkdownRenderer {
    static func htmlDocument(markdown: String, title: String, stylesheet: String, errorMessage: String? = nil) -> String {
        render(markdown: markdown, title: title, stylesheet: stylesheet, errorMessage: errorMessage).html
    }

    static func render(markdown: String, title: String, stylesheet: String, errorMessage: String? = nil) -> RenderedMarkdown {
        let document = Document(parsing: markdown)
        var visitor = HTMLRenderVisitor()
        visitor.visit(document)

        let errorBanner = errorMessage.map {
            "<aside class=\"app-error\"><strong>Warning</strong><span>\(escapeHTML($0))</span></aside>"
        } ?? ""

        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escapeHTML(title))</title>
          <style>
          \(baseCSS)
          \(stylesheet)
          </style>
        </head>
        <body>
          <main class="markdown-body">
            \(errorBanner)
            \(visitor.result)
          </main>
        </body>
        </html>
        """

        return RenderedMarkdown(html: html, headings: visitor.headings)
    }

    private static let baseCSS = """
    :root {
      color-scheme: light dark;
      text-rendering: optimizeLegibility;
      -webkit-font-smoothing: antialiased;
    }

    body {
      margin: 0;
      background: var(--page-bg, Canvas);
      color: var(--text, CanvasText);
      font-family: var(--body-font, -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif);
      line-height: 1.62;
    }

    .markdown-body {
      box-sizing: border-box;
      max-width: var(--content-width, 840px);
      min-height: 100vh;
      margin: 0 auto;
      padding: var(--content-padding, 48px 56px 72px);
      background: var(--content-bg, transparent);
    }

    .app-error {
      display: grid;
      gap: 2px;
      margin: 0 0 24px;
      padding: 12px 14px;
      border: 1px solid color-mix(in srgb, #c7522a 42%, transparent);
      border-radius: 8px;
      background: color-mix(in srgb, #c7522a 10%, transparent);
      color: var(--text, CanvasText);
      font-size: 0.92rem;
    }

    .app-error span {
      color: var(--muted, #6b7280);
    }

    h1[id], h2[id], h3[id], h4[id], h5[id], h6[id] {
      scroll-margin-top: 28px;
    }

    .markdown-body li.task-list-item {
      list-style: none;
      margin-left: -1.4em;
    }

    .markdown-body li.task-list-item > input[type="checkbox"] {
      margin: 0 0.45em 0 0;
      vertical-align: middle;
    }

    @media (max-width: 720px) {
      .markdown-body {
        padding: 28px 24px 48px;
      }
    }
    """
}

/// Walks a parsed swift-markdown (cmark-gfm) tree and emits HTML. Output is
/// escaped by default; soft line breaks become `<br>` to preserve the source's
/// visual line breaks.
private struct HTMLRenderVisitor: MarkupWalker {
    var result = ""
    var headings: [MarkdownHeading] = []

    private var usedAnchors: [String: Int] = [:]
    private var inTableHead = false
    private var tableColumnAlignments: [Table.ColumnAlignment?]? = nil
    private var currentTableColumn = 0

    // MARK: Block elements

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        result += "<blockquote>\n"
        descendInto(blockQuote)
        result += "</blockquote>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        let languageAttr = codeBlock.language.map { " class=\"language-\(escapeAttribute($0))\"" } ?? ""
        var code = codeBlock.code
        if code.hasSuffix("\n") { code.removeLast() }
        result += "<pre><code\(languageAttr)>\(escapeHTML(code))</code></pre>\n"
    }

    mutating func visitHeading(_ heading: Heading) {
        let title = heading.plainText
        let anchor = uniqueAnchor(for: title)
        headings.append(MarkdownHeading(id: anchor, level: heading.level, title: title))
        result += "<h\(heading.level) id=\"\(escapeAttribute(anchor))\">"
        descendInto(heading)
        result += "</h\(heading.level)>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        result += "<hr>\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        var raw = html.rawHTML
        if raw.hasSuffix("\n") { raw.removeLast() }
        result += "<p>\(escapeHTML(raw).replacingOccurrences(of: "\n", with: "<br>\n"))</p>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) {
        if let checkbox = listItem.checkbox {
            let checked = checkbox == .checked ? " checked" : ""
            result += "<li class=\"task-list-item\"><input type=\"checkbox\" disabled\(checked)> "
        } else {
            result += "<li>"
        }

        let children = Array(listItem.children)
        if children.count == 1, let paragraph = children.first as? Paragraph {
            descendInto(paragraph)
        } else {
            for child in children { visit(child) }
        }

        result += "</li>\n"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        let start = orderedList.startIndex != 1 ? " start=\"\(orderedList.startIndex)\"" : ""
        result += "<ol\(start)>\n"
        descendInto(orderedList)
        result += "</ol>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        result += "<ul>\n"
        descendInto(unorderedList)
        result += "</ul>\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        result += "<p>"
        descendInto(paragraph)
        result += "</p>\n"
    }

    mutating func visitTable(_ table: Table) {
        result += "<table>\n"
        tableColumnAlignments = table.columnAlignments
        descendInto(table)
        tableColumnAlignments = nil
        result += "</table>\n"
    }

    mutating func visitTableHead(_ tableHead: Table.Head) {
        result += "<thead>\n<tr>\n"
        inTableHead = true
        currentTableColumn = 0
        descendInto(tableHead)
        inTableHead = false
        result += "</tr>\n</thead>\n"
    }

    mutating func visitTableBody(_ tableBody: Table.Body) {
        guard !tableBody.isEmpty else { return }
        result += "<tbody>\n"
        descendInto(tableBody)
        result += "</tbody>\n"
    }

    mutating func visitTableRow(_ tableRow: Table.Row) {
        result += "<tr>\n"
        currentTableColumn = 0
        descendInto(tableRow)
        result += "</tr>\n"
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) {
        guard let alignments = tableColumnAlignments, currentTableColumn < alignments.count else { return }
        guard tableCell.colspan > 0, tableCell.rowspan > 0 else { return }

        let element = inTableHead ? "th" : "td"
        result += "<\(element)"

        if let alignment = alignments[currentTableColumn] {
            result += " style=\"text-align:\(cssAlignment(alignment))\""
        }
        currentTableColumn += 1

        if tableCell.rowspan > 1 { result += " rowspan=\"\(tableCell.rowspan)\"" }
        if tableCell.colspan > 1 { result += " colspan=\"\(tableCell.colspan)\"" }

        result += ">"
        descendInto(tableCell)
        result += "</\(element)>\n"
    }

    // MARK: Inline elements

    mutating func visitText(_ text: Text) {
        result += escapeHTML(text.string)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        result += "<code>\(escapeHTML(inlineCode.code))</code>"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        printInline(tag: "em", emphasis)
    }

    mutating func visitStrong(_ strong: Strong) {
        printInline(tag: "strong", strong)
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        printInline(tag: "del", strikethrough)
    }

    mutating func visitImage(_ image: Image) {
        result += "<img"
        if let source = image.source, !source.isEmpty {
            result += " src=\"\(safeURL(source))\""
        }
        result += " alt=\"\(escapeAttribute(image.plainText))\""
        if let title = image.title, !title.isEmpty {
            result += " title=\"\(escapeAttribute(title))\""
        }
        result += ">"
    }

    mutating func visitLink(_ link: Link) {
        result += "<a"
        if let destination = link.destination {
            result += " href=\"\(safeURL(destination))\""
        }
        result += ">"
        descendInto(link)
        result += "</a>"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        result += escapeHTML(inlineHTML.rawHTML)
    }

    mutating func visitSymbolLink(_ symbolLink: SymbolLink) {
        if let destination = symbolLink.destination {
            result += "<code>\(escapeHTML(destination))</code>"
        }
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        result += "<br>\n"
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        result += "<br>\n"
    }

    // MARK: Helpers

    private mutating func printInline(tag: String, _ content: Markup) {
        result += "<\(tag)>"
        descendInto(content)
        result += "</\(tag)>"
    }

    private func cssAlignment(_ alignment: Table.ColumnAlignment) -> String {
        switch alignment {
        case .left: "left"
        case .center: "center"
        case .right: "right"
        }
    }

    private mutating func uniqueAnchor(for text: String) -> String {
        let base = slug(for: text)
        let count = usedAnchors[base, default: 0]
        usedAnchors[base] = count + 1
        return count == 0 ? base : "\(base)-\(count + 1)"
    }
}

// MARK: - Shared formatting helpers

private func slug(for text: String) -> String {
    var slug = ""
    var previousWasSeparator = false

    for character in text.lowercased() {
        if character.isLetter || character.isNumber {
            slug.append(character)
            previousWasSeparator = false
        } else if !previousWasSeparator {
            slug.append("-")
            previousWasSeparator = true
        }
    }

    let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? "section" : trimmed
}

private func safeURL(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowercased = trimmed.lowercased()

    if lowercased.hasPrefix("javascript:") || lowercased.hasPrefix("data:text/html") {
        return "#"
    }

    return escapeAttribute(trimmed)
}

private func escapeHTML(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

private func escapeAttribute(_ value: String) -> String {
    escapeHTML(value)
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}
