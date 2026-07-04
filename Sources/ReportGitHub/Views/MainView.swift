import SwiftUI
import ReportGitHubKit

struct MainView: View {
    @Environment(AppModel.self) private var model
    // Measured width of the middle workbench column, used to pin its panes.
    @State private var workbenchWidth: CGFloat = 0

    var body: some View {
        @Bindable var model = model
        // Plain VStack rather than a safeAreaInset overlay: the footer takes
        // its own space, so scrolling content (console, results) can never
        // hide its last line underneath it.
        VStack(spacing: 0) {
            // Deterministic three-pane tiling via HSplitView, NOT
            // NavigationSplitView: on macOS 26 the navigation sidebars are
            // glass panels floating over a full-width content layer, and the
            // safe-area insets that should keep content out from under them
            // are lost inside VSplitView — SwiftUI rows ended up laid out
            // under both panels (AppKit-backed editor/table re-inset
            // themselves, which is why only some rows looked broken).
            // HSplitView has no overlay layer: panes are always side-by-side
            // and dividers always drag. The middle workbench is the only
            // pane free to flex.
            // HSplitView/VSplitView panes are not greedy: each needs an
            // explicit max to fill its slot instead of collapsing to its
            // ideal size and centering.
            HSplitView {
                SidebarView()
                    // The catalog's titles outgrew the original 210 ideal —
                    // give the library room to read at its default width.
                    .frame(minWidth: 170, idealWidth: 235, maxWidth: 300,
                           maxHeight: .infinity)
                // Split views measure children with unspecified proposals, so
                // a child with a wide ideal (the code editor's longest line)
                // can win the pane width and overflow-centre past both edges.
                // Pin every pane to the measured column width instead — but
                // measure it in a *background* GeometryReader, never by wrapping
                // the panes in one: a GeometryReader sinks the toolbar's top
                // safe-area inset on macOS 26's floating glass toolbar, dropping
                // ScriptPane's first row (the run-mode banner) underneath the
                // toolbar. As a direct child the VSplitView insets normally.
                Group {
                    if model.phase == .report {
                        // The report phase runs no script: its workbench is the
                        // findings matrix + the generated narrative.
                        ReportPane()
                            .frame(width: workbenchWidth > 0 ? workbenchWidth : nil)
                            .frame(minHeight: 240, maxHeight: .infinity)
                    } else {
                        VSplitView {
                            ScriptPane()
                                .frame(width: workbenchWidth > 0 ? workbenchWidth : nil)
                                .frame(minHeight: 240, maxHeight: .infinity)
                            ResultsPane()
                                .frame(width: workbenchWidth > 0 ? workbenchWidth : nil)
                                .frame(minHeight: 160, maxHeight: .infinity)
                            ConsolePane()
                                .frame(width: workbenchWidth > 0 ? workbenchWidth : nil)
                                .frame(minHeight: 80, idealHeight: 120, maxHeight: 240)
                        }
                    }
                }
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    GeometryReader { geo in
                        Color.clear
                            .onChange(of: geo.size.width, initial: true) { _, width in
                                workbenchWidth = width
                            }
                    }
                }
                .layoutPriority(1)
                // The detail pane holds the diffs — the actual work under
                // review — so it may open out wide at the workbench's expense.
                DetailPane()
                    .frame(minWidth: 320, idealWidth: 460, maxWidth: 760,
                           maxHeight: .infinity)
            }
            // HSplitView is not greedy — without this it collapses to its
            // children's minimum height inside the VStack.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("ReportGitHub")
            .toolbar {
                // The workflow's spine, centred in the title bar.
                ToolbarItem(placement: .principal) {
                    PhaseFlowControl()
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    // The report phase's primary action (Generate) lives in the
                    // Report pane header next to the matrix it acts on — the
                    // toolbar carries only the script controls (Find phase).
                    if model.phase != .report {
                    Button {
                        Task { await model.validate() }
                    } label: {
                        Label("Check", systemImage: "checkmark.shield")
                    }
                    .help("Lint and type-check the script against the host API")
                    .disabled(model.running || model.validating || model.generating)

                    if model.running {
                        Button {
                            model.cancel()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                                .foregroundStyle(.red)
                                .labelStyle(.titleAndIcon)
                        }
                        .help("Cancel the run — pending operations are abandoned")
                    } else {
                        // Run is always read-only — the find phase only reads.
                        Button {
                            model.run()
                        } label: {
                            Label("Run", systemImage: "play.fill")
                        }
                        .help("Validate and run the script (the find phase is read-only)")
                        // Generation streams into the editor, so running
                        // mid-generation would execute a truncated script.
                        .disabled(model.scriptText.isEmpty || model.validating || model.generating)
                    }
                    } // end (non-report phases)
                }
            }

            EnvironmentFooter()
        }
        .alert("Start a new job?", isPresented: $model.showNewJobConfirmation) {
            Button("Discard and Start New Job", role: .destructive) {
                model.startNewJob()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This discards the whole job — prompts, scripts, findings, the report, and the audit trail, in every phase. Settings and credentials are kept.")
        }
        .alert("Save script as recipe", isPresented: $model.showSaveRecipePrompt) {
            TextField("Recipe name", text: $model.recipeNameDraft)
            Button("Save") { model.saveCurrentAsRecipe() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the prompt, script, and phase to your recipe library (Application Support). Results and plans are not part of a recipe.")
        }
        .alert("Rename recipe", isPresented: renamingPresented, presenting: model.renamingRecipe) { recipe in
            TextField("Recipe name", text: $model.recipeNameDraft)
            Button("Rename") { model.renameRecipe(recipe) }
            Button("Cancel", role: .cancel) {}
        } message: { recipe in
            Text("Rename \"\(recipe.title)\".")
        }
        .alert("Delete recipe?", isPresented: deletingPresented, presenting: model.deletingRecipe) { recipe in
            Button("Delete \"\(recipe.title)\"", role: .destructive) {
                model.deleteRecipe(recipe)
            }
            Button("Cancel", role: .cancel) {}
        } message: { recipe in
            Text("\"\(recipe.title)\" is removed from your library. Scripts in the editor are not affected.")
        }
        .onChange(of: model.settings.useFixtureGitHub) {
            model.dataSourceChanged()
        }
    }

    private var renamingPresented: Binding<Bool> {
        Binding(
            get: { model.renamingRecipe != nil },
            set: { if !$0 { model.renamingRecipe = nil } }
        )
    }

    private var deletingPresented: Binding<Bool> {
        Binding(
            get: { model.deletingRecipe != nil },
            set: { if !$0 { model.deletingRecipe = nil } }
        )
    }
}

/// The workflow's spine in the title bar: Find ▸ Report at standard toolbar
/// metrics. Chevron separators carry the direction (the path-control idiom);
/// only the ACTIVE stage wears a tinted capsule — bold colour belongs in
/// content, not chrome. Each stage carries its product count.
struct PhaseFlowControl: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Phase switching is locked while a run or generation is in flight —
        // swapping workspaces mid-action invites confusion (the run keeps
        // writing into the phase it started in).
        let busy = model.running || model.generating || model.generatingReport
        HStack(spacing: 4) {
            stage(.check, label: "Find", systemImage: "magnifyingglass",
                  badge: model.matchedCount,
                  help: "Describe what to find and which parameters to extract; the read-only script's verified findings feed the report")
            chevron
            stage(.report, label: "Report", systemImage: "doc.text.magnifyingglass",
                  badge: 0,
                  help: "Aggregate the findings into a report — similarities, differences, and outliers")
        }
        // The principal toolbar slot compresses its item once the badges
        // appear, truncating the active stage's label — refuse compression;
        // the title bar has the room.
        .fixedSize()
        .disabled(busy)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    private func color(for phase: JobPhase) -> Color {
        switch phase {
        case .check: return .blue
        case .report: return .teal
        }
    }

