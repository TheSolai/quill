import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var appState: AppState

    let bgSecondary = Color(hex: "181825")
    let bgPrimary = Color(hex: "1e1e2e")
    let accent = Color(hex: "cba6f7")
    let textPrimary = Color(hex: "cdd6f4")
    let textSecondary = Color(hex: "a6adc8")
    let textMuted = Color(hex: "6c7086")
    let border = Color(hex: "45475a")

    @State private var title: String = ""
    @State private var author: String = ""
    @State private var genre: String = ""
    @State private var dedication: String = ""
    @State private var epigraph: String = ""
    @State private var style: String = ""
    @State private var isSaving: Bool = false
    @State private var saveMessage: String = ""
    @ObservedObject private var slotRegistry = LLMSlotRegistry.shared
    @State private var testingSlotId: String? = nil
    @State private var testResults: [String: String] = [:]  // slotId → "✓ 245ms" / "✗ error"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16))
                    .foregroundColor(accent)
                Text("Project Settings")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(textPrimary)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(bgSecondary)

            Divider().background(border)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    sectionHeader("Book Details")
                    labeledField(label: "Title", placeholder: "My Novel", text: $title)
                    labeledField(label: "Author", placeholder: "Your Name", text: $author)
                    labeledField(label: "Genre", placeholder: "e.g. Fantasy, Sci-Fi, Thriller", text: $genre)

                    Divider().background(border)

                    sectionHeader("Front Matter")
                    labeledField(label: "Dedication", placeholder: "For...", text: $dedication, multiline: true)
                    labeledField(label: "Epigraph", placeholder: "A quote that sets the tone...", text: $epigraph, multiline: true)

                    Divider().background(border)

                    sectionHeader("Writing Style")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Style Notes")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(textSecondary)
                        TextEditor(text: $style)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(textPrimary)
                            .scrollContentBackground(.hidden)
                            .background(bgSecondary)
                            .frame(height: 80)
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(border, lineWidth: 1)
                            )
                        Text("Describe the narrative voice, tone, and stylistic preferences for all generated content.")
                            .font(.system(size: 11))
                            .foregroundColor(textMuted)
                    }

                    Divider().background(border)

                    sectionHeader("AI Provider")
                    Text("Choose which AI engine powers the writing assistant.")
                        .font(.system(size: 11))
                        .foregroundColor(textMuted)
                        .padding(.horizontal, 4)

                    ForEach(LLMRegistry.shared.providerDescriptions, id: \.id) { provider in
                        aiProviderButton(provider: provider)
                    }

                    Text("Apple Intelligence uses your device's built-in AI for privacy-preserving, on-device generation. Ollama and Swift Helper both route to your local Ollama models (gemma4, etc.).")
                        .font(.system(size: 10))
                        .foregroundColor(textMuted)
                        .padding(.horizontal, 4)

                    Divider().background(border)

                    sectionHeader("AI Model Slot")
                    Text("Switch between local models (Ollama, MLX) and cloud models (MiniMax). The active slot powers the AI Assistant and book writer.")
                        .font(.system(size: 11))
                        .foregroundColor(textMuted)
                        .padding(.horizontal, 4)

                    if slotRegistry.isLoading {
                        HStack {
                            ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                            Text("Loading slots…")
                                .font(.system(size: 11))
                                .foregroundColor(textMuted)
                        }
                        .padding(.horizontal, 4)
                    } else if let err = slotRegistry.lastError {
                        Text("⚠️ \(err)")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 4)
                    }

                    ForEach(slotRegistry.slots) { slot in
                        slotButton(slot: slot)
                    }

                    HStack {
                        Button(action: {
                            Task { await slotRegistry.load() }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise").font(.system(size: 10))
                                Text("Refresh slots").font(.system(size: 11))
                            }
                            .foregroundColor(accent)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        if let err = slotRegistry.lastError {
                            Text(err)
                                .font(.system(size: 9))
                                .foregroundColor(.red)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 4)

                    Divider().background(border)

                    sectionHeader("Project")
                    if let project = appState.currentProject {
                        HStack {
                            Text("Location:")
                                .font(.system(size: 12))
                                .foregroundColor(textMuted)
                            Text("~/Projects/Quill/projects/\(project.id)/")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(textSecondary)
                        }
                        HStack {
                            Text("Chapters:")
                                .font(.system(size: 12))
                                .foregroundColor(textMuted)
                            Text("\(appState.chapters.count)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(textSecondary)
                        }
                    } else {
                        Text("No project selected — create or select a project first.")
                            .font(.system(size: 12))
                            .foregroundColor(textMuted)
                    }
                }
                .padding(24)
            }
            .frame(maxHeight: 520)
            .background(bgPrimary)

            Divider().background(border)

            HStack {
                if !saveMessage.isEmpty {
                    Text(saveMessage)
                        .font(.system(size: 12))
                        .foregroundColor(saveMessage.contains("✓") ? Color(hex: "a6e3a1") : Color(hex: "f9e2af"))
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .foregroundColor(textSecondary)
                Button(isSaving ? "Saving..." : "Save Settings") {
                    saveSettings()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(bgSecondary)
        }
        .frame(width: 560, height: 620)
        .background(bgPrimary)
        .onAppear {
            loadSettings()
            Task { await LLMSlotRegistry.shared.load() }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(accent)
            Rectangle()
                .fill(accent.opacity(0.3))
                .frame(height: 1)
        }
    }

    private func labeledField(label: String, placeholder: String, text: Binding<String>, multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(textSecondary)
            if multiline {
                TextEditor(text: text)
                    .font(.system(size: 13))
                    .foregroundColor(textPrimary)
                    .scrollContentBackground(.hidden)
                    .background(bgSecondary)
                    .frame(height: 60)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(border, lineWidth: 1)
                    )
            } else {
                TextField(placeholder, text: text)
                    .font(.system(size: 13))
                    .foregroundColor(textPrimary)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(bgSecondary)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(border, lineWidth: 1)
                    )
            }
        }
    }

    private func aiProviderButton(provider: ProviderDescription) -> some View {
        Button(action: {
            LLMRegistry.shared.selectedProviderId = provider.id
        }) {
            HStack(spacing: 12) {
                Image(systemName: iconForProvider(provider.id))
                    .font(.system(size: 16))
                    .foregroundColor(LLMRegistry.shared.selectedProviderId == provider.id ? accent : textMuted)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(LLMRegistry.shared.selectedProviderId == provider.id ? textPrimary : textSecondary)

                    Text(descriptionForProvider(provider.id))
                        .font(.system(size: 10))
                        .foregroundColor(textMuted)
                }

                Spacer()

                if LLMRegistry.shared.selectedProviderId == provider.id {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(accent)
                } else {
                    Image(systemName: "circle")
                        .font(.system(size: 14))
                        .foregroundColor(textMuted)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(LLMRegistry.shared.selectedProviderId == provider.id ? accent.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(LLMRegistry.shared.selectedProviderId == provider.id ? accent.opacity(0.4) : border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// Renders one slot row with type icon, name, model id, and a test button.
    private func slotButton(slot: LLMSlot) -> some View {
        let isActive = slotRegistry.activeSlotId == slot.id
        return Button(action: {
            Task { await slotRegistry.setActive(slot.id) }
        }) {
            HStack(spacing: 12) {
                Image(systemName: iconForSlot(slot.type))
                    .font(.system(size: 16))
                    .foregroundColor(isActive ? accent : textMuted)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(slot.name)
                            .font(.system(size: 13, weight: isActive ? .bold : .medium))
                            .foregroundColor(isActive ? textPrimary : textSecondary)
                        if slot.isDefault {
                            Text("DEFAULT")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(accent.opacity(0.2))
                                .foregroundColor(accent)
                                .cornerRadius(3)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(slot.modelId)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(textMuted)
                        Text("·")
                            .font(.system(size: 10))
                            .foregroundColor(textMuted)
                        Text(slot.type)
                            .font(.system(size: 10))
                            .foregroundColor(textMuted)
                        if let purpose = slot.purpose, purpose != "general" {
                            Text("·")
                                .font(.system(size: 10))
                                .foregroundColor(textMuted)
                            Text(purpose)
                                .font(.system(size: 10))
                                .foregroundColor(textMuted)
                        }
                    }
                    if let meta = slot.metadata?["notes"]?.value as? String, !meta.isEmpty {
                        Text(meta)
                            .font(.system(size: 9))
                            .foregroundColor(textMuted)
                            .lineLimit(1)
                    }
                    if let result = testResults[slot.id] {
                        Text(result)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(result.hasPrefix("✓") ? .green : .red)
                    }
                }

                Spacer()

                if testingSlotId == slot.id {
                    ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
                } else {
                    Button(action: {
                        Task {
                            testingSlotId = slot.id
                            let r = await slotRegistry.test(slot.id)
                            testResults[slot.id] = r.ok
                                ? "✓ \(Int(r.latencyMs))ms"
                                : "✗ \(r.error ?? "fail")"
                            testingSlotId = nil
                        }
                    }) {
                        Image(systemName: "bolt")
                            .font(.system(size: 11))
                            .foregroundColor(textMuted)
                    }
                    .buttonStyle(.plain)
                }

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(accent)
                } else {
                    Image(systemName: "circle")
                        .font(.system(size: 14))
                        .foregroundColor(textMuted)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? accent.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive ? accent.opacity(0.4) : border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func iconForSlot(_ type: String) -> String {
        switch type {
        case "ollama": return "server.rack"
        case "mlx": return "cpu"
        case "minimax": return "cloud"
        case "lmstudio": return "desktopcomputer"
        case "custom": return "wrench.and.screwdriver"
        default: return "questionmark.circle"
        }
    }

    private func iconForProvider(_ id: String) -> String {
        switch id {
        case "apple_intelligence": return "apple.logo"
        case "ollama": return "cpu"
        case "swift": return "swift"
        default: return "questionmark.circle"
        }
    }

    private func descriptionForProvider(_ id: String) -> String {
        switch id {
        case "apple_intelligence": return "Apple Intelligence — on-device, privacy-preserving AI"
        case "ollama": return "Direct Ollama via HTTP — fast, local"
        case "swift": return "Swift CLI bridge to Ollama — Swift-native path"
        default: return "Unknown provider"
        }
    }

    private func loadSettings() {
        guard let project = appState.currentProject else { return }
        Task {
            do {
                let settings: ProjectSettings = try await BackendService.shared.get(
                    "/api/projects/\(project.id)/settings"
                )
                title = settings.title
                author = settings.author
                genre = settings.genre
                dedication = settings.dedication
                epigraph = settings.epigraph
                style = settings.style
            } catch {
                print("Failed to load settings: \(error)")
            }
        }
    }

    private func saveSettings() {
        guard let project = appState.currentProject else { return }
        isSaving = true
        saveMessage = ""
        Task {
            do {
                try await BackendService.shared.put(
                    "/api/projects/\(project.id)/settings",
                    body: [
                        "title": title,
                        "author": author,
                        "genre": genre,
                        "dedication": dedication,
                        "epigraph": epigraph,
                        "style": style
                    ]
                )
                saveMessage = "✓ Settings saved"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    saveMessage = ""
                }
            } catch {
                saveMessage = "Failed to save: \(error.localizedDescription)"
            }
            isSaving = false
        }
    }
}
