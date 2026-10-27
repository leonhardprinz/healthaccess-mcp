import SwiftUI

/// The Settings tab: the same header as Export and Plans, then Access · What gets exported · Privacy · About.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showPicker = false

    var body: some View {
        @Bindable var settings = model.settings
        List {
            Section {
                EmptyView()
            } header: {
                TabHeader(title: "Settings", line: "Folders, permissions and privacy.")
            }

            Section {
                Button { showPicker = true } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        row("Health data", model.folder?.displayNameWithProvider ?? "None yet")
                        Text("Your finished workouts and days are written here. Tap to change.").font(.footnote).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let result = model.results["folder"] { ResultLine(result: result, undoKey: "folder") }
                Button { model.openInFiles(subfolder: "plans") } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        row("Workout plans", model.folder.map { "\($0.displayName) / plans" } ?? "None yet")
                        Text("Your AI writes workout plans here, inside the Health data folder.").font(.footnote).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.folder == nil)
                Button { Task { await healthTapped() } } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        row("Health access", healthText)
                        if model.healthStatus == .requested {
                            Text("Change in Health → Sharing → Apps → Health Access.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { Task { await notificationsTapped() } } label: {
                    row("Notifications", notificationsText).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                SectionTitle("Access")
            } footer: {
                Text("Read only. Health Access never writes to Health.")
            }

            Section {
                Toggle(isOn: Binding(get: { settings.includeReproductive }, set: { model.setIncludeReproductive($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reproductive health")
                        Text("Cycle, pregnancy, lactation, tests.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: Binding(get: { settings.includeECGVoltage }, set: { model.setIncludeECGVoltage($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ECG voltage")
                        Text("The raw ECG trace. Large files.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: {
                SectionTitle("What gets exported")
            } footer: {
                Text("Everything else with data is exported: \(HealthTypes.all.count) Health types.")
            }

            Section {
                NavigationLink { WhatLeftView() } label: {
                    row("What left this phone", NetworkLedger.shared.entries.isEmpty ? "Nothing" : "\(NetworkLedger.shared.entries.count) events")
                }
                Toggle(isOn: Binding(get: { settings.usageStatisticsEnabled }, set: { model.requestUsageStatistics($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Usage statistics")
                        Text(model.usageStatisticsAvailable
                             ? "Which features you use. Never health data."
                             : "Not available in this build.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .disabled(!model.usageStatisticsAvailable)
                NavigationLink { SyncLogView() } label: {
                    row("Sync log", settings.lastObserverFire.map { "Last wake \(Format.clock($0))" } ?? "No wake yet")
                }
            } header: {
                SectionTitle("Privacy")
            } footer: {
                Text("No account, no server. Your data stays in your folder.")
            }

            Section {
                LabeledContent("Version", value: "\(HealthAccessJSON.appVersion) (\(HealthAccessJSON.appBuild))")
                if let url = URL(string: SetupMessage.siteURL) {
                    Link(destination: url) { row("Docs", "healthaccessmcp.com") }
                }
                if let url = URL(string: SetupMessage.supportURL) {
                    Link(destination: url) { row("Support", "support@healthaccessmcp.com") }
                }
                if let url = URL(string: SetupMessage.privacyURL) {
                    Link(destination: url) { row("Privacy policy", "") }
                }
                Button("Restore purchases") { Task { await model.restoreSupport() } }
                if let result = model.results["restore"] { ResultLine(result: result, undoKey: "restore") }
            } header: {
                SectionTitle("About")
            } footer: {
                Text("Free and open source, by Prinz Tech Consulting.")
            }
        }
        .listStyle(.insetGrouped)
        .brandGround()
        .toolbar(.hidden, for: .navigationBar)
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.requestFolder(url) }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.primary)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing).font(.subheadline)
        }
    }

    private var healthText: String {
        switch model.healthStatus {
        case .unavailable: return "not available"
        case .notRequested: return "not requested"
        case .requested: return "Managed in Health"
        }
    }

    private var notificationsText: String {
        switch model.notificationStatus {
        case .authorized, .provisional, .ephemeral: return "On"
        case .denied: return "Off"
        default: return "not requested"
        }
    }

    /// iOS does not expose read grants; after the first request the row opens the Health app, where they are managed.
    private func healthTapped() async {
        if model.healthStatus == .notRequested {
            await model.requestHealthAccess()
        } else if let url = URL(string: "x-apple-health://") {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    private func notificationsTapped() async {
        if model.notificationStatus == .notDetermined {
            await model.requestNotifications()
        } else {
            openSystemSettings()
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

/// A real screen. Lists every outgoing network call this session; empty unless usage statistics are on.
struct WhatLeftView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let entries = NetworkLedger.shared.entries
        List {
            if entries.isEmpty {
                Section {
                    Text(model.settings.usageStatisticsEnabled
                         ? "Nothing yet this session. With usage statistics on, event names go to \(model.usageStatisticsHost) as they happen."
                         : "Nothing. Health Access has no server.")
                } footer: {
                    Text("Your health data goes only into the folder you picked. The folder's own sync (iCloud Drive, Dropbox and so on) is the provider's, not this app's.")
                }
            } else {
                Section {
                    ForEach(entries.reversed()) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.event).font(.body.monospaced())
                                Text(entry.host).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Format.clock(entry.at)).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("This session")
                } footer: {
                    Text("Event names with counts, durations and the app and iOS versions, sent in batches by the PostHog SDK under a random install id. No health values, file names or folder paths.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("What left this phone")
        .navigationBarTitleDisplayMode(.inline)
    }
}
