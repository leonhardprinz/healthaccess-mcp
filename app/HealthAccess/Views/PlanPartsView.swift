import SwiftUI

/// "See parts": the plan as text, label · goal · zone, with Put on Watch and Apple's preview.
struct PlanPartsView: View {
    @Environment(AppModel.self) private var model
    let item: PlanItem

    private var key: String { "plan:\(item.id)" }

    var body: some View {
        List {
            if let doc = item.doc {
                Section {
                    Text(doc.summaryLine).font(.body.monospacedDigit())
                    if let notes = doc.notes, !notes.isEmpty { Text(notes).font(.subheadline).foregroundStyle(.secondary) }
                    if let pool = doc.poolLengthM {
                        Text("Pool length \(safeInt(pool) ?? 0) m: set it on the Watch, the plan cannot.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let by = doc.createdBy { Text("Written by \(by)").font(.footnote).foregroundStyle(.secondary) }
                } header: {
                    Text("\(doc.name) · \(doc.sportWords)")
                }

                let parts = doc.parts
                let sections = parts.reduce(into: [String]()) { if !$0.contains($1.section) { $0.append($1.section) } }
                ForEach(sections, id: \.self) { section in
                    Section(section) {
                        ForEach(parts.filter { $0.section == section }) { part in
                            Text(part.line).font(.subheadline).monospacedDigit()
                        }
                    }
                }

                Section {
                    if let result = model.results[key] {
                        ResultLine(result: result, undoKey: key)
                    } else {
                        if let status = item.status, status.state == "scheduled" {
                            Text(status.method == "preview" ? "Added via preview (unconfirmed)." : "On your Watch for \(status.scheduledFor.map(Format.dayTime) ?? "its time").")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Button("Put on Watch") { model.requestPutOnWatch(item) }
                        Button("Preview on Watch") { model.requestPreview(item) }
                    }
                } footer: {
                    Text("Put on Watch schedules the session in the Workout app and confirms it arrived. The preview shows Apple's sheet; Add to Watch there cannot be confirmed by the app.")
                }
            } else {
                Section("Invalid plan") {
                    Text(item.parseError ?? "unreadable").foregroundStyle(.secondary)
                }
            }

            Section("File") {
                Text(item.file).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
