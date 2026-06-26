import AppKit
import SwiftUI
import ReportGitHubKit

struct DetailPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let result = model.selectedResult {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.repo.fullName)
                            .font(.headline)
                        HStack(spacing: 8) {
                            StatusBadge(status: result.status)
                            if let reason = result.reason {
                                Text(reason)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button {
                        open("\(model.settings.webHost)/\(result.repo.fullName)")
                    } label: {
                        Label("Open repository on GitHub", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.link)

                    ForEach(Array(result.evidence.enumerated()), id: \.offset) { _, evidence in
                        EvidenceView(evidence: evidence, repo: result.repo,
                                     webHost: model.settings.webHost)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        } else {
            ContentUnavailableView(
                "No repository selected",
                systemImage: "square.dashed",
                description: Text("Run a find script, then select a repository to inspect its evidence.")
            )
        }
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

struct EvidenceView: View {
    let evidence: Evidence
    let repo: RepoRef
    let webHost: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(evidence.path, systemImage: "doc.text")
                    .font(.system(.callout, design: .monospaced))
                Spacer()
                Button {
                    let url = "\(webHost)/\(repo.fullName)/blob/\(repo.defaultBranch)/\(evidence.path)"
                    if let link = URL(string: url) { NSWorkspace.shared.open(link) }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.link)
                .help("Open file on GitHub")
            }

            if let explanation = evidence.explanation {
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.green)
            }

            // The structured values this match contributed to the report — the
            // exact fields the comparison matrix aggregates, shown against the
            // evidence that backs them.
            if let fields = evidence.fields, !fields.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Extracted fields", systemImage: "tablecells")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(fields.keys.sorted(), id: \.self) { key in
                        HStack(alignment: .top, spacing: 8) {
                            Text(key)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(fields[key]?.displayString ?? "—")
                                .font(.caption)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)
            }

            // The host located the match against the real file at reportMatch
            // time and recorded which lines to highlight; the view just renders
            // them. Falls back to the script's excerpt when the host had no
            // cached content to anchor in, so the pane is never blank.
            if evidence.noSpecificLine == true {
                Text("No specific line to highlight — this match is described above.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(contextLines(evidence.context ?? evidence.excerpt), id: \.number) { line in
                        HStack(spacing: 8) {
                            Text(String(line.number))
                                .foregroundStyle(.tertiary)
                                .frame(minWidth: 28, alignment: .trailing)
                            Text(line.text.isEmpty ? " " : line.text)
                                .foregroundStyle(line.isMatch ? .primary : .secondary)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(line.isMatch ? Color.yellow.opacity(0.18) : .clear)
                    }
                }
                .padding(.vertical, 4)
                .textSelection(.enabled)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private struct ContextLine {
        let number: Int
        let text: String
        let isMatch: Bool
    }

    // The host decided which lines are the match (against the real file) and
    // recorded their absolute numbers; this is a pure integer-membership
    // render with no string matching and no silent degradation.
    private func contextLines(_ context: String) -> [ContextLine] {
        let start = evidence.contextStartLine ?? 1
        let matchSet = Set(evidence.matchLines ?? [])
        return context.components(separatedBy: "\n").enumerated().map { offset, text in
            let number = start + offset
            return ContextLine(number: number, text: text, isMatch: matchSet.contains(number))
        }
    }
}
