import SwiftUI
import AnalyzersKit
import UIComponents

/// One topic as a small lesson, written with this Mac's numbers: what the thing is, why it matters on this Mac, what it
/// never does, the named actions that open the screen it explains (each row deep-links to the exact screen or tab), and
/// one common question answered — with where it is written down at the foot.
struct TopicScreen: View {
    let topic: HowItWorksTopic
    @Environment(Navigator.self) private var navigator
    private var model: HowItWorksModel { .shared }

    var body: some View {
        DataScreen(title: topic.title, subtitle: topic.tab.title) {
            if let facts = model.facts {
                form(topic.content(facts))
            } else {
                LoadingState("Reading this Mac…")
            }
        }
        .task { await model.load() }
    }

    private func form(_ content: TopicContent) -> some View {
        Form {
            if content.what != nil || !content.does.isEmpty {
                Section(Names.HowItWorks.whatItDoes) {
                    if let what = content.what {
                        Text(what).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    ForEach(content.does, id: \.self) { paragraph in
                        Text(paragraph)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            if !content.onThisMac.isEmpty {
                Section(Names.HowItWorks.whyItMatters) {
                    ForEach(content.onThisMac, id: \.self) { paragraph in
                        Text(paragraph)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            if !content.never.isEmpty { section(Names.HowItWorks.whatItNeverDoes, content.never) }
            if !content.actions.isEmpty {
                Section(Names.HowItWorks.whatYouCanDo) {
                    ForEach(content.actions) { action in
                        row(action)
                    }
                }
            }
            if let question = content.question {
                Section(Names.HowItWorks.commonQuestion) {
                    Text(question.ask).font(Tokens.Typography.rowTitleKey).textSelection(.enabled)
                    Text(question.answer)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            if !content.written.isEmpty { section(Names.HowItWorks.whereItIsWritten, content.written) }
            if topic == .healthReport {
                Section {
                    Button(Names.HowItWorks.export) { HealthReport.save() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// A named action: what it is called, what waits where it leads, and the chevron — the same shape as a topic row.
    private func row(_ action: TopicContent.Action) -> some View {
        Button { navigator.open(target: action.target) } label: {
            HStack {
                VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                    Text(action.title).font(Tokens.Typography.rowTitleKey)
                    Text(action.detail)
                        .font(Tokens.Typography.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Tokens.Space.xl)
                Image(systemName: "arrow.up.forward.square")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func section(_ title: String, _ paragraphs: [String]) -> some View {
        Section(title) {
            ForEach(paragraphs, id: \.self) { paragraph in
                Text(paragraph)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}
