import SwiftUI

/// Settings → Older data. The app writes the last 60 days on its own; this is where the years before that come from.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var looking: AppModel.HistorySpan?

    var body: some View {
        let _ = model.backlog.revision   // the stored state is not observed; this is what redraws the screen
        let settings = model.settings
        List {
            Section {
                Text("Health Access writes your last \(settings.backfillDays) days when you set it up, and everything new from then on. Health itself often holds years more. Import them once, and your AI can read long-term trends: a season against the last one, resting heart rate over years, how your sleep changed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if model.historyUnderWay {
                Section {
                    LabeledContent("Going back to", value: settings.historyStart.map(Format.date) ?? "")
                    if model.backlog.running {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(model.backlogLine).monospacedDigit()
                        }
                    } else if settings.historyPaused {
                        Text("Paused. \(remainingLine)").foregroundStyle(.secondary)
                    } else {
                        Text(model.backlog.note ?? "Waiting. It carries on while the app is open and the phone unlocked.")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Written so far", value: writtenLine)
                    if settings.historyPaused {
                        Button("Carry on") { model.resumeHistory() }
                    } else {
                        Button("Pause") { model.pauseHistory() }
                    }
                } header: {
                    SectionTitle("Importing")
                } footer: {
                    Text("Newest first, so the recent years are there early. Keep the app open and the phone unlocked: iOS locks Health with the phone. If you leave, it carries on where it stopped the next time you open the app. New workouts are written as always.")
                }
            } else {
                if settings.historyFinishedAt != nil {
                    Section {
                        LabeledContent("Your folder goes back to", value: settings.historyStart.map(Format.date) ?? "")
                        LabeledContent("Imported", value: writtenLine)
                    } header: {
                        SectionTitle("Imported")
                    }
                }
                Section {
                    ForEach(AppModel.HistorySpan.allCases) { span in
                        Button {
                            looking = span
                            Task {
                                await model.requestHistory(span)
                                looking = nil
                            }
                        } label: {
                            HStack {
                                Text(span.title)
                                Spacer()
                                if looking == span { ProgressView() }
                            }
                        }
                        .disabled(looking != nil || model.folder == nil || settings.lastSync == nil)
                    }
                    if let result = model.results["history"] { ResultLine(result: result, undoKey: "history") }
                } header: {
                    SectionTitle(settings.historyFinishedAt == nil ? "Import older data" : "Go further back")
                } footer: {
                    Text(settings.lastSync == nil
                         ? "Available after the first sync."
                         : "You see how many workouts and days it is before anything is written. Files that already exist are kept. A year is usually 5 to 40 MB in your folder; GPS routes are the bulk of it.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Older data")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var writtenLine: String {
        let s = model.settings
        return "\(s.historyWorkoutsWritten.formatted()) workout\(s.historyWorkoutsWritten == 1 ? "" : "s") · \(s.historyDaysWritten.formatted()) day\(s.historyDaysWritten == 1 ? "" : "s")"
    }

    private var remainingLine: String {
        let days = model.settings.historyDays.count
        return days == 0 ? "Workouts are left." : "\(days.formatted()) day\(days == 1 ? "" : "s") are left, and any workouts before them."
    }
}
