import AppKit
import AnalyzersKit
import SwiftUI
import UIComponents

/// Reports: the memory and storage reports the analyzers write, as a reader.
/// The list of reports is on the left, named for when each was written; the
/// selected one is drawn on the right as a document, not as raw text — its
/// front matter, then its sections as contents rows. A section is one level
/// down: the row pushes the section's own screen (`ReportSectionScreen`), the
/// way the Sections menu and the `reports:section:<n>` link do.
///
/// One job per file next to it:
///   ReportsModel.swift        the reports on disk, the open one, the jobs that write new ones
///   ReportList.swift          the left side (the months and their reports)
///   ReportBlocksView.swift    the blocks a document draws, and what a contents row says
///   ReportSectionScreen.swift the pushed screen: one section's blocks
///   (the Markdown as written is the shared RawOutputScreen, opened from the top)
///   ReportFile.swift          what Export hands to the save panel
///
/// The Memory / Storage tabs are the shared bar under the toolbar (`scopeTabsToolbar`). Toolbar:
/// Write Report stays; Past Runs, Stop, Sections, Export and Show Source are
/// `.toolbarRank(.secondary)` and move into the system's overflow first.
struct ReportsView: View {

    @Environment(JobStore.self) private var store
    @Environment(Navigator.self) private var navigator
    @State private var model = ReportsModel()
    @State private var kind: ReportDocument.Kind = .memory
    /// The months that are open, kept across window close and relaunch.
    @State private var monthsOpen = RememberedExpansion<String>(screen: "reports")
    @State private var exporting = false

    private var months: [ReportMonth] { ReportMonth.months(of: model.reports(of: kind)) }

