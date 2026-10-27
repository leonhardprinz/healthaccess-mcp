import SwiftUI

/// The Plans tab, in the order every tab uses: header, status tile, Folder, Your AI, Sync, the plans, ideas for your AI.
struct PlansView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [HomeRoute] = []
    @State private var showPicker = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    plansTile
                } header: {
                    TabHeader(title: "Import workout plans", line: "AI-written plans, scheduled on your Watch.")
                }

                Section {
                    FolderRow(subfolder: "plans", pickFolder: { showPicker = true })
                } header: {
                    SectionTitle("Folder")
                } footer: {
                    Text("Your AI writes workout plans here. Health Access reads them.")
                }

                Section {
                    ConnectRow()
                } header: {
                    SectionTitle("Your AI")
                }

                Section {
                    Toggle(isOn: Binding(get: { model.settings.autoPutOnWatch }, set: { model.requestAutoPutOnWatch($0) })) {
                        InfoRow(symbol: "applewatch", tint: .accentColor,
                                title: "Automatic",
                                line: model.settings.autoPutOnWatch
                                    ? "New plans go on your Watch at their time."
                                    : "Off. You tap Put on Watch for each plan.")
                    }
                    if let result = model.results["auto"] { ResultLine(result: result, undoKey: "auto") }
                } header: {
                    SectionTitle("Sync to Watch")
                } footer: {
                    Text("Automatic runs when the app opens or iOS wakes it, within hours. Pull down to check now.")
                }

                let waiting = model.needsYou
                let onWatch = model.plansOnWatch
                let earlier = model.plansEarlier
                if !waiting.isEmpty {
                    Section {
                        ForEach(waiting) { PlanRow(item: $0) }
                    } header: {
                        SectionTitle("Waiting for you")
                    }
                }
                if !onWatch.isEmpty {
                    Section {
                        ForEach(onWatch) { ScheduledPlanRow(item: $0) }
                    } header: {
                        SectionTitle("On your Watch")
                    }
                }
                if !earlier.isEmpty {
                    Section {
                        ForEach(earlier) { ScheduledPlanRow(item: $0) }
                    } header: {
                        SectionTitle("Earlier")
                    }
                }
                let invalid = model.plansInvalid
                if !invalid.isEmpty {
                    Section {
                        ForEach(invalid) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.file).font(.subheadline.monospaced())
                                Text(item.parseError ?? "unknown error").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        SectionTitle("Could not read")
                    }
                }
                if waiting.isEmpty && onWatch.isEmpty && earlier.isEmpty && invalid.isEmpty {
                    Section {
                        InfoRow(symbol: "tray", tint: .secondary, title: "No workout plans yet",
                                line: "Ask your AI for a session. Say which day and time.")
                    } header: {
                        SectionTitle("Your workout plans")
                    }
                }

                Section {
                    NavigationLink(value: HomeRoute.prompts(.plans)) {
                        InfoRow(symbol: "text.bubble", tint: .accentColor, title: "Prompts",
                                line: "\(Prompts.in(.plans).count) ideas to plan workouts, any sport")
                    }
                } header: {
                    SectionTitle("Ideas for your AI")
                } footer: {
                    Text("Suggestions only.")
                }
            }
            .listStyle(.insetGrouped)
            .brandGround()
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model.checkPlansNow() }
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .settings: SettingsView()
                case .sessions: SessionsView()
                case .days: DaysView()
                case .prompts(let group): PromptsView(group: group)
                case .prompt(let prompt): PromptDetailView(prompt: prompt)
                case .clients: ClientsView()
                case .parts(let item): PlanPartsView(item: item)
                case .session(let entry): SessionDetailView(entry: entry)
                }
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { model.requestFolder(url) }
            }
        }
    }

    /// Where plans stand: a green check when nothing waits, the count when plans wait for you, Pick folder when the
    /// folder is missing.
    private var plansTile: some View {
        let waiting = model.needsYou.filter { model.results["plan:\($0.id)"] == nil }.count
        let onWatch = model.plansOnWatch.count
        let noFolder = model.folder == nil || model.folderStale
        let checked = model.lastPlanCheck.map { "checked \(Format.ago($0))" } ?? "not checked yet"
        if noFolder {
            return StatusTile(state: .needs, title: "Folder missing", detail: "Pick the folder your AI writes to.",
                              buttonTitle: "Pick folder", action: { showPicker = true })
        }
        if waiting > 0 {
            return StatusTile(state: .needs,
                              title: "\(waiting) plan\(waiting == 1 ? "" : "s") waiting",
                              detail: "Tap Put on Watch below, or turn on Automatic.")
        }
        return StatusTile(state: .done, title: "Up to date",
                          detail: "\(onWatch == 0 ? "Nothing" : "\(onWatch)") on your Watch · \(checked)")
    }
}

/// A plan that is (or was) on the Watch: when, how it got there, and Remove from Watch while it is still ahead.
struct ScheduledPlanRow: View {
    @Environment(AppModel.self) private var model
    let item: PlanItem

    private var key: String { "plan:\(item.id)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.name).font(.headline)
                Spacer()
                if let doc = item.doc { Text(doc.sportWords).font(.subheadline).foregroundStyle(.secondary) }
            }
            Text(line).font(.subheadline).foregroundStyle(.secondary)
            if let result = model.results[key] {
                ResultLine(result: result, undoKey: key)
            } else if item.state == .scheduled, (item.status?.scheduledFor ?? .distantFuture) > Date() {
                HStack(spacing: 8) {
                    Button("Remove from Watch") { model.requestRemoveFromWatch(item) }
                        .buttonStyle(.bordered)
                        .fixedSize()
                    NavigationLink(value: HomeRoute.parts(item)) { Text("See parts") }
                        .buttonStyle(.bordered)
                        .fixedSize()
                }
            } else if item.state == .cancelled {
                Button("Put on Watch") { model.requestPutOnWatch(item) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    private var line: String {
        let when = item.status?.scheduledFor.map { Format.dayTime($0) }
        switch item.state {
        case .cancelled:
            return when.map { "Removed from your Watch. Was for \($0)." } ?? "Removed from your Watch."
        default:
            if item.status?.method == "preview" { return "Added through Apple's preview, without a date." }
            guard let when, let date = item.status?.scheduledFor else { return "On your Watch." }
            return date > Date() ? "Workout app → Scheduled, for \(when)." : "Was on your Watch for \(when)."
        }
    }
}