    private func stage(_ phase: JobPhase, label: String, systemImage: String,
                       badge: Int, help: String) -> some View {
        let isCurrent = model.phase == phase
        let tint = color(for: phase)
        return Button {
            model.setPhase(phase)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.subheadline)
                Text(label)
                    .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.weight(.semibold))
                        // Refuse truncation: the principal toolbar slot squeezes
                        // its item, and without this the count renders as "2…".
                        .fixedSize()
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background((isCurrent ? tint : Color.secondary).opacity(0.16),
                                    in: Capsule())
                        .foregroundStyle(isCurrent ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(isCurrent ? AnyShapeStyle(tint.opacity(0.16)) : AnyShapeStyle(.clear),
                        in: Capsule())
            .overlay(
                Capsule().strokeBorder(tint.opacity(isCurrent ? 0.6 : 0), lineWidth: 1)
            )
            .foregroundStyle(isCurrent ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    /// Recipe groups are collapsible; open by default for discoverability.
    @State private var expandedGroups: Set<JobPhase> = Set(JobPhase.allCases)

    var body: some View {
        let busy = model.running || model.generating
        List {
            // The recipe LIBRARY is reference material, not navigation: it
            // lives under its own header, one collapsible group per phase,
            // with quieter styling so it doesn't compete with the workflow.
            // Bundled and user-saved recipes share the groups — a recipe is
            // a recipe; only rename/delete (context menu) is saved-only.
            Section("Recipe library") {
                if model.recipes.isEmpty && model.recipesLoading {
                    Label("Loading recipes…", systemImage: "hourglass")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                // ReportGitHub surfaces the read-only Find recipes; the dormant
                // update/merge recipes stay out of the library.
                ForEach([JobPhase.check, .report], id: \.self) { phase in
                    let bundled = model.recipes.filter { $0.phase == phase && $0.origin == .bundled }
                    let saved = model.userRecipes.filter { $0.phase == phase }
                    if !bundled.isEmpty || !saved.isEmpty {
                        DisclosureGroup(isExpanded: expansionBinding(for: phase)) {
                            ForEach(bundled) { recipe in
                                Button {
                                    model.loadRecipe(recipe)
                                } label: {
                                    Label(recipe.title, systemImage: recipe.systemImage)
                                        .font(.callout)
                                }
                                .buttonStyle(.plain)
                                .disabled(busy)
                                .selectionDisabled()
                                .help(recipe.prompt)
                                .contextMenu {
                                    Button("Export…") { exportRecipeViaPanel(recipe, model) }
                                }
                            }
                            ForEach(saved) { recipe in
                                Button {
                                    model.loadRecipe(recipe)
                                } label: {
                                    Label(recipe.title, systemImage: "bookmark")
                                        .font(.callout)
                                }
                                .buttonStyle(.plain)
                                .disabled(busy)
                                .selectionDisabled()
                                .help(recipe.prompt)
                                .contextMenu {
                                    Button("Rename…") {
                                        model.recipeNameDraft = recipe.title
                                        model.renamingRecipe = recipe
                                    }
                                    Button("Export…") { exportRecipeViaPanel(recipe, model) }
                                    Divider()
                                    Button("Delete…", role: .destructive) {
                                        model.deletingRecipe = recipe
                                    }
                                }
                            }
                        } label: {
                            Text(phase.displayName)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .selectionDisabled()
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func expansionBinding(for phase: JobPhase) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(phase) },
            set: { isOpen in
                if isOpen { expandedGroups.insert(phase) } else { expandedGroups.remove(phase) }
            }
        )
    }

}

/// Ambient environment status — deliberately out of the sidebar so it doesn't
/// compete with the workflow; lives in a quiet footer across the window.
struct EnvironmentFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            Label("org \(model.settings.organisation)", systemImage: "building.2")
            Label(model.settings.useFixtureGitHub ? "Fixture data" : "Live GitHub",
                  systemImage: model.settings.useFixtureGitHub ? "shippingbox" : "network")
            Label(model.settings.useMockLLM ? "Mock LLM" : "Anthropic",
                  systemImage: model.settings.useMockLLM ? "cpu" : "sparkles")
            Label(model.typeCheckerLabel,
                  systemImage: model.typeCheckingAvailable ? "checkmark.seal" : "xmark.seal")
            if let quota = model.quotaText {
                Label(quota, systemImage: "gauge.with.needle")
                    .help("GitHub API quota remaining")
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
