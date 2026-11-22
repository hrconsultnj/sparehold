import AnalyzersKit
import SwiftUI

/// One numbered section of a report, pushed from the reader's contents rows.
/// The Sections menu and the `reports:section:<n>` link land here too. The
/// report file is read again — the same read, the same split into sections the
/// reader did — so the screen stands on its own (a restored window, a link).
struct ReportSectionScreen: View {
    /// The report by its path (a `ReportDocument`'s id).
    let report: String
    /// The section's index in the report (`ReportSection.index`).
    let index: Int

    @State private var section: ReportSection?
    @State private var total = 0
    @State private var loaded = false

    var body: some View {
        Group {
            if let section {
                ReportBlocksView(blocks: section.blocks)
            } else if loaded {
                EmptyState(Names.Report.sectionGone, systemImage: "doc.text.magnifyingglass",
                           description: Text("The report on disk has changed since this section was opened. Reopen it from Reports."))
            } else {
                LoadingState()
            }
        }
        .navigationTitle(section?.title ?? Names.Screen.reports)
        .navigationSubtitle(total > 0 ? Names.Report.section(index, of: total) : "")
        .task { await load() }
    }

    /// The same read ReportsModel does for the reader, one section of it.
    private func load() async {
        let url = URL(fileURLWithPath: report)
        let parsed = await Task.detached(priority: .userInitiated) {
            ReportSection.split((try? String(contentsOf: url, encoding: .utf8)).map(ReportMarkdown.blocks(from:)) ?? [])
        }.value
        total = parsed.sections.count
        section = parsed.sections.first { $0.index == index }
        loaded = true
    }
}
