import SwiftUI

@main
struct HealthAccessApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    private let model = AppModel.shared

    init() {
        Brand.applyAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in
            Task { await model.scenePhaseChanged(phase) }
        }
    }
}
