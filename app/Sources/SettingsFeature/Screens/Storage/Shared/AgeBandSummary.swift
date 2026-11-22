import AnalyzersKit
import SwiftUI

/// The age bands of a whole-range preview (Old Recordings, Time Machine): the
/// folder's true size at a glance, one line per band with its count and size.
/// With a live review session each line carries the band's action — "Select",
/// which ticks exactly that band's rows, so "delete older than 7 days" is the
/// three bands past that line selected and then the review's one Apply. The
/// standing retention setting is never read, never written: the screen's
/// ranges are choices on the data in front of the person. Without a session
/// (a read-only last-known list, or a screen whose apply cannot take a list)
/// the strip only says the sizes, and `note` says why.
struct AgeBandSummary: View {
    /// The rows of the preview on screen (their `band` is what lines up).
    let rows: StorageRows
    /// The live review, when the review on screen can be applied from ticks;
    /// nil makes every band read-only.
    var session: ReviewSession?
    /// What the rows are called ("recordings", "snapshots").
    var noun = "items"
    /// One sentence under the bands; nil is none.
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows.bands) { band in
                line(band)
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .barMargin()
    }

    @ViewBuilder private func line(_ band: AgeBand) -> some View {
        let selectable = session.map { _ in rows.ids(in: band) } ?? []
        HStack {
            Text(band.title)
            Spacer()
            Text(detail(band)).monospacedDigit().foregroundStyle(.secondary)
            if !selectable.isEmpty {
                Button("Select") { session?.setTicked(selectable, true) }
                    .controlSize(.small)
                    .help("Tick this band's rows; Apply still shows the exact list before anything moves")
            }
        }
        .font(.callout)
    }

    /// "5 recordings · 12.3 GB" — the size only when the rows have sizes
    /// (Time Machine's rows do not, and nothing is invented in its place).
    private func detail(_ band: AgeBand) -> String {
        let count = rows.count(in: band)
        let bytes = rows.bytes(in: band)
        var text = "\(count) \(count == 1 ? noun : noun + "s")"
        if bytes > 0 { text += " · \(ByteSize.format(bytes))" }
        return text
    }
}
