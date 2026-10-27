import SwiftUI
import WorkoutKit

/// Onboarding until it is done, then the three tabs. The confirmation sheet, the share sheet and Apple's workout preview live
/// here so every screen can use them.
struct RootView: View {
    @Environment(AppModel.self) private var model

    private static let placeholder = WorkoutPlan(.custom(CustomWorkout(activity: .swimming, location: .indoor)))

    var body: some View {
        @Bindable var model = model
        Group {
            if model.settings.onboardingDone {
                MainTabs()
            } else {
                OnboardingView()
            }
        }
        .sheet(item: $model.confirmation, onDismiss: { model.confirmationDismissed() }) { confirmation in
            ConfirmSheet(confirmation: confirmation)
        }
        .sheet(item: $model.shareItems) { share in
            ShareSheet(items: share.items)
                .presentationDetents([.medium, .large])
        }
        .workoutPreview(model.previewing?.plan ?? Self.placeholder, isPresented: $model.showPreview)
        .onChange(of: model.showPreview) { _, shown in
            guard !shown else { return }
            Task { await model.previewClosed() }
        }
    }
}

/// Export (Health data out to your folder), Plans (sessions from your AI onto the Watch), Settings.
struct MainTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            HomeView()
                .tabItem { Label("Export", systemImage: "arrow.up.doc") }
                .tag(AppModel.Tab.export)
            PlansView()
                .tabItem { Label("Import", systemImage: "arrow.down.doc") }
                .tag(AppModel.Tab.plans)
                .badge(model.needsYou.filter { model.results["plan:\($0.id)"] == nil }.count)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppModel.Tab.settings)
        }
    }
}
