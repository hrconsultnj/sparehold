import SwiftUI
import AnalyzersKit
import UIComponents

/// Storage pane: auto-clean scope lists. Where Old Recordings looks is set in its Sources window.
struct StorageSettingsView: View {
    @Environment(ConfigStore.self) private var config
    @Environment(Navigator.self) private var navigator
    @State private var backups: [IOSBackup]?

    /// "3 on · 1 needs access", read the way the Sources window reads them (nothing guarded is looked at).
    private var recordingsSummary: String {
        let legacy = config.storage.recordingSourcesConfigured || config.storage.recordingsDir.isEmpty
            ? [] : [RecordingSourceEntry(id: RecordingSource.customID, enabled: true, path: config.storage.recordingsDir)]
        let saved = config.storage.recordingSources + legacy
        // only what is saved counts: a source that was found but never chosen is not looked through
        let keys = Set(saved.map(\.key))
        return RecordingSourcesStore.summary(RecordingDiscovery.discover(readers: .live(), saved: saved).filter { keys.contains($0.id) })
    }

    var body: some View {
        @Bindable var config = config
        PaneScaffold(symbol: "internaldrive.fill", color: .indigo, title: Names.Screen.storageSettings,
                     caption: "What the scheduled cleans may touch — build output and caches only, all of it regenerable. The Downloads janitor is separate: it moves old files to the Trash, after you review them, and you can undo it.") {
            cachesSection($config)
            toolCachesSection($config)
            codeProjectsSection($config)
            worktreesSection($config)
            appsSection($config)
            downloadsSection($config)
            backupsSection
            saveSection
        }
        .task {
            guard backups == nil else { return }
            let found = await Task.detached(priority: .utility) { IOSBackups.scan() }.value
            backups = found
        }
    }

    // MARK: - sections

