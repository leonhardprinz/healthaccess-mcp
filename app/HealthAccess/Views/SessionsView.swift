import SwiftUI

/// Plain rows: date, name, distance, duration, average heart rate, and what the Watch said about effort.
struct SessionsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if let entries = model.index?.workouts, !entries.isEmpty {
                Section {
                    ForEach(entries) { entry in
                        NavigationLink(value: HomeRoute.session(entry)) {
                            SessionRow(entry: entry, source: model.effortSources[entry.id])
                        }
                    }
                } footer: {
                    if let scan = model.indexScan, !scan.dropped.isEmpty {
                        Text("\(scan.dropped.count) duplicate\(scan.dropped.count == 1 ? "" : "s") hidden by the dedupe rule; the files stay in the folder.")
                    }
                }
            } else {
                Section {
                    Text(model.folder == nil ? "Pick a folder first." : "No workouts yet. Finish one on your Watch, or pull down on Export to sync now.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Workouts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SessionRow: View {
    let entry: IndexEntry
    let source: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.planName ?? ActivityMapping.title(entry.activity))
            Text(subtitle).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            Text(Format.effortLine(effort: entry.effort, source: source)).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        var parts = [Format.date(entry.start)]
        if entry.planName != nil { parts.append(ActivityMapping.title(entry.activity)) }
        if let d = entry.distanceM { parts.append(Format.distance(d)) }
        parts.append(Format.duration(entry.durationS))
        if let hr = entry.avgHr { parts.append("\(hr) bpm") }
        return parts.joined(separator: " · ")
    }
}

/// Text only: the one-line summary, the parts, the laps, Share.
struct SessionDetailView: View {
    @Environment(AppModel.self) private var model
    let entry: IndexEntry
    @State private var doc: WorkoutDoc?
    @State private var failed = false

    var body: some View {
        List {
            if let doc {
                content(doc)
            } else if failed {
                Section { Text("Could not read this file. \(model.lastError ?? "")").foregroundStyle(.secondary) }
            } else {
                Section { ProgressView() }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(entry.planName ?? ActivityMapping.title(entry.activity))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.index?.updated) {
            doc = model.loadWorkout(entry)
            failed = doc == nil
        }
        .toolbar {
            Button { model.shareSession(entry) } label: {
                Image(systemName: "square.and.arrow.up").accessibilityLabel("Share the file")
            }
        }
    }

    @ViewBuilder
    private func content(_ doc: WorkoutDoc) -> some View {
        Section {
            Text(summary(doc)).font(.body.monospacedDigit())
            Text(secondLine(doc)).font(.subheadline).foregroundStyle(.secondary)
            if let r = doc.recoveryHr {
                Text(recoveryLine(r)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            if let route = doc.routeSummary {
                Text("Route: \(route.points) points\(route.distanceM.map { " · \(Format.distance($0))" } ?? "")\(route.ascentM.map { " · \(Int($0)) m up" } ?? "")")
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(effortText(doc)).font(.subheadline)
            if let feel = doc.feel, !feel.isEmpty { Text(feel).font(.subheadline).foregroundStyle(.secondary) }
        } header: {
            Text(Format.dayTime(doc.start))
        }

        if !doc.steps.isEmpty {
            Section("Parts (\(doc.steps.count))") {
                ForEach(doc.steps) { step in
                    Text(partLine(step)).font(.subheadline).monospacedDigit()
                }
            }
        }

        if !doc.laps.isEmpty {
            Section("Laps") { Text(lapsLine(doc.laps)).font(.subheadline) }
        }

        Section("File") {
            Text((entry.file as NSString).lastPathComponent).font(.caption.monospaced()).textSelection(.enabled)
            if let plan = doc.planRef { Text("Plan: \(plan.name)").font(.caption).foregroundStyle(.secondary) }
            if let route = doc.routeFile { Text((route as NSString).lastPathComponent).font(.caption.monospaced()).textSelection(.enabled) }
            Text(filesLine(doc)).font(.caption).foregroundStyle(.secondary)
            Button("Share the file") { model.shareSession(entry) }
        }
    }

    private func summary(_ doc: WorkoutDoc) -> String {
        var parts = [ActivityMapping.title(doc.activity)]
        if let d = doc.distanceM { parts.append(Format.distance(d)) }
        parts.append(Format.duration(doc.durationS))
        if let hr = doc.avgHr { parts.append("avg \(hr) bpm") }
        if let hr = doc.maxHr { parts.append("max \(hr) bpm") }
        if let kcal = doc.activeKcal { parts.append(Format.kcal(kcal)) }
        return parts.joined(separator: " · ")
    }

    private func secondLine(_ doc: WorkoutDoc) -> String {
        var parts: [String] = []
        if let pool = doc.poolLengthM { parts.append("\(Int(pool)) m pool") }
        if let d = doc.distanceM, d > 0 { parts.append(Format.pace(Double(doc.durationS) / d * 100)) }
        parts.append(doc.source)
        return parts.joined(separator: " · ")
    }

    private func recoveryLine(_ r: RecoveryHR) -> String {
        var text = "Recovery HR: \([r.end, r.oneMin, r.twoMin].map { $0.map(String.init) ?? "none" }.joined(separator: " → ")) bpm"
        if let apple = r.apple1min { text += " · Apple 1 min \(apple.bpm) bpm" }
        return text
    }

    /// What else the file holds, as a count: "12 statistics · 48 events · 3 series".
    private func filesLine(_ doc: WorkoutDoc) -> String {
        var parts = ["\(doc.hrSeries.count) HR samples"]
        if !doc.statistics.isEmpty { parts.append("\(doc.statistics.count) statistics") }
        if !doc.events.isEmpty { parts.append("\(doc.events.count) events") }
        if !doc.series.isEmpty { parts.append("\(doc.series.count) series") }
        if doc.device != nil { parts.append("device") }
        return parts.joined(separator: " · ")
    }

    private func effortText(_ doc: WorkoutDoc) -> String {
        var text = Format.effortLine(effort: doc.effort, source: doc.effortSource)
        if let estimated = doc.effortEstimated { text += " · Apple estimates \(estimated)" }
        return text
    }

    /// "label · distance · pace · HR"
    private func partLine(_ step: StepDoc) -> String {
        var parts = [step.label ?? step.kind.capitalized]
        if let d = step.distanceM { parts.append(Format.distance(d)) } else { parts.append(Format.duration(step.durationS)) }
        if let p = step.paceSPer100m { parts.append(Format.pace(p)) }
        if let hr = step.avgHr { parts.append("\(hr) bpm") }
        return parts.joined(separator: " · ")
    }

    private func lapsLine(_ laps: [LapDoc]) -> String {
        var parts = ["\(laps.count) lap\(laps.count == 1 ? "" : "s")"]
        let strokes = Dictionary(grouping: laps.compactMap(\.stroke), by: { $0 }).mapValues(\.count)
        if !strokes.isEmpty {
            parts.append(strokes.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        let swolf = laps.compactMap(\.swolf)
        if !swolf.isEmpty { parts.append("avg SWOLF \(Int((swolf.reduce(0, +) / Double(swolf.count)).rounded()))") }
        parts.append("avg lap \(Format.duration(laps.map(\.durationS).reduce(0, +) / max(laps.count, 1)))")
        return parts.joined(separator: " · ")
    }
}
