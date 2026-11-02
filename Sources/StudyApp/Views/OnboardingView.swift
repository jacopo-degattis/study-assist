import SwiftUI
import AppKit
import StudyDomain
import StudyDesignSystem

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0

    @State private var providerName = "My model"
    @State private var baseURL = "https://openrouter.ai/api/v1"
    @State private var style: ProviderAPIStyle = .chatCompletions
    @State private var modelId = ""
    @State private var apiKey = ""
    @State private var providerError: String?
    @State private var providerStatus: String?
    @State private var isWorking = false

    @State private var speechEngine: SpeechEngine = .appleOnDevice
    @State private var language = ""
    @State private var addedSpeech = false

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.spacingXL) {
            HStack(spacing: 10) {
                Image(systemName: "book.closed")
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                Text("Welcome to StudyApp")
                    .font(StudyDesign.sectionTitleFont)
                Spacer()
                Text("Step \(step + 1) of 3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch step {
            case 0: welcome
            case 1: providerStep
            default: speechStep
            }

            Spacer(minLength: 0)
            Divider()
            HStack {
                Button("Set up later") {
                    Task {
                        await model.completeOnboarding()
                        dismiss()
                    }
                }
                .buttonStyle(.borderless)
                Spacer()
                if step > 0 {
                    Button("Back") { step -= 1 }
                        .buttonStyle(.bordered)
                }
                if step < 2 {
                    Button("Continue") { step += 1 }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Finish") {
                        Task {
                            await model.completeOnboarding()
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(28)
        .frame(minWidth: 640, minHeight: 580)
        .task { await model.refreshSpeechCatalog() }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Study one document with questions that come only from its text.")
                .font(.title3.weight(.semibold))
            Text("The app imports a PDF or DOCX, extracts verifiable passages with page or paragraph references, and asks one question at a time. Every question, hint and correction is checked against those passages. You can answer by typing or dictating.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            StudyCard {
                VStack(alignment: .leading, spacing: 8) {
                    Label("You choose the AI provider", systemImage: "sparkles")
                    Label("Your documents stay on this Mac", systemImage: "lock")
                    Label("Speech can stay on-device", systemImage: "mic")
                }
                .font(.callout)
            }
            Text("Next: connect an OpenAI-compatible model. You can skip this and set it up in Settings instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var providerStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect a model")
                .font(StudyDesign.sectionTitleFont)
            Text("Use an OpenAI-compatible endpoint. The app makes a real request to verify authentication, the endpoint, the model and JSON output.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $providerName)
                TextField("Base URL", text: $baseURL)
                Picker("API style", selection: $style) {
                    ForEach(ProviderAPIStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                TextField("Model ID", text: $modelId)
                SecureField("API key", text: $apiKey)
            }
            .formStyle(.grouped)
            if let providerError {
                ErrorBanner(message: providerError)
            }
            if let providerStatus {
                Label(providerStatus, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Button("Save and test connection") { saveAndTest() }
                    .buttonStyle(.bordered)
                    .disabled(isWorking)
                if !model.providerProfiles.isEmpty {
                    Label("A provider is configured", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private var speechStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Spoken answers")
                .font(StudyDesign.sectionTitleFont)
            Text("Choose how dictation should work. Microphone permission is requested only when you first record, and transcripts are editable before submission.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Engine", selection: $speechEngine) {
                ForEach(availableEngines, id: \.self) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            .frame(maxWidth: 380)
            TextField("Language (optional, for example it or en-US)", text: $language)
                .frame(maxWidth: 280)
            Text(speechEngine.supportedLanguageNote)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Use this engine") { addSpeech() }
                    .buttonStyle(.bordered)
                if addedSpeech {
                    Label("Speech engine configured", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            Text("Typed answers always work. Local engines never send audio off this Mac; a custom endpoint sends the recording to the URL you configure.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var availableEngines: [SpeechEngine] {
        let engines = model.speechCatalog.filter { $0.availability.isAvailable }.map(\.engine)
        let filtered = engines.filter { $0 != .customEndpoint }
        return filtered.isEmpty ? [.appleOnDevice] : filtered
    }

    private func saveAndTest() {
        providerError = nil
        providerStatus = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let profile = try await model.saveProvider(
                    name: providerName,
                    baseURL: baseURL,
                    style: style,
                    modelId: modelId,
                    apiKey: apiKey,
                    requiresAuthentication: true,
                    extraHeaders: [:],
                    timeoutSeconds: 60,
                    maxRetries: 1
                )
                let result = await model.testConnection(for: profile)
                switch result {
                case .success(let test):
                    providerStatus = test.detail
                case .failure(let error):
                    providerError = model.message(for: error)
                }
            } catch {
                providerError = model.message(for: error)
            }
        }
    }

    private func addSpeech() {
        Task {
            do {
                let profile = try await model.saveSpeechProfile(
                    engine: speechEngine,
                    language: speechEngine == .customEndpoint ? nil : language,
                    modelId: nil,
                    remoteBaseURL: nil,
                    apiKey: nil
                )
                await model.setActiveSpeechProfile(profile.id)
                addedSpeech = true
            } catch {
                providerError = model.message(for: error)
            }
        }
    }
}
