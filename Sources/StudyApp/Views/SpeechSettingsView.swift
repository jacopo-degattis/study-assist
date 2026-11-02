import SwiftUI
import StudyDomain
import StudyDesignSystem

struct SpeechSettingsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var selectedEngine: SpeechEngine = .appleOnDevice
    @State private var language: String = ""
    @State private var endpoint: String = ""
    @State private var transcriptModel: String = "whisper-1"
    @State private var endpointKey: String = ""
    @State private var errorMessage: String?
    @State private var availability: TranscriberAvailability?
    @State private var installProgress: Double?
    @State private var isWorking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudyDesign.spacingL) {
                SectionHeader(
                    title: "Speech input",
                    subtitle: "Answers can be typed or dictated. A transcript is inserted into the answer field as editable text; it is never submitted automatically and never graded differently."
                )
                activeEngineCard
                addEngineCard
                enginesCard
                StudyCard {
                    Text("Local engines transcribe on this Mac and never fall back to a server. When a custom endpoint is active, the recording is uploaded to it; audio files are deleted after transcription and are not kept in history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: 780, alignment: .leading)
        }
        .task { await refreshAvailability() }
        .onChange(of: model.activeSpeechProfile?.id) { _, _ in
            Task { await refreshAvailability() }
        }
    }

    @ViewBuilder
    private var activeEngineCard: some View {
        StudyCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Active engine")
                    .font(StudyDesign.headingFont)
                if let profile = model.activeSpeechProfile {
                    HStack(spacing: 10) {
                        Text(profile.engine.displayName)
                            .font(.body.weight(.medium))
                        if let language = profile.language {
                            Text(language)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isWorking {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if let availability {
                        Text(availability.detail)
                            .font(.callout)
                            .foregroundStyle(availability.isAvailable ? Color.secondary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        if availability.requiresDownload {
                            HStack(spacing: 12) {
                                if let installProgress {
                                    ProgressView(value: installProgress)
                                        .frame(width: 160)
                                    Text("\(Int(installProgress * 100))%")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                } else {
                                    Button("Download model") {
                                        install(profile)
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                                if let size = availability.approximateDownloadMegabytes {
                                    Text("About \(size) MB, stored in Application Support.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else if availability.isAvailable, profile.engine.isLocal, profile.engine != .appleOnDevice {
                            Button("Remove downloaded model") {
                                remove(profile)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } else {
                    Text("No speech engine is selected. Typed answers are unaffected.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if model.speechProfiles.count > 1 {
                    Divider()
                    ForEach(model.speechProfiles) { profile in
                        HStack(spacing: 10) {
                            Button {
                                Task {
                                    await model.setActiveSpeechProfile(profile.id)
                                    await refreshAvailability()
                                }
                            } label: {
                                Image(systemName: model.activeSpeechProfile?.id == profile.id ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(model.activeSpeechProfile?.id == profile.id ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Make \(profile.engine.displayName) the active speech engine")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.engine.displayName)
                                    .font(.callout)
                                if let url = profile.remoteBaseURL {
                                    Text(url)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Button("Remove", role: .destructive) {
                                Task {
                                    await model.deleteSpeechProfile(profile.id)
                                    await refreshAvailability()
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                }
            }
        }
    }

    private var addEngineCard: some View {
        StudyCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add an engine")
                    .font(StudyDesign.headingFont)
                Picker("Engine", selection: $selectedEngine) {
                    ForEach(availableEngines, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .frame(maxWidth: 380)
                if selectedEngine != .customEndpoint {
                    TextField("Language (optional, for example it or en-US)", text: $language)
                        .frame(maxWidth: 280)
                    Text(selectedEngine.supportedLanguageNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Transcription endpoint URL", text: $endpoint, prompt: Text("https://api.example.com/v1"))
                        .frame(maxWidth: 420)
                    HStack {
                        TextField("Model (optional)", text: $transcriptModel)
                            .frame(maxWidth: 220)
                        SecureField("API key (Keychain)", text: $endpointKey)
                            .frame(maxWidth: 260)
                    }
                    Text("Audio is sent to this endpoint only. A chat endpoint is not automatically a transcription endpoint; the app tests capability by requiring a real transcript.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    ErrorBanner(message: errorMessage)
                }
                Button("Add engine") { addEngine() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)
            }
        }
    }

    private var enginesCard: some View {
        StudyCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Engines in this build")
                    .font(StudyDesign.headingFont)
                Text("Only engines that can actually run here are selectable. The others are listed with their limitation instead of pretending support.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(model.speechCatalog) { status in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: status.availability.isAvailable ? "checkmark.circle" : "slash.circle")
                            .foregroundStyle(status.availability.isAvailable ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(status.engine.displayName)
                                .font(.callout)
                            Text(status.note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !status.availability.isAvailable {
                                Text(status.availability.detail)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                    }
                    if status.engine != model.speechCatalog.last?.engine {
                        Divider()
                    }
                }
            }
        }
    }

    private var availableEngines: [SpeechEngine] {
        let engines = model.speechCatalog
            .filter { $0.availability.isAvailable }
            .map(\.engine)
        var result = engines.filter { $0 != .customEndpoint }
        result.append(.customEndpoint)
        if !result.contains(selectedEngine) {
            result.append(selectedEngine)
        }
        return result
    }

    private func addEngine() {
        errorMessage = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let profile = try await model.saveSpeechProfile(
                    engine: selectedEngine,
                    language: selectedEngine == .customEndpoint ? nil : language,
                    modelId: selectedEngine == .customEndpoint ? transcriptModel : nil,
                    remoteBaseURL: selectedEngine == .customEndpoint ? endpoint : nil,
                    apiKey: selectedEngine == .customEndpoint ? endpointKey : nil
                )
                if model.activeSpeechProfile == nil {
                    await model.setActiveSpeechProfile(profile.id)
                }
                await model.refreshSpeechCatalog()
                await refreshAvailability()
                endpointKey = ""
            } catch {
                errorMessage = model.message(for: error)
            }
        }
    }

    private func install(_ profile: SpeechProfile) {
        isWorking = true
        installProgress = 0
        Task {
            defer {
                isWorking = false
                installProgress = nil
            }
            do {
                try await model.installSpeechModel(profile: profile, progress: { fraction in
                    Task { @MainActor in
                        installProgress = fraction
                    }
                })
            } catch {
                errorMessage = model.message(for: error)
            }
            await refreshAvailability()
        }
    }

    private func remove(_ profile: SpeechProfile) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await model.removeSpeechModel(profile: profile)
            } catch {
                errorMessage = model.message(for: error)
            }
            await refreshAvailability()
        }
    }

    private func refreshAvailability() async {
        guard let profile = model.activeSpeechProfile else {
            availability = nil
            return
        }
        availability = await model.speechManager.availability(for: profile)
    }
}
