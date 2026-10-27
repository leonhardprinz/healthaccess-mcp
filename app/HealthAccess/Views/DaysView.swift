import SwiftUI

/// One row per day file, as text.
struct DaysView: View {
    @Environment(AppModel.self) private var model
    @State private var days: [AppModel.DaySummary] = []
    @State private var loaded = false

    var body: some View {
        List {
            if !loaded {
                Section { ProgressView() }
            } else if days.isEmpty {
                Section {
                    Text("No day files yet. Today and yesterday are written on every check; Settings → Sync log can write the last 30 days.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(days) { day in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title(day.id))
                            Text(day.line).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                } footer: {
                    Text("One file per day in days/, with a group per kind of data that has values: activity, heart, respiratory, sleep, body, blood, mobility, hearing, nutrition, mind, symptoms, cycle, medications, hygiene, uv, wheelchair, audiogram, vision.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Days")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            days = model.loadDays()
            loaded = true
        }
    }

    private func title(_ date: String) -> String {
        HealthAccessJSON.date(date + "T12:00:00Z").map(Format.date) ?? date
    }
}
