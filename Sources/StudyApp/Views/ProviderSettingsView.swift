import SwiftUI
import StudyDomain
import StudyProviders
import StudyDesignSystem

struct SettingsView: View {
    var body: some View {
        TabView {
            ProviderSettingsView()
                .tabItem { Label("AI Model", systemImage: "sparkles") }
            SpeechSettingsView()
                .tabItem { Label("Speech", systemImage: "mic") }
            PromptSettingsView()
                .tabItem { Label("AI Instructions", systemImage: "text.alignleft") }
            DataSettingsView()
                .tabItem { Label("Data", systemImage: "externaldrive") }
        }
        .padding(16)
        .navigationTitle("Settings")
        .frame(minWidth: 680, minHeight: 540)
    }
}

// MARK: - Providers

struct ProviderSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editor: ProviderEditorContext?
    @State private var testingID: ProviderProfileID?
    @State private var testResult: (ProviderProfileID, Result<ConnectionTestResult, Error>)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudyDesign.spacingL) {
                SectionHeader(
                    title: "AI model",
                    subtitle: "Only one provider is active at a time. Changes apply to new sessions; a running session keeps the provider it started with."
                )
                if model.providerProfiles.isEmpty {
                    EmptyStateView(
                        symbol: "sparkles",
                        title: "No provider yet",
                        message: "Add an OpenAI-compatible endpoint. The app tests the real connection before using it for study."
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(model.providerProfiles) { profile in
                        providerRow(profile)
                    }
                }
                Button {
                    editor = ProviderEditorContext(profile: nil)
                } label: {
                    Label("Add provider", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                
                StudyCard {
                    Text("With a remote provider, the passages needed for the current question or assessment, the question, the rubric and your answer are sent to that provider. Documents and history remain on this Mac. API keys are stored in the macOS Keychain, never in the database or AGENT.md.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: 780, alignment: .leading)
        }
        .sheet(item: $editor) { context in
            ProviderEditorView(existing: context.profile)
                .environmentObject(model)
        }
    }

    private func providerRow(_ profile: ProviderProfile) -> some View {
        StudyCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Button {
                        Task { await model.setActiveProvider(profile.id) }
                    } label: {
                        Image(systemName: model.activeProviderID == profile.id ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(model.activeProviderID == profile.id ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(model.activeProviderID == profile.id ? "Active provider" : "Make active provider")

                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.name)
                            .font(StudyDesign.headingFont)
                        Text("\(profile.modelId) · \(profile.apiStyle.displayName) · \(profile.baseURL)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if model.hasAPIKey(for: profile) {
                        Label("Key in Keychain", systemImage: "key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Menu {
                        Button("Edit…") { editor = ProviderEditorContext(profile: profile) }
                        Button("Test connection") {
                            testingID = profile.id
                            Task {
                                let result = await model.testConnection(for: profile)
                                testingID = nil
                                testResult = (profile.id, result)
                            }
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            Task { await model.deleteProvider(profile.id) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Provider actions")
                }

                if testingID == profile.id {
                    BusyLabel(text: "Testing the real connection")
                }
                if let testResult, testResult.0 == profile.id {
                    switch testResult.1 {
                    case .success(let result):
                        Label("\(result.detail) \(String(format: "%.0f ms", result.latency * 1000))", systemImage: "checkmark.seal")
                            .font(.caption)
                            .foregroundStyle(.green)
                    case .failure(let error):
                        Label(model.message(for: error), systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let tested = profile.lastConnectionTest {
                    Text("Last tested \(tested.formatted(date: .abbreviated, time: .shortened)) · \(profile.lastConnectionSucceeded == true ? "succeeded" : "failed")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ProviderEditorContext: Identifiable {
    let id = UUID()
    let profile: ProviderProfile?
}

struct ProviderEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let existing: ProviderProfile?

    @State private var name: String
    @State private var baseURL: String
    @State private var style: ProviderAPIStyle
    @State private var modelId: String
    @State private var apiKey: String = ""
    @State private var requiresAuthentication: Bool
    @State private var timeout: Double
    @State private var retries: Int
    @State private var extraHeadersText: String
    @State private var errorMessage: String?
    @State private var testMessage: String?
    @State private var isWorking = false

    init(existing: ProviderProfile?) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _baseURL = State(initialValue: existing?.baseURL ?? "https://openrouter.ai/api/v1")
        _style = State(initialValue: existing?.apiStyle ?? .chatCompletions)
        _modelId = State(initialValue: existing?.modelId ?? "")
        _requiresAuthentication = State(initialValue: existing?.requiresAuthentication ?? true)
        _timeout = State(initialValue: existing?.timeoutSeconds ?? 60)
        _retries = State(initialValue: existing?.maxRetries ?? 1)
        let headers = (existing?.extraHeaders ?? [:])
            .map { "\($0.key): \($0.value)" }
            .sorted()
            .joined(separator: "\n")
        _extraHeadersText = State(initialValue: headers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "Add provider" : "Edit provider")
                .font(StudyDesign.sectionTitleFont)

            Form {
                TextField("Name", text: $name)
                TextField("Base URL", text: $baseURL, prompt: Text("https://openrouter.ai/api/v1"))
                Picker("API style", selection: $style) {
                    ForEach(ProviderAPIStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                TextField("Model ID", text: $modelId, prompt: Text("exact model identifier"))
                Toggle("Requires authentication", isOn: $requiresAuthentication)
                SecureField("API key", text: $apiKey, prompt: Text(existing?.keychainRef != nil ? "Stored in Keychain — leave blank to keep" : "Stored in the Keychain"))
                    .disabled(!requiresAuthentication)
                HStack {
                    TextField("Timeout (seconds)", value: $timeout, format: .number)
                    Stepper("Retries: \(retries)", value: $retries, in: 0...5)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra headers (non-secret, one per line: Name: value)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $extraHeadersText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 54)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                }
            }
            .formStyle(.grouped)

            StudyCard {
                VStack(alignment: .leading, spacing: 4) {
                    Text("OpenCode Go: base URL https://opencode.ai/inference/go/openai/v1")
                    Text("Use Responses for gpt-5.6-luna or Chat Completions for glm-5.3. The app sends a stable x-opencode-session header automatically; OpenCode Go is intended for coding agents, so check their terms before using it here.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage {
                ErrorBanner(message: errorMessage)
            }
            if let testMessage {
                Text(testMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                if isWorking {
                    ProgressView().controlSize(.small)
                }
                Button("Save") { save(thenTest: false) }
                Button("Save and test") { save(thenTest: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)
            }
        }
        .padding(24)
        .frame(minWidth: 580, minHeight: 540)
    }

    private func save(thenTest: Bool) {
        errorMessage = nil
        testMessage = nil
        isWorking = true
        var headers: [String: String] = [:]
        for line in extraHeadersText.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            headers[parts[0]] = parts[1]
        }
        let keyToSend: String? = apiKey.isEmpty ? nil : apiKey
        Task {
            defer { isWorking = false }
            do {
                let profile = try await model.saveProvider(
                    name: name,
                    baseURL: baseURL,
                    style: style,
                    modelId: modelId,
                    apiKey: keyToSend,
                    requiresAuthentication: requiresAuthentication,
                    extraHeaders: headers,
                    timeoutSeconds: timeout,
                    maxRetries: retries,
                    existingID: existing?.id
                )
                if thenTest {
                    let result = await model.testConnection(for: profile)
                    switch result {
                    case .success(let test):
                        testMessage = "\(test.detail) (\(String(format: "%.0f ms", test.latency * 1000)))"
                        dismiss()
                    case .failure(let error):
                        errorMessage = model.message(for: error)
                    }
                } else {
                    dismiss()
                }
            } catch {
                errorMessage = model.message(for: error)
            }
        }
    }
}
