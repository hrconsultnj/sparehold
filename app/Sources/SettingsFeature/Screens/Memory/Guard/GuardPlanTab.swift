import AppKit
import SwiftUI
import AnalyzersKit
import UIComponents

/// When Memory Runs Out: the plan in one sentence, its steps in the order they are tried (each with what it would pick right
/// now), what nothing may touch right now, and the two lists the person keeps.
struct GuardPlanTab: View {
    let model: GuardRulesModel
    /// The list whose Add sheet is open.
    @State private var adding: Names.GuardList?

    var body: some View {
        DataScreen(title: Names.Screen.memoryGuard, subtitle: subtitle) {
            Form {
                Section {
                    Text(GuardRule.ladderSentence(model.rules.steps.filter { $0.state != .off }.map(\.rule)))
                    Text(GuardPlanPreview.watchingNote)
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let notice = model.notice { Section { Label(notice, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
                Section(Names.Guard.steps) {
                    ForEach(model.rules.steps) { step in stepRow(step) }
                }
                Section {
                    ForEach(protectedNow, id: \.name) { item in
                        LabeledContent { Text(item.why).foregroundStyle(.secondary) } label: { Label(item.name, systemImage: item.symbol) }
                    }
                    if protectedNow.isEmpty { Text("Nothing running is protected by name right now.").foregroundStyle(.secondary) }
                } header: { Text(Names.Guard.protectedNow) } footer: {
                    Text("What a live coding session started, a Connection Tool, the app in front and what you listed below is never stopped, whatever a rule says.")
                }
                list(.mayQuit, Names.Guard.mayQuitList, "Apps you list here may be asked to quit, as ⌘Q does, only when memory has run out. None is listed.")
                list(.neverClose, Names.Guard.neverCloseList, "Memory Guard and the cleanups that sweep developer tools and leftover helpers never touch what is listed here: a name of an app or program, or the full path of a program. Quitting apps by name in Memory Cleanup is your own choice and is not checked against this list.")
            }
            .formStyle(.grouped)
        }
        .helpTopic(.guardSteps, screen: Names.Screen.memoryGuard)
        .appPicker(isPresented: Binding(get: { adding != nil }, set: { if !$0 { adding = nil } }),
                   mode: adding == .neverClose ? .processFragments : .installedApps,
                   existing: adding.map(entries) ?? []) { name in
            if let kind = adding, !entries(kind).contains(name) { model.add(kind, name) }
        }
        .toolbar {
            ToolbarItem {
                Button(Names.Monitor.refresh, systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .help("Look at what is running again")
            }
        }
    }

    private var subtitle: String {
        if model.loading && model.look == nil { return "Looking at what is running…" }
        let pressure = LiveStats.memoryPressure().label
        return "Memory pressure: \(pressure)"
    }

    private func stepRow(_ step: ResolvedRule) -> some View {
        let pick = model.evaluation?.picks.first { $0.rule.id == step.id }
        let counts = model.counts(rule: step.id)
        return LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Text(step.state.title).font(.caption.weight(.semibold)).foregroundStyle(color(step.state))
                if counts.would + counts.kept > 0 {
                    Text("Would have acted \(counts.would) \(counts.would == 1 ? "time" : "times") this week").font(.caption).foregroundStyle(.secondary)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(step.rule.summary)
                Text(wouldPick(pick, step)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            if step.state != .acting {
                Button(step.state == .off ? "Turn On" : "Turn Off") { model.setOff(step.id, step.state != .off) }
            }
        }
    }

    private func wouldPick(_ pick: StepPick?, _ step: ResolvedRule) -> String { GuardPlanPreview.wouldPick(pick, step) }

    private func color(_ state: RuleState) -> Color {
        switch state {
        case .acting: .green
        case .watching: .blue
        case .off: .secondary
        case .cantRun: .orange
        }
    }

    /// What nothing may touch right now, from what is running (the same reading the Welcome flow's Memory Guard step uses).
    private var protectedNow: [(name: String, why: String, symbol: String)] {
        GuardPlanPreview.protectedNow(rules: model.rules, groups: model.groups, front: NSWorkspace.shared.frontmostApplication?.localizedName)
            .map { ($0.name, $0.why, $0.symbol) }
    }

    private func entries(_ kind: Names.GuardList) -> [String] {
        kind == .mayQuit ? model.rules.local.mayQuit : model.rules.local.neverClose
    }

    @ViewBuilder private func list(_ kind: Names.GuardList, _ title: String, _ footer: String) -> some View {
        Section {
            ForEach(entries(kind), id: \.self) { name in
                LabeledContent {
                    Button("Remove", systemImage: "minus.circle") { model.remove(kind, name) }.labelStyle(.iconOnly).buttonStyle(.borderless)
                        .help("Remove \(name) from this list")
                } label: {
                    AppNameLabel(name: name, mode: kind == .mayQuit ? .installedApps : .processFragments)
                }
            }
            Button("Add…", systemImage: "plus") { adding = kind }
                .help(kind == .mayQuit ? "Choose an installed app" : "Choose a running program or app, or type a name or path")
        } header: { Text(title) } footer: { Text(footer) }
    }
}