    var body: some View {
        // The left side is a list and the right a document. Not an HSplitView:
        // inside the main window's detail column it took the sum of its panes'
        // ideal widths as its minimum, so at 900 points the sidebar was squeezed
        // and the window's contents ran past its edges (rendered and checked).
        DataScreen(title: Names.Screen.reports, subtitle: subtitle) {
        HStack(spacing: 0) {
            ReportList(months: months, selection: $model.selection, expansion: monthsOpen,
                       onShowInFinder: reveal)
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 380)
            Divider()
            reader
                .frame(minWidth: 280, idealWidth: 480, maxWidth: .infinity)
        }
        }
        .helpTopic(.whereWritten, screen: Names.Screen.reports)
        .scopeTabsToolbar(screen: "reports", items: tabs, selection: $kind)
        .toolbar { toolbar }
        .fileExporter(isPresented: $exporting,
                      document: ReportFile(text: model.selected?.text() ?? ""),
                      contentType: ReportFile.markdown,
                      defaultFilename: model.selected?.url.deletingPathExtension().lastPathComponent ?? "Report") { _ in }
        .task {
            model.adopt(from: store)
            await model.reload()
            // the remembered tab wins; with nothing of that kind (a first launch) show the kind there is
            if months.isEmpty, let newest = model.reports.first { kind = newest.kind }
            // the open report follows the tab: the newest of that kind
            if model.selected?.kind != kind { model.selection = months.first?.reports.first?.id }
            applyPendingLink()
        }
        .onChange(of: kind) {
            if model.selected?.kind != kind { model.selection = months.first?.reports.first?.id }
        }
        // the newest month starts open; never once a person opened or closed one
        .onChange(of: months.first?.id, initial: true) {
            monthsOpen.seedIfUntouched(months.first.map { [ReportList.key($0)] } ?? [])
        }
        // a link opened while Reports is already showing
        .onChange(of: navigator.pendingIntent) { applyPendingLink() }
        // when a report job ends, read what it wrote and show it
        .onChange(of: model.stamps) { old, new in
            for (kind, (before, after)) in zip(ReportDocument.Kind.allCases, zip(old, new))
            where before != after && after.stage == .succeeded {
                Task { await model.reload(selectNewestOf: kind) }
            }
        }
    }

    @ViewBuilder private var reader: some View {
        if let report = model.selected, model.blocksFor == report.id {
            document(report)
        } else if model.selected != nil {
            LoadingState()
        } else {
            EmptyState {
                Label("No Report Selected", systemImage: "doc.text")
            } description: {
                Text(model.loaded ? "Pick a report on the left, or write a new one." : "Looking for reports…")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)   // centred in the window, as the running state is
        }
    }

    /// The open report's front matter, then its sections as contents rows — each
    /// row one level down, pushing the section's own screen.
    private func document(_ report: ReportDocument) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(model.preface.enumerated()), id: \.offset) { _, block in ReportBlocksView.block(block) }
                contents(of: report)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder private func contents(of report: ReportDocument) -> some View {
        if !model.sections.isEmpty {
            Text(Names.Report.contents).font(.title3.bold()).padding(.top, 6)
            ForEach(model.sections) { section in
                Button {
                    navigator.push(.system(.reportSection(report: report.id, index: section.index)))
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title)
                            if let preview = section.preview {
                                Text(preview).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var tabs: [ScopeTabItem<ReportDocument.Kind>] {
        ReportDocument.Kind.allCases.map {
            ScopeTabItem(value: $0, title: $0.tabTitle, symbol: $0.symbol,
                         count: model.loaded ? model.reports(of: $0).count : nil)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(ReportDocument.Kind.allCases, id: \.self) { kind in
                    Button { model.write(kind, in: store) } label: {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                    .help(kind == .memory ? "Takes a few seconds" : "Takes a minute or two on a full disk")
                }
            } label: {
                Label("Write Report", systemImage: "doc.badge.plus")
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.writing != nil)
            .help("Write a new report. Reports only read; nothing is moved, deleted or stopped.")
        }
        .toolbarRank(.primary)

        ToolbarItem(placement: .primaryAction) {
            Button { navigator.open(target: "activity:find:\(Names.job(kind == .memory ? .memoryReport : .storageReport))") } label: {
                Label("Past Runs", systemImage: "clock.arrow.circlepath")
            }
            .labelStyle(.titleAndIcon)
            .help("See every earlier report in Activity")
        }
        .toolbarRank(.secondary)

        ToolbarItem(placement: .primaryAction) {
            Button { model.stop() } label: { Label("Stop", systemImage: "stop.circle") }
                .labelStyle(.titleAndIcon)
                .disabled(model.writing == nil)
                .help("Stop writing the report")
        }
        .toolbarRank(.secondary)

        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(model.sections) { section in
                    Button(section.title) {
                        if let report = model.selected {
                            navigator.push(.system(.reportSection(report: report.id, index: section.index)))
                        }
                    }
                }
            } label: {
                Label(Names.Report.sections, systemImage: "list.number")
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.sections.isEmpty)
            .help("Open a section of this report")
        }
        .toolbarRank(.secondary)

        ToolbarItem(placement: .primaryAction) {
            Button { exporting = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .labelStyle(.titleAndIcon)
                .disabled(model.selected == nil)
                .help("Save a copy of this report")
        }
        .toolbarRank(.secondary)

        ToolbarItem(placement: .primaryAction) {
            Button {
                if let report = model.selected { navigator.push(.overview(.raw(.file(report.url, fromTop: true)))) }
            } label: { Label("Show Source", systemImage: "curlybraces") }
                .labelStyle(.titleAndIcon)
                .disabled(model.selected == nil)
                .help("See the report's text exactly as written")
        }
        .toolbarRank(.secondary)
    }

    private var subtitle: String {
        if let kind = model.writing {
            return "Writing the \(kind == .memory ? "memory" : "storage") report…"
        }
        if let failure = model.failure { return failure }
        let ofKind = model.reports(of: kind)
        guard let newest = ofKind.first else { return model.loaded ? "No reports yet" : "Looking…" }
        // one short fact; the count is on the tab
        return "Newest \(newest.date.formatted(.relative(presentation: .named)))"
    }

    /// A deep link's request: open the nth report, or push its source.
    private func applyPendingLink() {
        guard let payload = navigator.takeIntent(for: HistoryGroup.reports) else { return }
        if payload.hasPrefix("pick:"), let n = Int(payload.dropFirst("pick:".count)) {
            let all = months.flatMap(\.reports)
            if all.indices.contains(n) { model.selection = all[n].id }
        }
        // month:<n> opens the nth month; section:<n> opens the nth section's screen
        if payload.hasPrefix("month:"), let n = Int(payload.dropFirst("month:".count)), months.indices.contains(n) {
            let open = monthsOpen.binding
            open.wrappedValue.insert(ReportList.key(months[n]))
        }
        if payload.hasPrefix("section:"), let n = Int(payload.dropFirst("section:".count)),
           model.sections.indices.contains(n), let report = model.selected {
            navigator.push(.system(.reportSection(report: report.id, index: model.sections[n].index)))
        }
        if payload == "storage" { kind = .storage }
        if payload == "memory" { kind = .memory }
        if payload == "raw", let report = model.selected {
            navigator.push(.overview(.raw(.file(report.url, fromTop: true))))
        }
    }

    private func reveal(_ report: ReportDocument) {
        NSWorkspace.shared.activateFileViewerSelecting([report.url])
    }
}
