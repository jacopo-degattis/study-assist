import SwiftUI
import StudyDomain
import StudyPersistence

@main
struct StudyApp: App {
    @StateObject private var model = AppModel.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 620)
                .task { await model.bootstrap() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    model.sidebarSelection = .settings
                    model.study = nil
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Import Document…") {
                    model.requestImportPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Study") {
                Button("End Session") {
                    Task { await model.endStudy() }
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(model.study == nil)
            }
        }
    }
}

extension AppModel {
    /// Creates the live model, falling back to an in-memory store if the library
    /// cannot be opened, so the app can explain the failure instead of crashing.
    static func live() -> AppModel {
        AppModel.makeStandard()
    }
}
