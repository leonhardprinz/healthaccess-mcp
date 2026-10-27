import SwiftUI

/// Four screens, one sentence of why and one button each: what it is → pick a folder → allow Health and
/// notifications → connect your AI.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var page = 0
    @State private var showPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            MarkTile(size: 64)
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(i <= page ? Color.accentColor : Color(.separator)).frame(height: 3)
                }
            }
            .padding(.bottom, 18)
            .accessibilityLabel("Step \(page + 1) of 4")
            Group {
                switch page {
                case 0: intro
                case 1: folder
                case 2: health
                default: connect
                }
            }
            .animation(.easeInOut(duration: 0.2), value: page)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 34)
        .background(Color(.systemBackground))
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.requestFolder(url, key: "folder") }
        }
    }

    private func screen<Buttons: View>(_ title: String, _ text: String, @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.brand(30, relativeTo: .title)).fixedSize(horizontal: false, vertical: true)
            Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) { buttons() }.padding(.top, 10)
        }
    }

    private var intro: some View {
        screen("Apple won't let your AI read your Watch. This does.",
               "Health Access writes your workouts and vitals as plain files into a folder you pick, then gets out of the way. Your AI reads the folder, on your computer.") {
            primary("Continue") { page = 1 }
        }
    }

    private var folder: some View {
        screen("Pick a folder",
               "Anything the Files app can see: iCloud Drive, Dropbox, Google Drive, OneDrive, a NAS. Pick one that syncs to the computer where your AI runs.") {
            if let result = model.results["folder"] ?? model.storedFolderResult {
                ResultLine(result: result, undoKey: "folder").padding(.bottom, 4)
            }
            if model.folder == nil {
                primary("Pick folder") { showPicker = true }
            } else {
                primary("Continue") { page = 2 }
                secondary("Pick a different folder") { showPicker = true }
            }
        }
    }

    private var health: some View {
        screen("Allow Health access",
               "Read only, you choose the types. Notifications are for one thing: telling you when your AI wrote a plan.") {
            if !model.settings.healthAuthRequested {
                primary("Allow Health access") { Task { await model.requestHealthAccess() } }
            } else if !model.settings.notificationsRequested {
                Label("Health access requested", systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(.secondary)
                primary("Allow notifications") { Task { await model.requestNotifications() } }
            } else {
                Label("Health access requested", systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(.secondary)
                Label(model.notificationStatus == .denied ? "Notifications off" : "Notifications allowed", systemImage: "checkmark.circle.fill")
                    .font(.subheadline).foregroundStyle(.secondary)
                primary("Continue") { page = 3 }
            }
        }
    }

    private var connect: some View {
        screen("Now connect your AI.",
               "This app only writes the files. Your AI reads them on your computer. Copy the setup message, paste it to Claude, ChatGPT or Cursor, and it installs the rest itself.") {
            Text(PlansText.whereFrom)
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)
            if let result = model.results["setup-onboarding"] {
                ResultLine(result: result, undoKey: "setup-onboarding").padding(.bottom, 4)
                primary("Done") { finish() }
            } else {
                primary("Copy setup message") { model.requestSetupCopy(key: "setup-onboarding") }
                secondary("I'll do it later") { finish() }
            }
        }
    }

    private func finish() {
        model.settings.onboardingDone = true
        model.log("onboarding done", .ui)
        Task { await model.runSync(trigger: .manual) }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
    }
}
