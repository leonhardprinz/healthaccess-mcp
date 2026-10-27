import StoreKit
import SwiftUI

/// Where a push from Home goes.
enum HomeRoute: Hashable {
    case settings, sessions, days, clients
    case prompts(Prompt.Group)
    case prompt(Prompt)
    case parts(PlanItem)
    case session(IndexEntry)
}

/// The Export tab, in the order every tab uses: header, status tile, Folder, Your AI, Sync, the content, ideas for
/// your AI. Then the support card.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [HomeRoute] = []
    @State private var showPicker = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    exportTile
                } header: {
                    TabHeader(title: "Export your Apple Health data", line: "Workouts and daily data, as files for your AI.")
                }

                Section {
                    FolderRow(pickFolder: { showPicker = true })
                } header: {
                    SectionTitle("Folder")
                } footer: {
                    Text("Health Access writes here. Your AI reads it on your computer.")
                }

                Section {
                    ConnectRow()
                    if model.clients.count > 1 {
                        NavigationLink(value: HomeRoute.clients) {
                            HStack {
                                Text("All connected AIs")
                                Spacer()
                                Text("\(model.clients.count)").foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    SectionTitle("Your AI")
                }

                Section {
                    InfoRow(symbol: "arrow.triangle.2.circlepath", tint: .accentColor,
                            title: "Automatic",
                            line: "After every workout, while your phone is unlocked.")
                } header: {
                    SectionTitle("Sync from Health")
                } footer: {
                    Text("Pull down to sync now.")
                }

                Section {
                    NavigationLink(value: HomeRoute.sessions) {
                        InfoRow(symbol: "figure.run", tint: .accentColor, title: "Workouts", line: sessionsLine)
                    }
                    NavigationLink(value: HomeRoute.days) {
                        InfoRow(symbol: "calendar", tint: .accentColor, title: "Days",
                                line: model.dayFiles == 0 ? "No files yet" : "\(model.dayFiles) file\(model.dayFiles == 1 ? "" : "s"), one per day")
                    }
                } header: {
                    SectionTitle("Your files")
                }

                Section {
                    NavigationLink(value: HomeRoute.prompts(.export)) {
                        InfoRow(symbol: "text.bubble", tint: .accentColor, title: "Prompts",
                                line: "\(Prompts.in(.export).count) ideas to understand your data")
                    }
                } header: {
                    SectionTitle("Ideas for your AI")
                } footer: {
                    Text("Suggestions only. What you share with an AI is between you and that AI.")
                }

                if !model.support.cardRemoved || model.results["support"] != nil {
                    Section {
                        SupportCard()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .brandGround()
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model.runSync(trigger: .manual) }
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

    /// The status of the export: a green check when everything is written, otherwise the state and its one fix.
    private var exportTile: some View {
        let status = model.status
        let state: TileState
        switch status.kind {
        case .done: state = .done
        case .working: state = .working
        case .waiting: state = .waiting
        case .failed: state = .failed
        case .needs: state = .needs
        }
        return StatusTile(state: state, title: status.title, detail: status.detail,
                          buttonTitle: status.action?.title,
                          action: { if let a = status.action { handle(a.kind) } })
    }

    private var sessionsLine: String {
        let n = model.sessionCount
        guard let newest = model.index?.workouts.first else { return "No workouts yet" }
        return "\(n) workout\(n == 1 ? "" : "s"), newest \(Format.date(newest.start))"
    }

    private func handle(_ action: AppModel.StatusAction) {
        switch action {
        case .pickFolder:
            showPicker = true
        case .allowHealth:
            Task { await model.requestHealthAccess() }
        case .allowNotifications:
            Task { await model.requestNotifications() }
        case .openSystemSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        case .syncNow:
            Task { await model.runSync(trigger: .manual) }
        }
    }
}

/// The tip jar, last on the Export tab: open source, privacy first, and the App Store buttons that pay for the tokens.
/// Apple's payment sheet is the confirmation; the card then shows the result like every other row.
struct SupportCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.purchase) private var purchase
    @State private var busy = false

    static let text = "Health Access is open source and privacy first: it unlocks your own health data into folders you own, nothing in between. The AI tokens that built it cost real money. Remove this card for good and help the dev recoup them, or buy a coffee and leave it."

    var body: some View {
        let store = model.support
        VStack(alignment: .leading, spacing: 8) {
            Text("Open source, privacy first").font(.headline)
            Text(Self.text).font(.subheadline).foregroundStyle(.secondary)
            if let result = model.results["support"] {
                ResultLine(result: result, undoKey: "support")
            } else {
                switch store.availability {
                case .loading:
                    Text("Loading prices…").font(.footnote).foregroundStyle(.secondary)
                case .unavailable:
                    Text("No prices right now; the App Store did not answer.").font(.footnote).foregroundStyle(.secondary)
                case .ready:
                    HStack(spacing: 8) {
                        if let card = store.card {
                            Button("Remove this card · \(card.displayPrice)") { buy(card) }
                                .buttonStyle(.borderedProminent)
                        }
                        if let coffee = store.coffee {
                            Button("Coffee · \(coffee.displayPrice)") { buy(coffee) }
                                .buttonStyle(.bordered)
                        }
                    }
                    .disabled(busy)
                    .padding(.top, 4)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func buy(_ product: Product) {
        busy = true
        Task {
            await model.buySupport(product, purchase: purchase)
            busy = false
        }
    }
}


/// "Your AI wrote S26": Put on Watch or See parts, then the result, all inside the row.
struct PlanRow: View {
    @Environment(AppModel.self) private var model
    let item: PlanItem

    private var key: String { "plan:\(item.id)" }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            NeedsDot().padding(.top, 7)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Your AI wrote \(item.name)").font(.headline)
                    Spacer()
                    if let doc = item.doc { Text(doc.sportWords).font(.subheadline).foregroundStyle(.secondary) }
                }
                if let doc = item.doc {
                    Text(doc.summaryLine).font(.subheadline).foregroundStyle(.secondary)
                    if model.results[key] == nil {
                        Text(model.planTiming(for: doc).sentence).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let result = model.results[key] {
                    ResultLine(result: result, undoKey: key)
                } else {
                    if item.state == .failed, let error = item.status?.error {
                        Text("Could not put it on your Watch last time: \(error)").font(.footnote).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Button("Put on Watch") { model.requestPutOnWatch(item) }
                            .buttonStyle(.borderedProminent)
                        NavigationLink(value: HomeRoute.parts(item)) {
                            Text("See parts")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// The door for your AI, as a state: connected (the MCP wrote a handshake file within 7 days), waiting after a copy,
/// or not connected yet with the Copy button.
struct ConnectRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let client = model.connectedClient {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green).font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connected · \(client.name)")
                        Text(client.whereAndWhen).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                if let result = model.results["setup"] { ResultLine(result: result, undoKey: "setup") }
                Button("Connect another AI") { model.requestSetupCopy() }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
            }
            .padding(.vertical, 2)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "circle.dashed").foregroundStyle(Color.signal).font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Not connected")
                        Text("Copy the setup message, paste it to Claude or Cursor on your computer.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Copy") { model.requestSetupCopy() }
                        .buttonStyle(.borderedProminent)
                }
                if let result = model.results["setup"] { ResultLine(result: result, undoKey: "setup") }
                if model.waitingForClient {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for your AI to connect…").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// Every AI that ever connected, newest first.
/// Where plans come from, for the onboarding and the sync log.
enum PlansText {
    static let whereFrom = "Your AI writes plans into the plans folder. Health Access checks it when you open the app and when iOS wakes it, and tells you when a plan arrives."
}

struct ClientsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                ForEach(model.clients) { client in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            if client.isConnected() {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                            }
                            Text(client.name)
                            if let version = client.version { Text(version).foregroundStyle(.secondary).font(.subheadline) }
                        }
                        Text(detail(client)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("From the handshake files the MCP writes into mcp/clients in your folder. An AI counts as connected when it was seen within 7 days.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Connected AIs")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detail(_ client: ClientInfo) -> String {
        var parts: [String] = []
        if let machine = client.machine { parts.append(machine) }
        if let mcp = client.mcpVersion { parts.append("MCP \(mcp)") }
        if let first = client.firstSeen { parts.append("first \(Format.dayTime(first))") }
        if let last = client.lastSeen { parts.append("last \(Format.ago(last))") }
        if let calls = client.calls { parts.append("\(calls) call\(calls == 1 ? "" : "s")") }
        if let tool = client.lastTool { parts.append("last tool \(tool)") }
        return parts.joined(separator: " · ")
    }
}
