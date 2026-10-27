import SwiftUI

/// Checkmark + what happened, plus Undo while it is still possible. Lives inside the row the action came from.
struct ResultLine: View {
    @Environment(AppModel.self) private var model
    let result: AppModel.ActionResult
    let undoKey: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: result.kind == .done ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(result.kind == .done ? Color.green : Color.secondary)
            Text(result.text).font(.subheadline)
            Spacer(minLength: 8)
            if let undo = model.undo, undo.key == undoKey {
                Button("Undo") { Task { await model.performUndo() } }
                    .buttonStyle(.borderless)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The dot that marks a row the user has to act on: the one warm element in the app.
struct NeedsDot: View {
    var body: some View {
        Circle().fill(Color.signal).frame(width: 8, height: 8).accessibilityHidden(true)
    }
}

/// UIActivityViewController for the setup message and session files.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// One sentence, Confirm or Cancel, then progress until the action is done. Nothing happens without it.
struct ConfirmSheet: View {
    @Environment(AppModel.self) private var model
    let confirmation: AppModel.Confirmation
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(confirmation.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Text(confirmation.detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                busy = true
                Task {
                    await confirmation.action()
                    model.confirmation = nil
                }
            } label: {
                HStack(spacing: 8) {
                    if busy { ProgressView().tint(.white) }
                    Text(busy ? "Working…" : confirmation.confirmTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(busy)
            Button("Cancel") { model.confirmation = nil }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(busy)
        }
        .padding(24)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(busy)
    }
}
