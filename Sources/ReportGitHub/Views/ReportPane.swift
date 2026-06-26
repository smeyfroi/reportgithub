import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ReportGitHubKit

/// The Report workspace: a view over the Find run's verified findings. The
/// deterministic comparison matrix is shown first (grounded, LLM-independent),
/// with the generated narrative below. Generation runs no sandboxed script — it
/// aggregates the findings and narrates the matrix, regenerable over the same
/// findings without re-running Find.
struct ReportPane: View {
    @Environment(AppModel.self) private var model

    private var matrix: FieldMatrix { model.reportMatrix }
    private var narrative: String {
        model.reportMarkdown.isEmpty ? (model.report?.markdown ?? "") : model.reportMarkdown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if matrix.isEmpty {
                emptyState
            } else if narrative.isEmpty {
                ScrollView {
                    matrixSection
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                // Matrix on top (interactive, selectable), the rendered report
                // below in its own WebView — each scrolls independently.
                VSplitView {
                    ScrollView {
                        matrixSection
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 120, idealHeight: 240, maxHeight: .infinity)

                    VStack(spacing: 0) {
                        ReportWebView(markdown: narrative)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if let report = model.report, !model.generatingReport {
                            attributionFooter(report)
                        }
                    }
                    .frame(minHeight: 220, maxHeight: .infinity)
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Label("Report", systemImage: "doc.text.magnifyingglass")
                .font(.headline)
            Spacer()
            if model.generatingReport {
                ProgressView().controlSize(.small)
                Button(role: .cancel) { model.cancelReport() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            } else {
                if model.report != nil {
                    Menu {
                        Button("Markdown (.md)") { save(.markdown) }
                        Button("Web Page (.html)") { save(.html) }
                    } label: {
                        Label("Save…", systemImage: "square.and.arrow.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Save the report to a file")
                }
                Button {
                    model.generateReport()
                } label: {
                    Label(model.report == nil ? "Generate report" : "Regenerate",
                          systemImage: "sparkles")
                }
                .disabled(!model.canGenerateReport)
                .help(matrix.isEmpty
                      ? "Run a Find that extracts parameters first — its findings feed the report"
                      : "Aggregate the \(matrix.repoCount) finding(s) into a report")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No findings to report on yet")
                .font(.headline)
            Text("Run a Find that extracts parameters (e.g. the \u{201C}Report on a CloudFormation resource\u{201D} recipe). Each verified match carries the fields the report compares.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: Matrix

    private var matrixSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Comparison")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(matrix.repoCount) repo(s) · \(matrix.columns.count) field(s) · \(model.reportCoverage.examined) examined")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                    GridRow {
                        Text("Repo").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                        ForEach(matrix.columns) { column in
                            Text(column.key).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                        }
                    }
                    Divider()
                    ForEach(matrix.rows) { row in
                        GridRow {
                            cell(text: shortRepo(row.repo), repo: row.repo, weight: .medium)
                            ForEach(matrix.columns) { column in
                                cell(text: row.cells[column.key] ?? "—", repo: row.repo,
                                     outlier: isOutlier(repo: row.repo, key: column.key))
                            }
                        }
                    }
                }
            }
            Text(matrix.outliers.isEmpty
                 ? "Select a row to inspect that repo's evidence on the right."
                 : "Outliers in orange. Select a row to inspect that repo's evidence on the right.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// One matrix cell: tappable to select the repo (so the DetailPane shows
    /// its evidence), highlighted when its row is selected, orange for outliers.
    private func cell(text: String, repo: String, outlier: Bool = false,
                      weight: Font.Weight = .regular) -> some View {
        Text(text)
            .font(.callout.weight(weight))
            .foregroundStyle(outlier ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(model.selectedRepo == repo ? Color.accentColor.opacity(0.15) : .clear)
            .contentShape(Rectangle())
            .onTapGesture { model.selectedRepo = repo }
    }

    private func isOutlier(repo: String, key: String) -> Bool {
        matrix.outliers.contains { $0.repo == repo && $0.key == key }
    }

    // MARK: Narrative

    private func attributionFooter(_ report: Report) -> some View {
        HStack {
            Text("Generated by \(report.model) · \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .overlay(alignment: .top) { Divider() }
    }

    private func shortRepo(_ fullName: String) -> String {
        fullName.split(separator: "/").last.map(String.init) ?? fullName
    }

    // MARK: Save

    private enum ReportFormat { case markdown, html }

    /// Save the report to a user-chosen file. Markdown writes the narrative as
    /// authored; HTML writes the same self-contained, styled document the pane
    /// renders (MDViewer's Native theme), openable in any browser.
    private func save(_ format: ReportFormat) {
        guard let report = model.report else { return }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Save Report"
        switch format {
        case .markdown:
            panel.nameFieldStringValue = "report.md"
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        case .html:
            panel.nameFieldStringValue = "report.html"
            panel.allowedContentTypes = [.html]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let content: String
        switch format {
        case .markdown:
            content = report.markdown
        case .html:
            content = MarkdownRenderer.htmlDocument(markdown: report.markdown,
                                                    title: "Report",
                                                    stylesheet: ReportTheme.css)
        }

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            model.statusLine = "Saved report to \(url.lastPathComponent)"
        } catch {
            model.statusLine = "Could not save report: \(error.localizedDescription)"
        }
    }
}
