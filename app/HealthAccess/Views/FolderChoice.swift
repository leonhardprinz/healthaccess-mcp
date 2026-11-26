import SwiftUI

/// "Pick folder", on every screen: first the question where the files go, then the iOS folder picker or the
/// list of cloud drives. A storage app such as Google Drive cannot be picked as a folder, so the second way
/// keeps the files on this iPhone and uploads them.
struct FolderChoice: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool
    /// Opens the screen's own folder picker: a view can hold only one.
    let pickFolder: () -> Void

    enum Step { case folder, drives }
    @State private var next: Step?
    @State private var showDrives = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, onDismiss: go) {
                FolderChoiceSheet(drives: model.cloud.kinds.map(\.name)) { step in
                    next = step
                    isPresented = false
                }
            }
            .sheet(isPresented: $showDrives) { DriveChoiceSheet() }
    }

    /// The next step opens only after the question has closed: two sheets cannot be up at once.
    private func go() {
        switch next {
        case .folder: pickFolder()
        case .drives: showDrives = true
        case nil: break
        }
        next = nil
    }
}

extension View {
    /// Shows the question "a folder or a cloud drive" and then the matching next step.
    func folderChoice(isPresented: Binding<Bool>, pickFolder: @escaping () -> Void) -> some View {
        modifier(FolderChoice(isPresented: isPresented, pickFolder: pickFolder))
    }
}

enum FolderChoiceCopy {
    static let title = "Where do your files go?"
    static let folderTitle = "A folder"
    static let folderLine = "iCloud Drive, a network drive or On My iPhone. Pick this if the folder reaches the computer where your AI runs."
    static let drivesTitle = "A cloud drive"

    static func drivesLine(_ drives: [String]) -> String {
        "\(Format.list(drives, last: "or")). The app keeps your files on this iPhone and uploads them to your drive."
    }
}

/// The question itself: two rows, one tap.
struct FolderChoiceSheet: View {
    let drives: [String]
    let pick: (FolderChoice.Step) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(FolderChoiceCopy.title).font(.title3.weight(.semibold))
            option(symbol: "folder", title: FolderChoiceCopy.folderTitle, line: FolderChoiceCopy.folderLine) { pick(.folder) }
            if !drives.isEmpty {
                option(symbol: "icloud.and.arrow.up", title: FolderChoiceCopy.drivesTitle, line: FolderChoiceCopy.drivesLine(drives)) { pick(.drives) }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func option(symbol: String, title: String, line: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.title3).foregroundStyle(Color.accentColor).frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(Color.primary)
                    Text(line).font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// Set inside the drive sheet, so a drive's own screen can offer "Done" as well.
private struct CloseDriveSheetKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var closeDriveSheet: (() -> Void)? {
        get { self[CloseDriveSheetKey.self] }
        set { self[CloseDriveSheetKey.self] = newValue }
    }
}

/// The drives, in a sheet of their own. It shows the confirmation itself, because the root view cannot put
/// a sheet on top of this one.
struct DriveChoiceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            CloudList()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        .environment(\.closeDriveSheet, { dismiss() })
        .sheet(item: $model.confirmation, onDismiss: { model.confirmationDismissed() }) { confirmation in
            ConfirmSheet(confirmation: confirmation)
        }
        .onAppear { model.confirmationInSheet = true }
        .onDisappear { model.confirmationInSheet = false }
    }
}