    /// Where the cleans look for build caches beyond the ones they know.
    private func cachesSection(_ config: Bindable<ConfigStore>) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                StringListEditor(
                    title: "Extra Cache Folders",
                    prompt: "e.g. ~/.someapp/cache/.next-*",
                    items: config.storage.extraCacheGlobs
                )
                caption("Folders matching these patterns are cleaned when they have been idle for more than 7 days, on top of the caches the app already knows.")
            }
        } header: {
            Text("Build Caches")
        }
    }

    private func toolCachesSection(_ config: Bindable<ConfigStore>) -> some View {
        Section {
            ForEach(ToolCache.allCases) { tool in
                Toggle(isOn: toolBinding(tool, in: config.storage.toolCaches)) {
                    VStack(alignment: .leading, spacing: Tokens.Space.hair) {
                        Text(tool.title)
                        caption(tool.detail)
                    }
                }
            }
        } header: {
            Text("Tool Caches (Expansion Pack)")
        } footer: {
            caption("Opt-in per tool. Everything here is redownloadable or rebuildable cache — sources and state are never in scope. Sizes show every time you preview; cleaning happens when you apply.")
        }
    }

    private func codeProjectsSection(_ config: Bindable<ConfigStore>) -> some View {
        let days = config.wrappedValue.storage.nmAgeDays
        return Section {
            LabeledContent {
                Stepper("\(days) \(days == 1 ? "day" : "days")", value: config.storage.nmAgeDays, in: 1...60)
            } label: {
                VStack(alignment: .leading, spacing: Tokens.Space.hair) {
                    Text("Remove node_modules When Idle")
                    caption("A repo counts as idle when none of its source files changed — build output doesn't count. Reinstall with your package manager.")
                }
            }
            Toggle(isOn: config.storage.nmRequireClean) {
                VStack(alignment: .leading, spacing: Tokens.Space.hair) {
                    Text("Only When the Git Tree Is Clean")
                    caption("Off: idle repos lose node_modules even with uncommitted changes — your source files are never touched either way.")
                }
            }
            LabeledContent {
                Stepper("\(config.wrappedValue.storage.turboCacheMaxGB) GB in total",
                        value: config.storage.turboCacheMaxGB, in: 1...50)
            } label: {
                VStack(alignment: .leading, spacing: Tokens.Space.hair) {
                    Text("Turborepo Cache Cap")
                    caption("Each build adds an entry; the oldest beyond the cap are removed on every run, even in active repos. Never while turbo is running.")
                }
            }
        } header: {
            Text("Code Projects")
        }
    }

    private func worktreesSection(_ config: Bindable<ConfigStore>) -> some View {
        let days = config.wrappedValue.storage.worktreeIdleDays
        return Section {
            LabeledContent {
                Stepper(days == 0 ? "Off" : "\(days) \(days == 1 ? "day" : "days")",
                        value: config.storage.worktreeIdleDays, in: 0...60)
            } label: {
                VStack(alignment: .leading, spacing: Tokens.Space.hair) {
                    Text(days == 0
                         ? "Idle worktrees: off"
                         : "Clear build output of worktrees idle \(days) \(days == 1 ? "day" : "days")")
                    caption("Only build output that git ignores (node_modules, .next, dist and the like) is removed. The worktree itself, its source files and its local files such as an .env always stay. A worktree with uncommitted changes, any folder under .composure/workspaces, main, a locked worktree and one a terminal or agent session is using are never touched. Deep clean only.")
                }
            }
        } header: {
            Text("Git Worktrees")
        }
    }

    private func appsSection(_ config: Bindable<ConfigStore>) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                AppListEditor(
                    title: "Stale Apps",
                    mode: .installedApps,
                    items: config.storage.staleApps,
                    height: 140
                )
                caption("Apps the cleanup offers to remove, per app, when you have not opened them in a while.")
            }
            LabeledContent {
                // the one editor is Old Recordings' Sources window; this says what it holds and opens it
                HStack {
                    Text(recordingsSummary).foregroundStyle(.secondary)
                    Button(Names.Recordings.sourcesButton) { navigator.open(target: "recordings:sources") }
                }
            } label: {
                VStack(alignment: .leading, spacing: Tokens.Space.hair) {
                    Text("Recordings")
                    caption("Where Old Recordings looks for what your recording apps saved.")
                }
            }
        } header: {
            Text("Apps and Recordings")
        }
    }

    // The janitor is the ONE cleaner that touches documents rather than rebuildable caches, and its settings were
    // reachable only by hand-editing a shell file — so the pane's promise that keep patterns are honoured had no
    // way to be acted on.
    private func downloadsSection(_ config: Bindable<ConfigStore>) -> some View {
        Section {
            LabeledContent {
                Stepper("\(config.wrappedValue.storage.janitorDownloadsDays) days",
                        value: config.storage.janitorDownloadsDays, in: 1...365)
            } label: {
                VStack(alignment: .leading, spacing: Tokens.Space.hair) {
                    Text("Downloads Older Than")
                    caption("Counted from when you last opened or changed the file, not when you downloaded it.")
                }
            }
            LabeledContent {
                Stepper("\(config.wrappedValue.storage.janitorScreenshotsDays) days",
                        value: config.storage.janitorScreenshotsDays, in: 1...365)
            } label: {
                VStack(alignment: .leading, spacing: Tokens.Space.hair) {
                    Text("Screenshots Older Than")
                    caption("Only files in your Screenshots folder. Folders are never moved.")
                }
            }
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                StringListEditor(
                    title: "Never Touch",
                    prompt: "e.g. *.dmg  or  Tax *",
                    items: config.storage.janitorKeepPatterns
                )
                caption("Anything whose name matches one of these is left where it is.")
            }
        } header: {
            Text(Names.Screen.downloads)
        } footer: {
            caption("These move to the Trash, so you can always put them back — from the Undo screen or from Finder. Nothing moves until you review it and apply.")
        }
    }

    private var backupsSection: some View {
        Section {
            if let backups {
                if backups.isEmpty {
                    Text("No local iPhone/iPad backups on this Mac.")
                        .foregroundStyle(.secondary)
                }
                ForEach(backups) { backup in
                    HStack {
                        DataCard(symbol: "iphone", color: .blue,
                                 title: backup.deviceName,
                                 subtitle: backup.lastBackup.map {
                                     "Last backup \($0.formatted(.dateTime.month(.abbreviated).day().year()))"
                                 } ?? "Backup date unknown",
                                 trailing: ByteSize.format(backup.sizeBytes))
                        Button("Show in Finder") { IOSBackups.revealInFinder(backup) }
                    }
                }
            } else {
                HStack(spacing: Tokens.Space.m) {
                    ProgressView().controlSize(.small)
                    Text("Sizing local device backups…")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("iPhone and iPad Backups on This Mac")
        } footer: {
            caption("Report only — deleting a backup is always your manual call, in Finder.")
        }
    }

    private var saveSection: some View {
        Section {
            SaveBar { try config.save() }
            caption("Applies on the next scheduled run — daily: \(ScheduleKit.describe(GuardControl.storageCleanLabel)); deep: \(ScheduleKit.describe(GuardControl.storageDeepLabel)).")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func toolBinding(_ tool: ToolCache, in list: Binding<[String]>) -> Binding<Bool> {
        Binding(get: { list.wrappedValue.contains(tool.rawValue) },
                set: { enabled in
                    if enabled {
                        if !list.wrappedValue.contains(tool.rawValue) {
                            list.wrappedValue.append(tool.rawValue)
                        }
                    } else {
                        list.wrappedValue.removeAll { $0 == tool.rawValue }
                    }
                })
    }
}
