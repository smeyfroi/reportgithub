import SwiftUI
import CodeEditor
import ReportGitHubKit

struct ScriptPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 6) {
            // The prompt is the user's words — what they recognise the job
            // by — so it gets visual primacy over the generated code, and an
            // unmistakable "this goes to the AI" treatment: sparkles and a
            // soft gradient border, with room to breathe.
            HStack(alignment: .center, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15))
                        .foregroundStyle(LinearGradient(colors: [.purple, .blue],
                                                        startPoint: .top, endPoint: .bottom))
                    TextField(promptPlaceholder,
                              text: $model.prompt, axis: .vertical)
                        .lineLimit(2...6)
                        // The ranged lineLimit grows with content but does
                        // not reserve height — guarantee room for two full
                        // lines so a two-line prompt never scrolls. maxWidth
                        // pins the field to the available width so long words
                        // wrap instead of overflowing the row.
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .font(.system(size: 15))
                        .textFieldStyle(.plain)
                        .focusEffectDisabled()
                        .onSubmit { model.generate() }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(LinearGradient(colors: [.purple.opacity(0.55), .blue.opacity(0.45)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing),
                                      lineWidth: 1.5)
                )
                Button(model.generating ? "Generating…" : "Generate") {
                    model.generate()
                }
                .controlSize(.large)
                .disabled(model.generating || model.running || model.prompt.isEmpty)
            }
            .padding([.top, .horizontal], 10)

            CodeEditor(source: $model.scriptText,
                       language: .typescript,
                       theme: colorScheme == .dark ? .atelierSavannaDark : .atelierSavannaLight,
                       inset: CGSize(width: 8, height: 8))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 10)

            if !model.visibleParamKeys.isEmpty {
                ParamsBar()
                    .padding(.horizontal, 10)
            }

            if !model.diagnostics.isEmpty {
                DiagnosticsList()
                    .frame(maxHeight: 110)
                    .padding(.horizontal, 10)
            }

            HStack {
                // Determinate meter whenever the run has a known denominator
                // (scan via candidate rows; Update/Merge via the worked set) —
                // otherwise the indeterminate spinner. model.runProgress owns
                // the per-phase logic; here it's just processed-of-total.
                if let progress = model.runProgress {
                    ProgressView(value: Double(progress.processed), total: Double(progress.total))
                        .controlSize(.small)
                        .frame(width: 130)
                    Text("\(progressVerb) \(progress.processed) of \(progress.total)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    if model.running || model.validating || model.generating {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(model.statusLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                Text("\(model.visibleRowCount) repos")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .padding([.horizontal, .bottom], 10)
        }
    }

    private var promptPlaceholder: String {
        switch model.phase {
        case .check: return "Describe what to find — and which parameters to extract — across the organisation…"
        case .report: return "Generate a report from the Find results…"
        }
    }

    /// Leading word for the progress meter — a Find scan "Scanned" repos.
    private var progressVerb: String {
        model.runHadCandidates ? "Scanned" : "Processed"
    }
}

/// Editable parameters surfaced from the script's meta.params — tweak a job
/// without re-prompting or editing code. A wrapping grid of labelled fields:
/// nothing crops off-screen, however many params a script declares.
///
/// The mechanism is stated in the header (these are runtime inputs the
/// script reads as job.params; the source keeps its declared defaults), and
/// an edited value is visibly marked, with the script's own default a click
/// away — so "does editing this do anything?" never needs guessing.
struct ParamsBar: View {
    @Environment(AppModel.self) private var model

    /// meta.params keys that are git/PR structure rather than recipe logic.
    /// They're grouped apart from the search/replace params because they're
    /// "special" — the job branch and commit message, always present in
    /// generated update scripts and structural rather than job-specific.
    static let gitParamKeys: Set<String> = ["branch", "message", "commitMessage"]

    var body: some View {
        let gitKeys = model.visibleParamKeys.filter { Self.gitParamKeys.contains($0) }
        let otherKeys = model.visibleParamKeys.filter { !Self.gitParamKeys.contains($0) }
        VStack(alignment: .leading, spacing: 8) {
            if !otherKeys.isEmpty {
                paramGroup(title: "Parameters", systemImage: "slider.horizontal.3",
                           caption: "override the script's meta.params defaults on the next run (the script reads job.params; the source is untouched)",
                           keys: otherKeys)
            }
            if !gitKeys.isEmpty {
                paramGroup(title: "Branch & commit", systemImage: "arrow.triangle.branch",
                           caption: "the job branch and commit message this run will use",
                           keys: gitKeys)
            }
        }
    }

    private func paramGroup(title: String, systemImage: String,
                            caption: String, keys: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("— \(caption)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .help("The script declares names and defaults in meta.params and reads the effective values from job.params at run time. Edits here apply to the next run without changing the script source — changed values are marked and can be reset to the script's default.")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 380),
                                         spacing: 8, alignment: .topLeading)],
                      alignment: .leading, spacing: 8) {
                ForEach(keys, id: \.self) { key in
                    paramField(key)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func paramField(_ key: String) -> some View {
        let edited = isEdited(key)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(key)
                    .font(.caption2)
                    .foregroundStyle(edited ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fontWeight(edited ? .semibold : .regular)
                if edited {
                    Text("edited")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Button {
                        model.paramsDraft[key] = model.declaredDefault(for: key)
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("Reset to the script's default: \(model.declaredDefault(for: key) ?? "")")
                }
            }
            TextField(key, text: binding(for: key))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
        }
    }

    /// Edited = differs from the script's declared default. Unknown defaults
    /// (script not validated since it changed) are never marked.
    private func isEdited(_ key: String) -> Bool {
        guard let declared = model.declaredDefault(for: key) else { return false }
        return (model.paramsDraft[key] ?? "") != declared
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { model.paramsDraft[key] ?? "" },
            set: { model.paramsDraft[key] = $0 }
        )
    }
}

struct DiagnosticsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.diagnostics) { diagnostic in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: icon(for: diagnostic.severity))
                            .foregroundStyle(color(for: diagnostic.severity))
                            .font(.caption)
                        if diagnostic.line > 0 {
                            Text("\(diagnostic.line):\(diagnostic.column)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Text(diagnostic.message)
                            .font(.caption)
                            .textSelection(.enabled)
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private func icon(for severity: Diagnostic.Severity) -> String {
        switch severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }

    private func color(for severity: Diagnostic.Severity) -> Color {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }
}
