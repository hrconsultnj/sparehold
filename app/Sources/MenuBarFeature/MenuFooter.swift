import AppKit
import SwiftUI
import AnalyzersKit
import UIComponents

/// The footer shared by every tab, and the small helpers the tabs share.
extension MenuContentView {

    var footer: some View {
        HStack {
            // icon-only with tooltips: the panel's width cannot hold words
            // for three destinations plus the version and Quit
            Button {
                ActivationPolicy.windowOpening()
                openWindow(id: "main")
            } label: {
                Label("Open App", systemImage: "macwindow")
                    .labelStyle(.iconOnly)
            }
            .help("Open the main window")
            Button {
                SettingsOpener.open(target: "ask")
            } label: {
                Label("Ask", systemImage: "sparkles")
                    .labelStyle(.iconOnly)
            }
            .help("Open the agent's Ask screen")
            Button {
                SettingsOpener.open(target: "settings")
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
            .help("Open Settings")
            // the version is always text; an available update is a star that
            // opens Updates — the panel never installs anything itself
            Text(updates.build.shortVersionText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(updates.build.versionText)        // the full version, build metadata included
            if updates.offersInstall {
                Button {
                    SettingsOpener.open(target: "update")
                } label: {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
                .help("An update is available — open Updates to install it")
            }
            Spacer()
            Button {
                GuardControl.restartApp()
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .help("Restart this app only — nothing else is touched")
            Button("Quit") { NSApp.terminate(nil) }
        }
    }

    func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    func runText(_ date: Date?) -> String {
        guard let date else { return "never" }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
