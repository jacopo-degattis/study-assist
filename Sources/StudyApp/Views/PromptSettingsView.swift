import SwiftUI
import AppKit
import StudyDomain
import StudyDesignSystem

struct PromptSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft: String = ""
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var confirmRestore = false
    @State private var preview: PromptVersion?

    private var hasChanges: Bool {
        draft != (model.promptVersion?.content ?? model.promptContent)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudyDesign.spacingL) {
                SectionHeader(
                    title: "AI instructions",
                    subtitle: "AGENT.md sets the tutor's tone, question style and feedback style. Grounding rules are enforced in code and cannot be overridden here. Changes apply to newly generated questions and assessments; earlier records keep the version they used."
                )

                HStack(spacing: 10) {
                    if let version = model.promptVersion {
                        Text("Version \(version.contentHash.prefix(8)) · edited \(version.editedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if version.isDefault {
                            Text("default")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary.opacity(0.6), in: Capsule())
                        }
                    }
                    Spacer()
                    if isSaving { ProgressView().controlSize(.small) }
                    Button("Restore defaults") { confirmRestore = true }
                        .buttonStyle(.bordered)
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!hasChanges || isSaving)
                }

                if let statusMessage {
                    Label(statusMessage, systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    ErrorBanner(message: errorMessage)
                }

                TextEditor(text: $draft)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 300)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.separator.opacity(0.6), lineWidth: 1)
                    )
                    .accessibilityLabel("Tutor instructions, markdown")

                if model.promptVersions.count > 1 {
                    StudyCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Versions")
                                .font(StudyDesign.headingFont)
                            ForEach(model.promptVersions.prefix(12)) { version in
                                HStack(spacing: 10) {
                                    Text(version.editedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                    Text(version.contentHash.prefix(8))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    if version.isDefault {
                                        Text("default")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Preview") { preview = version }
                                        .buttonStyle(.borderless)
                                        .font(.caption)
                                    Button("Restore") {
                                        save(version.content)
                                    }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: 780, alignment: .leading)
        }
        .onAppear { draft = model.promptContent }
        .onChange(of: model.promptContent) { _, newValue in
            if !hasChanges { draft = newValue }
        }
        .confirmationDialog("Restore the default instructions?", isPresented: $confirmRestore) {
            Button("Restore defaults", role: .destructive) {
                Task {
                    do {
                        try await model.restoreDefaultPrompt()
                        draft = model.promptContent
                        statusMessage = "Default instructions restored as a new version."
                        errorMessage = nil
                    } catch {
                        errorMessage = model.message(for: error)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A new version is created from the bundled AGENT.md. Earlier versions remain in the list.")
        }
        .sheet(item: $preview) { version in
            VStack(spacing: 0) {
                HStack {
                    Text("Version \(version.contentHash.prefix(8))")
                        .font(StudyDesign.headingFont)
                    Spacer()
                    Button("Done") { preview = nil }
                }
                .padding(16)
                Divider()
                ScrollView {
                    Text(version.content)
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
            .frame(minWidth: 640, minHeight: 500)
        }
    }

    private func save(_ content: String? = nil) {
        let value = content ?? draft
        isSaving = true
        errorMessage = nil
        statusMessage = nil
        Task {
            defer { isSaving = false }
            do {
                try await model.savePrompt(value)
                if content != nil { draft = value }
                statusMessage = "Saved. New questions and assessments use this version."
            } catch {
                errorMessage = model.message(for: error)
            }
        }
    }
}

struct DataSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmClear = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudyDesign.spacingL) {
                SectionHeader(
                    title: "Data and privacy",
                    subtitle: "Local-first by design: documents, extracted passages, sessions and assessments stay in this app's container. No account or backend is involved."
                )

                StudyCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Storage location")
                            .font(StudyDesign.headingFont)
                        Text(model.storageLocation)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                        HStack(spacing: 10) {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.storageLocation)])
                            }
                            Button("Delete temporary audio") {
                                model.clearTemporaryAudio()
                                message = "Temporary recordings were deleted."
                            }
                        }
                    }
                }

                StudyCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("What is stored")
                            .font(StudyDesign.headingFont)
                        bullet("Your imported file, a copy of the extracted text with page or paragraph references, topics, sessions, answers and assessments.")
                        bullet("The active AGENT.md and every previous version, in the database and as Markdown files.")
                        bullet("Provider profiles without secrets. API keys live only in the macOS Keychain.")
                        bullet("Speech transcripts as text, with the raw transcript kept for review. Recordings are deleted after transcription.")
                        bullet("No telemetry and no analytics are sent anywhere.")
                    }
                }

                StudyCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("What leaves this Mac")
                            .font(StudyDesign.headingFont)
                        bullet("When a cloud model is active: the passages needed for the current question or assessment, the question, the rubric and your answer.")
                        bullet("When a custom speech endpoint is active: the audio recording.")
                        bullet("Nothing else. Documents are never uploaded in bulk.")
                    }
                }

                StudyCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Delete study data")
                            .font(StudyDesign.headingFont)
                        Text("Removes every imported document copy, extracted passage, topic, session, answer and assessment. Provider profiles, speech profiles and AGENT.md versions are kept. System backups made earlier cannot be recalled by the app.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let message {
                            Label(message, systemImage: "checkmark.circle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Button("Delete all study data…", role: .destructive) { confirmClear = true }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: 780, alignment: .leading)
        }
        .confirmationDialog("Delete all study data?", isPresented: $confirmClear) {
            Button("Delete all documents and history", role: .destructive) {
                Task {
                    await model.clearStudyData()
                    message = "All study data was deleted."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Imported copies, passages, topics, sessions, answers and assessments will be removed. This cannot be undone in the app.")
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
