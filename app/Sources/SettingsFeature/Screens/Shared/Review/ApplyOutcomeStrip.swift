import AnalyzersKit
import SwiftUI
import UIComponents

/// The one strip a screen shows once its review has sent an apply: while it runs,
/// the step it is on and the way into the job's own Activity screen; when it ends,
/// what became of the reviewed list — moved to the Trash, with Undo one tap away,
/// or removed outright where the cleanup doesn't use the Trash. Reads only the
/// `Job`; the screen that applied owns the job and decides where the strip sits.
struct ApplyOutcomeStrip: View {
    let job: Job?

    @Environment(Navigator.self) private var navigator

    var body: some View {
        Group {
            if let job {
                switch job.state {
                case .queued, .running:
                    HStack(spacing: Tokens.Space.s) {
                        ProgressView().controlSize(.small)
                        Text(job.step.map { "Cleaning… \($0)" } ?? "Cleaning…")
                            .font(Tokens.Typography.rowTitleKey)
                        Spacer()
                        LinkActionButton(title: "Show in Activity") { navigator.push(.job(job.id)) }
                    }
                case .succeeded:
                    HStack(spacing: Tokens.Space.s) {
                        Image(systemName: "checkmark.circle").foregroundStyle(Tokens.Status.safe.tint)
                        Text(doneLine).font(Tokens.Typography.rowTitleKey)
                        Spacer()
                        if goesToTrash {
                            Button(Names.Screen.undo) { navigator.open(target: "undo") }
                                .help(Names.Undo.explains)
                        }
                        LinkActionButton(title: "Show in Activity") { navigator.push(.job(job.id)) }
                    }
                case .failed(let failure):
                    HStack(spacing: Tokens.Space.s) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Tokens.Status.destructive.tint)
                        Text("Couldn't finish: \(failure.message)").font(Tokens.Typography.rowTitleKey)
                        Spacer()
                        LinkActionButton(title: "Show in Activity") { navigator.push(.job(job.id)) }
                    }
                case .cancelled:
                    HStack(spacing: Tokens.Space.s) {
                        Image(systemName: "stop.circle").foregroundStyle(.secondary)
                        Text("Stopped — what ran before the stop stays done.").font(Tokens.Typography.rowTitleKey)
                        Spacer()
                        LinkActionButton(title: "Show in Activity") { navigator.push(.job(job.id)) }
                    }
                }
            }
        }
        .barMargin()
    }

    // MARK: - the words, from the apply's own kind and options

    /// Whether this apply put what it reviewed in the Trash (and so has an Undo).
    private var goesToTrash: Bool {
        guard let job else { return false }
        return switch job.kind {
        case .janitor, .unusedApps, .recordings: true
        case .tempClean: !job.request.options.permanent
        default: false
        }
    }

    /// "Done — 12 items moved to the Trash." The count is what the review sent;
    /// a cleanup that takes no list (Time Machine's snapshots) has none to name.
    private var doneLine: String {
        guard let job else { return "Done." }
        let reviewed = job.request.approved?.approved.count
        let what = reviewed.map { $0 == 1 ? "1 item" : "\($0) items" } ?? "the reviewed items"
        return switch job.kind {
        case .janitor, .unusedApps, .recordings:
            "Done — \(what) moved to the Trash."
        case .tempClean where job.request.options.permanent:
            "Done — \(what) deleted."
        case .tempClean:
            "Done — \(what) moved to the Trash."
        case .storageClean:
            "Done — \(what) removed."
        case .tmReclaim:
            "Done — the local snapshots were deleted."
        default:
            "Done."
        }
    }
}

/// The strip's one small button: plain text beside the line it explains.
private struct LinkActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .controlSize(.small)
            .help("Open this job's own screen in Activity")
    }
}
