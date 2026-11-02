import SwiftUI
import StudyDomain
import StudyDesignSystem

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: Binding(
            get: { !model.hasCompletedOnboarding },
            set: { presented in if !presented { Task { await model.completeOnboarding() } } }
        )) {
            OnboardingView()
                .environmentObject(model)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let startupError = model.startupError {
                ErrorBanner(message: startupError)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
        }
    }

    private var sidebar: some View {
        List(selection: Binding(
            get: { model.sidebarSelection },
            set: { newValue in
                guard let newValue else { return }
                if newValue != .documents {
                    model.study = nil
                }
                model.sidebarSelection = newValue
            }
        )) {
            Section("Study") {
                Label("Documents", systemImage: "books.vertical")
                    .tag(SidebarSection.documents)
                Label("History", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarSection.history)
            }
            Section {
                Label("Settings", systemImage: "gearshape")
                    .tag(SidebarSection.settings)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("StudyApp")
    }

    @ViewBuilder
    private var detail: some View {
        switch model.sidebarSelection {
        case .documents:
            if let study = model.study {
                StudyView(viewModel: study)
                    .id(study.session.id)
            } else if let ready = model.readyDocument {
                DocumentReadyView(ready: ready)
                    .id(ready.document.id)
            } else {
                LibraryHomeView()
            }
        case .history:
            HistoryView()
        case .settings:
            SettingsView()
        }
    }
}
