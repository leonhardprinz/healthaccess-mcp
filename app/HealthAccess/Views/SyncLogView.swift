import SwiftUI

/// Every launch, wake, check and error, newest first. The "write again" actions live here as small text buttons.
struct SyncLogView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = Filter.all

    enum Filter: String, CaseIterable, Identifiable {
        case all, observer, refresh, plan, error
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .observer: return "Wakes"
            case .refresh: return "Refresh"
            case .plan: return "Plans"
            case .error: return "Errors"
            }
        }
    }

    private var lines: [String] {
        let all = model.logLines.reversed()
        guard filter != .all else { return Array(all) }
        return all.filter { $0.contains("[\(filter.rawValue)]") }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Last check", value: model.settings.lastSync.map(Format.dateTime) ?? "none yet")
                LabeledContent("Last wake by a workout", value: model.settings.lastObserverFire.map(Format.dateTime) ?? "none yet")
                LabeledContent("Last wake by sleep", value: model.settings.lastSleepWake.map(Format.dateTime) ?? "none yet")
                LabeledContent("Last run from Shortcuts", value: model.settings.lastShortcutRun.map(Format.dateTime) ?? "none")
                LabeledContent("Last refresh by iOS", value: model.settings.lastBGTaskRun.map(Format.dateTime) ?? "not yet")
                LabeledContent("Workouts", value: model.sessionFilesLine)
                LabeledContent("Catalog", value: model.settings.lastCatalogAt.map(Format.dateTime) ?? "none yet")
            } header: {
                Text("How files get written")
            } footer: {
                Text("Files are written when you open the app, when a workout finishes and when the Watch hands last night's sleep to the phone, as long as the phone has been unlocked once since it started. iOS's own refresh comes on top when iOS decides; for a new app that can take days. To sync at a set moment, use the Shortcuts action Sync Health data, for example in an automation when Sleep Focus turns off. The status row counts the sessions listed, so a hidden duplicate is not counted. \(PlansText.whereFrom)")
            }

            Section {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                if lines.isEmpty {
                    Text("Nothing logged yet").foregroundStyle(.secondary)
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            } footer: {
                Text("Kept in a file in the app's own storage, so it survives restarts. Share it when something looks wrong.")
            }

            Section {
                if let result = model.results["resync"] { ResultLine(result: result, undoKey: "resync") }
                Button("Write the last \(model.settings.backfillDays) days again") { model.requestResync() }
                    .font(.footnote)
                    .disabled(model.folder == nil || model.isSyncing)
                if let result = model.results["days"] { ResultLine(result: result, undoKey: "days") }
                Button("Write the last 30 days") { model.requestDaysBackfill() }
                    .font(.footnote)
                    .disabled(model.folder == nil)
                if let result = model.results["catalog"] { ResultLine(result: result, undoKey: "catalog") }
                Button("Write the catalog again") { model.requestCatalog() }
                    .font(.footnote)
                    .disabled(model.folder == nil || model.isSyncing)
            } footer: {
                Text("Session files that already exist are never overwritten, so the Watch's ratings survive. Day files are rewritten only when a value changed. Days the app missed while it was closed are filled in on their own; for the years before, see Settings → Older data.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Sync log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: DiskLog.shared.fileURL) {
                    Image(systemName: "square.and.arrow.up").accessibilityLabel("Share the log")
                }
                Button {
                    Task { await model.clearLog() }
                } label: {
                    Image(systemName: "trash").accessibilityLabel("Clear the log")
                }
            }
        }
    }
}
