import SwiftUI
import AVFoundation
import UIKit
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var selectedVoicePickerID = HostedServiceConfig.defaultElevenLabsVoiceID
    @State private var customVoiceID = ""
    @State private var selectedOpenAITTSVoice = HostedServiceConfig.defaultOpenAITTSVoice
    @State private var previewPlayer: AVAudioPlayer?
    @State private var previewError: String?
    @State private var selectedLanguageID = HostedServiceConfig.deviceLanguageID
    @State private var showAICaption = false
    @State private var isLoadingSettings = false
    @State private var selectedAIProviderID = AIProvider.gemini.rawValue
    @State private var selectedAIModel = AIProvider.gemini.defaultModel
    @State private var aiModelIsCustom = false
    @State private var aiAPIKey = ""
    @State private var hasSavedAIAPIKey = false
    @State private var ollamaURL = OllamaConfig.defaultURL
    @State private var aiSettingsMessage: String?
    @State private var selectedSTTBackendID = STTBackend.nativeIOS.rawValue
    @State private var selectedSTTModel = STTBackend.nativeIOS.defaultModel
    @State private var sttModelIsCustom = false
    @State private var sttAPIKey = ""
    @State private var hasSavedSTTAPIKey = false
    @State private var sttSettingsMessage: String?
    @State private var selectedTTSBackendID = TTSBackend.elevenLabs.rawValue
    @State private var selectedTTSModel = TTSBackend.elevenLabs.defaultModel
    @State private var ttsModelIsCustom = false
    @State private var ttsAPIKey = ""
    @State private var hasSavedTTSAPIKey = false
    @State private var ttsSettingsMessage: String?
    @State private var customTTSVoice = ""
    @State private var ttsEndpoint = ""

    // MARK: - Secret visibility
    @State private var revealAIKey = false
    @State private var revealSTTKey = false
    @State private var revealTTSKey = false

    // MARK: - Character Settings
    @State private var hasCharacterChanges = false
    @State private var characterName: String = ""
    @State private var selectedAvatar: String = "AvatarSample_A"
    @State private var systemPrompt: String = ""
    @State private var savedCharacterName: String = ""
    @State private var savedSystemPrompt: String = ""

    // MARK: - Scene & Camera Settings
    @State private var selectedBackgroundID: String = ""
    @State private var subjectOffset: Double = 0
    @State private var zoomMax: Double = AmicaViewerBridge.defaultZoomMax

    // MARK: - User media (backgrounds / avatars)
    @State private var backgroundPhotoItem: PhotosPickerItem?
    @State private var isPickingBackgroundPhoto = false
    @State private var importedAvatars: [AmicaImportedAvatar] = []

    // MARK: - Focus timer
    @State private var focusTimerEnabled = true
    @State private var focusTimerModeID = FocusTimerMode.countdown.rawValue
    @State private var focusMinutes = 25
    @State private var restMinutes = 5
    @State private var focusAutoRest = true
    @State private var focusChime = true

    // MARK: - Ambience & music
    @State private var importedMusic: [AmicaMediaFile] = []
    @State private var isImportingMusic = false
    @State private var ambienceMessage: String?
    /// Mirrors of the player's state. Views bind to these rather than to the
    /// player directly, because a Picker may apply its selection while the view
    /// is still being built — writing to observed state at that point is not
    /// allowed and takes the app down.
    @State private var selectedAmbientTrackID = ""
    @State private var ambientVolume: Double = 0.5
    @State private var musicLevel: Double = 0.6
    private var ambience: AmbienceAudio { .shared }
    private var focusTimer: FocusTimer { .shared }
    @State private var isImportingAvatar = false
    @State private var mediaMessage: String?
    @State private var mediaMessageIsError = false

    var showsDismissControls = true

    private static let defaultSystemPrompt = "You are a warm, cheerful, and expressive AI companion. You're friendly, playful, and genuinely care about the person you're talking to. You speak naturally and conversationally — like a close friend. Keep responses concise (1-3 sentences). Be expressive and show personality."

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    settingsSection(
                        "Conversation",
                        icon: "bubble.left.and.bubble.right",
                        footer: "Language helps supported speech providers choose transcription and voice output language. Captions control the assistant's spoken response overlay."
                    ) {
                        settingRow {
                            Picker("Language", selection: $selectedLanguageID) {
                                Text(
                                    String.localizedStringWithFormat(
                                        NSLocalizedString("iPhone Language (%@)", comment: "Device language picker option"),
                                        HostedServiceConfig.currentDeviceLanguageName()
                                    )
                                )
                                    .tag(HostedServiceConfig.deviceLanguageID)
                                ForEach(ScowldLanguageLibrary.options) { language in
                                    Text(LocalizedStringKey(language.name)).tag(language.code)
                                }
                            }
                            .pickerStyle(.menu)
                            .onChange(of: selectedLanguageID) {
                                guard !isLoadingSettings else { return }
                                saveLanguageSettings()
                            }
                        }

                        if let selectedLanguageDescription {
                            settingsInfoRow(
                                title: selectedLanguageDescription,
                                systemImage: "globe"
                            )
                        }

                        settingRow {
                            Toggle("Show AI captions", isOn: $showAICaption)
                                .tint(.amicaBlue)
                                .onChange(of: showAICaption) {
                                    guard !isLoadingSettings else { return }
                                    saveDisplaySettings()
                                }
                        }
                    }

                    focusTimerSection

                    ambienceSection

                    aiProviderSection
                    sttProviderSection

                    settingsSection(
                        "Text-to-Speech",
                        icon: "speaker.wave.3",
                        footer: ttsSectionFooter
                    ) {
                        settingRow {
                            Picker("Provider", selection: $selectedTTSBackendID) {
                                ForEach(TTSBackend.allCases, id: \.rawValue) { backend in
                                    Text(backend.displayName).tag(backend.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .onChange(of: selectedTTSBackendID) {
                                guard !isLoadingSettings else { return }
                                loadTTSBackendSettings()
                            }
                        }

                        modelSelectionRows(
                            models: selectedTTSBackend.availableModels,
                            selection: $selectedTTSModel,
                            isCustom: $ttsModelIsCustom
                        )

                        settingRow {
                            apiKeyField(placeholder: ttsAPIKeyPlaceholder, text: $ttsAPIKey, isRevealed: $revealTTSKey)
                        }

                        if selectedTTSBackend == .elevenLabs {
                            settingRow {
                                Picker("Voice", selection: $selectedVoicePickerID) {
                                    ForEach(ScowldVoiceLibrary.presetVoices) { voice in
                                        Text(LocalizedStringKey(voice.name)).tag(voice.voiceID)
                                    }
                                    Text("Custom Voice ID").tag(ScowldVoiceLibrary.customID)
                                }
                                .pickerStyle(.menu)
                                .onChange(of: selectedVoicePickerID) {
                                    guard !isLoadingSettings else { return }
                                    saveSelectedVoice()
                                    resetPreviewState()
                                }
                            }

                            if selectedVoicePickerID == ScowldVoiceLibrary.customID {
                                settingRow {
                                    TextField("ElevenLabs Voice ID", text: $customVoiceID)
                                        .autocorrectionDisabled()
                                        .textInputAutocapitalization(.never)
                                        .onChange(of: customVoiceID) {
                                            guard !isLoadingSettings else { return }
                                            saveSelectedVoice()
                                            resetPreviewState()
                                        }
                                }

                                settingsActionRow(
                                    title: "Where to get a custom voice ID",
                                    subtitle: "elevenlabs.io/app/voice-library",
                                    systemImage: "info.circle"
                                ) {
                                    openURL(URL(string: "https://elevenlabs.io/app/voice-library")!)
                                }
                            } else if let voice = ScowldVoiceLibrary.option(for: selectedVoicePickerID) {
                                settingRow {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(LocalizedStringKey(voice.description))
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                        Text(voice.voiceID)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.tertiary)
                                            .textSelection(.enabled)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }

                            settingsActionRow(
                                title: previewButtonTitle,
                                subtitle: selectedVoiceHasBundledPreview ? "Plays a bundled local sample" : nil,
                                systemImage: previewButtonIcon,
                                isDisabled: !selectedVoiceHasBundledPreview
                            ) {
                                playBundledVoicePreview()
                            }

                            if let previewError {
                                settingsInfoRow(title: previewError, systemImage: "exclamationmark.triangle.fill", color: .red)
                            }

                            settingsInfoRow(
                                title: "Preset samples are bundled in the app and play locally from this device.",
                                systemImage: "speaker.wave.2.fill"
                            )
                        } else if selectedTTSBackend == .openAI {
                            settingRow {
                                Picker("Voice", selection: $selectedOpenAITTSVoice) {
                                    ForEach(TTSBackend.openAI.voiceOptions, id: \.self) { voice in
                                        Text(voice.capitalized).tag(voice)
                                    }
                                }
                                .pickerStyle(.menu)
                                .onChange(of: selectedOpenAITTSVoice) {
                                    guard !isLoadingSettings else { return }
                                    saveOpenAITTSVoice()
                                }
                            }

                            settingsInfoRow(
                                title: "OpenAI voices use your OpenAI API key. There's no local preview.",
                                systemImage: "info.circle"
                            )
                        } else if selectedTTSBackend.usesCustomVoiceField {
                            settingRow {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Voice ID")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    TextField(ttsVoicePlaceholder, text: $customTTSVoice)
                                        .autocorrectionDisabled()
                                        .textInputAutocapitalization(.never)
                                }
                            }

                            if selectedTTSBackend.usesEndpointField {
                                settingRow {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("API endpoint")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        TextField(selectedTTSBackend.defaultEndpoint, text: $ttsEndpoint)
                                            .autocorrectionDisabled()
                                            .textInputAutocapitalization(.never)
                                            .font(.footnote.monospaced())
                                    }
                                }
                            }

                            if selectedTTSBackend == .doubao {
                                settingsInfoRow(
                                    title: "API key must be entered as appid:access_token — both from the Volcano Engine speech console.",
                                    systemImage: "key.horizontal"
                                )
                            }

                            settingsInfoRow(
                                title: selectedTTSBackend.providerHint,
                                systemImage: "antenna.radiowaves.left.and.right"
                            )
                        }

                        glassSaveRow(status: ttsSettingsMessage ?? ttsSaveSubtitle) {
                            saveTTSSettings()
                        }
                    }

                    settingsSection(
                        "Character",
                        icon: "person.fill",
                        footer: "Avatar saves immediately. Use Save Character after changing the custom name or system prompt."
                    ) {
                        settingRow {
                            Picker("Avatar", selection: $selectedAvatar) {
                                ForEach(CharacterPack.defaultPacks) { pack in
                                    Text(pack.displayName).tag(pack.fileName)
                                }
                                ForEach(importedAvatars) { avatar in
                                    Text("\(avatar.displayName) (imported)").tag(avatar.publicPath)
                                }
                            }
                            .pickerStyle(.menu)
                            .onChange(of: selectedAvatar) {
                                guard !isLoadingSettings else { return }
                                saveAvatarSettings()
                            }
                        }

                        settingsActionRow(
                            title: "Import a VRM model",
                            subtitle: "Use your own character from a .vrm file",
                            systemImage: "square.and.arrow.down"
                        ) {
                            isImportingAvatar = true
                        }

                        ForEach(importedAvatars) { avatar in
                            settingRow {
                                HStack(spacing: 10) {
                                    Image(systemName: "person.crop.square")
                                        .font(.system(size: 18))
                                        .foregroundStyle(.secondary)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(avatar.displayName)
                                            .lineLimit(1)
                                        Text(avatar.sizeLabel)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Button {
                                        deleteImportedAvatar(avatar)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Delete \(avatar.displayName)")
                                }
                            }
                        }

                        if let mediaMessage {
                            settingsInfoRow(
                                title: mediaMessage,
                                systemImage: mediaMessageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                                color: mediaMessageIsError ? .red : .secondary
                            )
                        }

                        settingRow {
                            HStack(spacing: 8) {
                                TextField("Bella", text: $characterName)
                                    .autocorrectionDisabled()
                                    .onChange(of: characterName) { markCharacterChanged() }

                                if !characterName.isEmpty {
                                    Button {
                                        characterName = ""
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Clear custom name")
                                }
                            }
                        }

                        settingRow {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("System Prompt")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ZStack(alignment: .topLeading) {
                                    if systemPrompt.isEmpty {
                                        Text(Self.defaultSystemPrompt)
                                            .font(.body)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 8)
                                            .allowsHitTesting(false)
                                    }
                                    TextEditor(text: $systemPrompt)
                                        .frame(minHeight: 112)
                                        .font(.body)
                                        .scrollContentBackground(.hidden)
                                        .onChange(of: systemPrompt) { markCharacterChanged() }
                                }
                                .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }

                        HStack(spacing: 12) {
                            Button {
                                clearCharacterDefaults()
                            } label: {
                                Label("Clear", systemImage: "arrow.counterclockwise")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(canClearCharacter ? Color.red : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(!canClearCharacter)
                            .accessibilityLabel("Clear custom name and system prompt")

                            Spacer()

                            Button {
                                saveCharacterSettings()
                            } label: {
                                Label("Save Character", systemImage: "checkmark.circle.fill")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(hasCharacterChanges ? Color.amicaBlue : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(!hasCharacterChanges)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }

                    sceneSection

                }
                .padding(20)
                .padding(.bottom, 96)
            }
            .background(Color.black.ignoresSafeArea())
            .photosPicker(
                isPresented: $isPickingBackgroundPhoto,
                selection: $backgroundPhotoItem,
                matching: .images
            )
            .fileImporter(
                isPresented: $isImportingAvatar,
                allowedContentTypes: [UTType(filenameExtension: "vrm") ?? .data],
                allowsMultipleSelection: false
            ) { result in
                handleAvatarImport(result)
            }
            .fileImporter(
                isPresented: $isImportingMusic,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: true
            ) { result in
                handleMusicImport(result)
            }
            .onChange(of: backgroundPhotoItem) {
                handleBackgroundPhoto()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .background(KeyboardDismissInstaller())
            .toolbar {
                if showsDismissControls {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
            }
        }
        .onAppear {
            CrashCatcher.breadcrumb("settings: view appeared")
            loadSettings()
        }
    }

    private var aiProviderSection: some View {
        settingsSection(
            "BYOK AI",
            icon: "brain.head.profile",
            footer: "Scowld sends chat and optional vision requests directly to your selected provider using the key saved in Keychain."
        ) {
            settingRow {
                Picker("Provider", selection: $selectedAIProviderID) {
                    ForEach(AIProvider.allCases, id: \.rawValue) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedAIProviderID) {
                    guard !isLoadingSettings else { return }
                    loadAIProviderSettings()
                }
            }

            if selectedAIProvider == .ollama {
                settingRow {
                    TextField("Ollama URL", text: $ollamaURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            modelSelectionRows(
                models: selectedAIProvider.availableModels,
                selection: $selectedAIModel,
                isCustom: $aiModelIsCustom
            )

            if selectedAIProvider.requiresAPIKey {
                settingRow {
                    apiKeyField(placeholder: aiAPIKeyPlaceholder, text: $aiAPIKey, isRevealed: $revealAIKey)
                }
            }

            glassSaveRow(status: aiSettingsMessage ?? aiSaveSubtitle) {
                saveAISettings()
            }
        }
    }

    private var sttProviderSection: some View {
        settingsSection(
            "Speech-to-Text",
            icon: "waveform.badge.mic",
            footer: "Native iOS uses no API key. Cloud STT providers use your API key from Keychain."
        ) {
            settingRow {
                Picker("Provider", selection: $selectedSTTBackendID) {
                    ForEach(STTBackend.allCases, id: \.rawValue) { backend in
                        Text(backend.displayName).tag(backend.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedSTTBackendID) {
                    guard !isLoadingSettings else { return }
                    loadSTTBackendSettings()
                }
            }

            if !selectedSTTBackend.availableModels.isEmpty {
                modelSelectionRows(
                    models: selectedSTTBackend.availableModels,
                    selection: $selectedSTTModel,
                    isCustom: $sttModelIsCustom
                )
            }

            if selectedSTTBackend.requiresAPIKey {
                settingRow {
                    apiKeyField(placeholder: sttAPIKeyPlaceholder, text: $sttAPIKey, isRevealed: $revealSTTKey)
                }
            }

            settingsInfoRow(title: selectedSTTBackend.footerText, systemImage: "info.circle")

            glassSaveRow(status: sttSettingsMessage ?? sttSaveSubtitle) {
                saveSTTSettings()
            }
        }
    }

    // MARK: - Scene & camera

    /// Placeholder for the free-form voice field, per provider.
    private var ttsVoicePlaceholder: String {
        switch selectedTTSBackend {
        case .doubao: "zh_female_qingxin"
        case .minimax: "female-shaonv"
        case .fishAudio: "Reference ID from fish.audio"
        default: "Voice ID"
        }
    }

    private var sceneSection: some View {
        settingsSection(
            "Scene & Camera",
            icon: "camera.viewfinder",
            footer: "Backgrounds ship inside the app. Pinch the 3D view to zoom and drag to orbit; use the sparkles button on the home screen for actions and expressions."
        ) {
            settingRow {
                Picker("Background", selection: $selectedBackgroundID) {
                    Text(AmicaBackground.defaultPreset.title).tag("")
                    ForEach(AmicaBackground.presets) { background in
                        Text(background.title).tag(background.id)
                    }
                    if selectedBackgroundID.hasPrefix("/") {
                        Text("Your photo").tag(selectedBackgroundID)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedBackgroundID) {
                    guard !isLoadingSettings else { return }
                    AmicaSceneSettings.setBackground(id: selectedBackgroundID)
                    notifySceneChanged()
                }
            }

            settingsActionRow(
                title: "Choose a photo…",
                subtitle: "Use any image from your photo library",
                systemImage: "photo.on.rectangle"
            ) {
                isPickingBackgroundPhoto = true
            }

            settingRow {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Character position")
                        Spacer()
                        Text(characterOffsetLabel)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $subjectOffset, in: -0.6...0.6, step: 0.05)
                        .onChange(of: subjectOffset) {
                            guard !isLoadingSettings else { return }
                            AmicaSceneSettings.setSubjectOffset(subjectOffset)
                            notifySceneChanged()
                        }
                }
            }

            settingRow {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Maximum zoom out")
                        Spacer()
                        Text(String(format: "%.1f×", zoomMax))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $zoomMax, in: 2...12, step: 0.5)
                        .onChange(of: zoomMax) {
                            guard !isLoadingSettings else { return }
                            AmicaSceneSettings.setZoomMax(zoomMax)
                            notifySceneChanged()
                        }
                }
            }

            settingsInfoRow(
                title: "Move the slider right to push the character towards the right of the screen — useful for making room for other panels.",
                systemImage: "arrow.left.and.right"
            )
        }
    }

    private var characterOffsetLabel: String {
        if abs(subjectOffset) < 0.001 { return "Centred" }
        return String(format: "%@ %.2f", subjectOffset > 0 ? "Right" : "Left", abs(subjectOffset))
    }

    /// Pushes scene changes to the running 3D viewer.
    private func notifySceneChanged() {
        NotificationCenter.default.post(name: .amicaSettingsChanged, object: nil)
    }

    // MARK: - User media

    private func reloadImportedAvatars() {
        importedAvatars = AmicaUserMedia.importedAvatars()
    }

    private func handleAvatarImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let source = urls.first else { return }
            if let publicPath = AmicaUserMedia.importAvatar(from: source) {
                reloadImportedAvatars()
                selectedAvatar = publicPath
                saveAvatarSettings()
                showMediaMessage("Imported \(source.lastPathComponent)", isError: false)
            } else {
                showMediaMessage("Could not import that file", isError: true)
            }
        case .failure(let error):
            showMediaMessage("Import failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func deleteImportedAvatar(_ avatar: AmicaImportedAvatar) {
        AmicaUserMedia.deleteAvatar(fileName: avatar.fileName)
        if selectedAvatar == avatar.publicPath {
            selectedAvatar = CharacterPack.defaultPacks[0].fileName
            saveAvatarSettings()
        }
        reloadImportedAvatars()
        showMediaMessage("Deleted \(avatar.displayName)", isError: false)
    }

    private func handleBackgroundPhoto() {
        guard let item = backgroundPhotoItem else { return }
        backgroundPhotoItem = nil
        Task { @MainActor in
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data),
                      let publicPath = AmicaUserMedia.saveBackgroundImage(image) else {
                    showMediaMessage("Could not read that photo", isError: true)
                    return
                }
                selectedBackgroundID = publicPath
                AmicaSceneSettings.setBackground(id: publicPath)
                notifySceneChanged()
                showMediaMessage("Background updated", isError: false)
            } catch {
                showMediaMessage("Could not read that photo", isError: true)
            }
        }
    }

    private func showMediaMessage(_ text: String, isError: Bool) {
        mediaMessage = text
        mediaMessageIsError = isError
    }

    /// API-key entry with an eye toggle to reveal/hide the secret.
    @ViewBuilder
    private func apiKeyField(
        placeholder: String,
        text: Binding<String>,
        isRevealed: Binding<Bool>
    ) -> some View {
        Group {
            if isRevealed.wrappedValue {
                TextField(placeholder, text: text)
            } else {
                SecureField(placeholder, text: text)
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .frame(maxWidth: .infinity, alignment: .leading)

        Button {
            isRevealed.wrappedValue.toggle()
        } label: {
            Image(systemName: isRevealed.wrappedValue ? "eye.slash.fill" : "eye.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isRevealed.wrappedValue ? .amicaBlue : .secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRevealed.wrappedValue ? "Hide key" : "Show key")
    }

    /// Footer row: optional status text on the left, Liquid Glass Save button on the right.
    private func glassSaveRow(
        status: String?,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
            liquidGlassSaveButton(isDisabled: isDisabled, action: action)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }

    @ViewBuilder
    private func liquidGlassSaveButton(
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if #available(iOS 26.0, *) {
            Button(action: action) {
                Label("Save", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.glassProminent)
            .tint(.amicaBlue)
            .disabled(isDisabled)
        } else {
            Button(action: action) {
                Label("Save", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [.amicaBlue, .amicaBlue.opacity(0.7)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    )
                    .overlay(
                        Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.8)
                    )
                    .shadow(color: .amicaBlue.opacity(0.4), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.5 : 1)
        }
    }

    private static let customModelTag = "__scowld_custom_model__"

    /// Single model row: a menu picker of preset models plus a "Custom model" option.
    /// The editable text field only appears when "Custom model" is selected, so the
    /// model name is never shown twice.
    @ViewBuilder
    private func modelSelectionRows(
        models: [String],
        selection: Binding<String>,
        isCustom: Binding<Bool>
    ) -> some View {
        settingRow {
            Picker("Model", selection: Binding(
                get: { isCustom.wrappedValue ? Self.customModelTag : selection.wrappedValue },
                set: { newValue in
                    if newValue == Self.customModelTag {
                        isCustom.wrappedValue = true
                    } else {
                        isCustom.wrappedValue = false
                        selection.wrappedValue = newValue
                    }
                }
            )) {
                ForEach(models, id: \.self) { model in
                    Text(model).tag(model)
                }
                Text("Custom model").tag(Self.customModelTag)
            }
            .pickerStyle(.menu)
        }

        if isCustom.wrappedValue {
            settingRow {
                TextField("Custom model name", text: selection)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
    }

    private func labeledValue(_ label: String, value: String) -> some View {
        settingRow {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Focus timer

    /// The focus session has no controls on the scene itself; everything is here.
    private var focusTimerSection: some View {
        CrashCatcher.breadcrumb("build: focusTimerSection")
        return settingsSection(
            "Focus Timer",
            icon: "timer",
            footer: "Turning the device to landscape starts a session automatically; portrait hides the timer but it keeps running. A plain local notification alerts you when a countdown ends."
        ) {
            settingRow {
                Toggle("Enable focus timer", isOn: $focusTimerEnabled)
                    .tint(.amicaBlue)
                    .onChange(of: focusTimerEnabled) {
                        guard !isLoadingSettings else { return }
                        saveFocusTimerSettings()
                    }
            }

            settingRow {
                Picker("Mode", selection: $focusTimerModeID) {
                    ForEach(FocusTimerMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.title)).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: focusTimerModeID) {
                    guard !isLoadingSettings else { return }
                    saveFocusTimerSettings()
                }
            }

            if let mode = FocusTimerMode(rawValue: focusTimerModeID) {
                settingsInfoRow(title: mode.explanation, systemImage: "info.circle")
            }

            if FocusTimerMode(rawValue: focusTimerModeID) == .countdown {
                settingRow {
                    Picker("Focus", selection: $focusMinutes) {
                        ForEach(FocusTimerSettings.focusLengthOptions, id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: focusMinutes) {
                        guard !isLoadingSettings else { return }
                        saveFocusTimerSettings()
                    }
                }

                settingRow {
                    Picker("Break", selection: $restMinutes) {
                        ForEach(FocusTimerSettings.restLengthOptions, id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: restMinutes) {
                        guard !isLoadingSettings else { return }
                        saveFocusTimerSettings()
                    }
                }

                settingRow {
                    Toggle("Start the break automatically", isOn: $focusAutoRest)
                        .tint(.amicaBlue)
                        .onChange(of: focusAutoRest) {
                            guard !isLoadingSettings else { return }
                            saveFocusTimerSettings()
                        }
                }
            }

            settingRow {
                Toggle("Chime when a session ends", isOn: $focusChime)
                    .tint(.amicaBlue)
                    .onChange(of: focusChime) {
                        guard !isLoadingSettings else { return }
                        saveFocusTimerSettings()
                    }
            }

            if focusTimer.isRunning {
                settingsInfoRow(
                    title: "\(focusTimer.phase.title) · \(focusTimer.displayText)",
                    systemImage: "hourglass"
                )

                settingsActionRow(
                    title: "End this session",
                    subtitle: "Stops the timer and clears the countdown",
                    systemImage: "stop.circle"
                ) {
                    focusTimer.stop()
                }
            }
        }
    }

    // MARK: - Ambience & music

    private var ambienceSection: some View {
        CrashCatcher.breadcrumb("build: ambienceSection")
        return settingsSection(
            "Ambience & Music",
            icon: "waveform",
            footer: "Ambience and music are independent: play either one, or both together. Ambient loops ship with the app; music files are yours."
        ) {
            settingRow {
                Picker("Ambience", selection: $selectedAmbientTrackID) {
                    Text("Off").tag("")
                    ForEach(AmbientTrack.allCases) { track in
                        Label(LocalizedStringKey(track.title), systemImage: track.systemImage).tag(track.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedAmbientTrackID) {
                    guard !isLoadingSettings else { return }
                    ambience.play(AmbientTrack(rawValue: selectedAmbientTrackID))
                }
            }

            settingRow {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.1.fill")
                        .foregroundStyle(.secondary)
                    Slider(value: $ambientVolume, in: 0...1)
                        .onChange(of: ambientVolume) {
                            ambience.noiseVolume = ambientVolume
                        }
                }
            }

            Divider().opacity(0.25)

            if importedMusic.isEmpty {
                settingsInfoRow(
                    title: "No music yet. Add your own files and they play here, separately from the ambience.",
                    systemImage: "music.note.list"
                )
            } else {
                settingRow {
                    HStack(spacing: 10) {
                        Button {
                            ambience.toggleMusicPlayback()
                        } label: {
                            Image(systemName: ambience.isMusicPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(.amicaBlue)
                        }
                        .buttonStyle(.plain)

                        Text(ambience.currentTrack?.displayName ?? "Nothing playing")
                            .lineLimit(1)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 0)

                        Button { ambience.previousTrack() } label: {
                            Image(systemName: "backward.fill")
                        }
                        .buttonStyle(.plain)

                        Button { ambience.nextTrack() } label: {
                            Image(systemName: "forward.fill")
                        }
                        .buttonStyle(.plain)
                    }
                }

                settingRow {
                    HStack(spacing: 10) {
                        Image(systemName: "speaker.wave.1.fill")
                            .foregroundStyle(.secondary)
                        Slider(value: $musicLevel, in: 0...1)
                            .onChange(of: musicLevel) {
                                ambience.musicVolume = musicLevel
                            }
                    }
                }

                ForEach(importedMusic) { file in
                    settingRow {
                        HStack(spacing: 10) {
                            Image(systemName: "music.note")
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.displayName)
                                    .lineLimit(1)
                                Text(file.sizeLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 0)

                            Button {
                                ambience.playMusic(file)
                            } label: {
                                Image(systemName: "play.fill")
                            }
                            .buttonStyle(.plain)

                            Button(role: .destructive) {
                                deleteMusic(file)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            settingsActionRow(
                title: "Add music…",
                subtitle: "Pick audio files from your device",
                systemImage: "plus.circle"
            ) {
                isImportingMusic = true
            }

            if let ambienceMessage {
                settingsInfoRow(title: ambienceMessage, systemImage: "info.circle")
            }
        }
    }

    private func settingsSection<Content: View>(
        _ title: String,
        icon: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(spacing: 0) {
                content()
            }
            .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func settingRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            settingsRowDivider
        }
    }

    private func settingsActionRow(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        tint: Color = .primary,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.08), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(tint)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                settingsRowDivider
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.72 : 1)
    }

    private func settingsInfoRow(
        title: String,
        systemImage: String,
        color: Color = .secondary
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.08), in: Circle())

            Text(title)
                .font(.caption)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            settingsRowDivider
        }
    }

    private var settingsRowDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(height: 0.5)
            .padding(.leading, 62)
    }

    private var selectedPreviewVoiceID: String {
        ScowldVoiceLibrary.voiceID(for: selectedVoicePickerID, customVoiceID: customVoiceID)
    }

    private var previewButtonTitle: String {
        selectedVoiceHasBundledPreview
            ? NSLocalizedString("Play sample", comment: "Play voice preview button")
            : NSLocalizedString("Sample unavailable", comment: "Disabled voice preview button")
    }

    private var previewButtonIcon: String {
        selectedVoiceHasBundledPreview ? "play.circle.fill" : "exclamationmark.circle"
    }

    private var selectedVoiceHasBundledPreview: Bool {
        BundledElevenLabsVoicePreviews.hasPreview(forVoiceID: selectedPreviewVoiceID)
    }

    private var selectedLanguageDescription: String? {
        switch selectedLanguageID {
        case HostedServiceConfig.deviceLanguageID:
            if let code = HostedServiceConfig.currentDeviceLanguageCode(),
               let language = ScowldLanguageLibrary.option(for: code) {
                return String.localizedStringWithFormat(
                    NSLocalizedString("Uses this iPhone's current language when supported: %@.", comment: "Device language mode description"),
                    NSLocalizedString(language.name, comment: "Language name")
                )
            }
            return NSLocalizedString(
                "This iPhone language is not in the supported shortcut list, so providers will use auto.",
                comment: "Unsupported device language description"
            )
        default:
            return ScowldLanguageLibrary.option(for: selectedLanguageID).map {
                String.localizedStringWithFormat(
                    NSLocalizedString("Forces STT and TTS toward %@.", comment: "Selected service language description"),
                    NSLocalizedString($0.name, comment: "Language name")
                )
            }
        }
    }

    private var selectedAIProvider: AIProvider {
        AIProvider(rawValue: selectedAIProviderID) ?? .gemini
    }

    private var selectedSTTBackend: STTBackend {
        STTBackend(rawValue: selectedSTTBackendID) ?? .nativeIOS
    }

    private var selectedTTSBackend: TTSBackend {
        TTSBackend(rawValue: selectedTTSBackendID) ?? .elevenLabs
    }

    private var aiAPIKeyPlaceholder: String {
        hasSavedAIAPIKey ? "Saved API key - type to replace" : "\(selectedAIProvider.displayName) API key"
    }

    private var sttAPIKeyPlaceholder: String {
        hasSavedSTTAPIKey ? "Saved API key - type to replace" : "\(selectedSTTBackend.displayName) API key"
    }

    private var ttsAPIKeyPlaceholder: String {
        hasSavedTTSAPIKey ? "Saved API key - type to replace" : "\(selectedTTSBackend.displayName) API key"
    }

    private var ttsSectionFooter: String {
        switch selectedTTSBackend {
        case .elevenLabs:
            return "ElevenLabs speech uses your API key from Keychain. Celine, Claire, and custom voice IDs are supported."
        case .openAI:
            return "OpenAI text-to-speech reuses your OpenAI API key from Keychain and its built-in voices."
        case .doubao:
            return "Doubao speech is called through the app's local proxy, so the key never reaches the web view."
        case .minimax:
            return "MiniMax speech is called through the app's local proxy, so the key never reaches the web view."
        case .fishAudio:
            return "Fish Audio speech is called through the app's local proxy, so the key never reaches the web view."
        }
    }

    private var aiSaveSubtitle: String {
        selectedAIProvider.requiresAPIKey
            ? (hasSavedAIAPIKey ? "Key saved in Keychain" : "Add a key before chatting")
            : "No API key required"
    }

    private var sttSaveSubtitle: String {
        selectedSTTBackend.requiresAPIKey
            ? (hasSavedSTTAPIKey ? "Key saved in Keychain" : "Add a key for cloud STT")
            : "No API key required"
    }

    private var ttsSaveSubtitle: String {
        hasSavedTTSAPIKey ? "Key saved in Keychain" : "Add a key for spoken replies"
    }

    // MARK: - Settings Persistence

    private func loadSettings() {
        CrashCatcher.breadcrumb("loadSettings: start")
        isLoadingSettings = true
        HostedServiceConfig.applyBYOKDefaults()
        CrashCatcher.breadcrumb("loadSettings: after provider defaults")

        let defaults = UserDefaults.standard
        selectedAIProviderID = defaults.string(forKey: "selectedProvider") ?? AIProvider.gemini.rawValue
        loadAIProviderSettings(resetMessage: false)
        selectedSTTBackendID = defaults.string(forKey: "amica_stt_backend") ?? STTBackend.nativeIOS.rawValue
        loadSTTBackendSettings(resetMessage: false)
        selectedTTSBackendID = defaults.string(forKey: "amica_tts_backend") ?? TTSBackend.elevenLabs.rawValue
        loadTTSBackendSettings(resetMessage: false)
        CrashCatcher.breadcrumb("loadSettings: after TTS backend")
        let voiceID = HostedServiceConfig.selectedElevenLabsVoiceID()
        selectedVoicePickerID = ScowldVoiceLibrary.pickerID(for: voiceID)
        customVoiceID = selectedVoicePickerID == ScowldVoiceLibrary.customID ? voiceID : ""
        selectedLanguageID = HostedServiceConfig.selectedServiceLanguageID()
        let storedCharacterName = defaults.string(forKey: "character_name")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        characterName = storedCharacterName
        selectedAvatar = defaults.string(forKey: "selected_avatar") ?? "AvatarSample_A"
        let storedSystemPrompt = defaults.string(forKey: "system_prompt") ?? ""
        systemPrompt = storedSystemPrompt == Self.defaultSystemPrompt ? "" : storedSystemPrompt
        savedCharacterName = characterName
        savedSystemPrompt = systemPrompt
        showAICaption = defaults.bool(forKey: "show_ai_caption")

        selectedBackgroundID = AmicaSceneSettings.backgroundID(defaults: defaults)
        subjectOffset = AmicaSceneSettings.subjectOffset(defaults: defaults)
        zoomMax = AmicaSceneSettings.zoomMax(defaults: defaults)
        reloadImportedAvatars()
        CrashCatcher.breadcrumb("loadSettings: after avatars")
        loadFocusTimerSettings()
        CrashCatcher.breadcrumb("loadSettings: after focus timer")
        reloadImportedMusic()
        CrashCatcher.breadcrumb("loadSettings: after music")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isLoadingSettings = false
            hasCharacterChanges = false
            CrashCatcher.breadcrumb("loadSettings: done")
        }
    }

    // MARK: - Focus timer settings

    private func loadFocusTimerSettings() {
        let defaults = UserDefaults.standard
        FocusTimerSettings.registerDefaults()
        focusTimerEnabled = FocusTimerSettings.isEnabled(defaults: defaults)
        focusTimerModeID = FocusTimerSettings.mode(defaults: defaults).rawValue
        // Snap to the offered presets, so a value saved before the picker existed
        // still has a matching option to show.
        focusMinutes = Self.nearest(FocusTimerSettings.focusMinutes(defaults: defaults), in: FocusTimerSettings.focusLengthOptions)
        restMinutes = Self.nearest(FocusTimerSettings.restMinutes(defaults: defaults), in: FocusTimerSettings.restLengthOptions)
        focusAutoRest = FocusTimerSettings.autoRest(defaults: defaults)
        focusChime = FocusTimerSettings.playsChime(defaults: defaults)
    }

    private static func nearest(_ value: Int, in options: [Int]) -> Int {
        options.min(by: { abs($0 - value) < abs($1 - value) }) ?? value
    }

    private func saveFocusTimerSettings() {
        let defaults = UserDefaults.standard
        defaults.set(focusTimerEnabled, forKey: FocusTimerSettings.enabledKey)
        defaults.set(focusTimerModeID, forKey: FocusTimerSettings.modeKey)
        defaults.set(focusMinutes, forKey: FocusTimerSettings.focusMinutesKey)
        defaults.set(restMinutes, forKey: FocusTimerSettings.restMinutesKey)
        defaults.set(focusAutoRest, forKey: FocusTimerSettings.autoRestKey)
        defaults.set(focusChime, forKey: FocusTimerSettings.chimeKey)

        // Turning it off should not leave a session running in the background.
        if !focusTimerEnabled {
            focusTimer.stop()
        }
    }

    // MARK: - Music

    private func reloadImportedMusic() {
        importedMusic = AmicaUserMedia.importedMusic()
        ambience.refreshMusicLibrary()
        selectedAmbientTrackID = ambience.track?.rawValue ?? ""
        ambientVolume = ambience.noiseVolume
        musicLevel = ambience.musicVolume
    }

    private func handleMusicImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            var added = 0
            for url in urls where AmicaUserMedia.importMusic(from: url) != nil {
                added += 1
            }
            reloadImportedMusic()
            ambienceMessage = added > 0
                ? "Added \(added) track\(added == 1 ? "" : "s")"
                : "Those files could not be added"
        case .failure(let error):
            ambienceMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private func deleteMusic(_ file: AmicaMediaFile) {
        if ambience.currentTrack?.id == file.id {
            ambience.stopMusic()
        }
        AmicaUserMedia.deleteMusic(fileName: file.fileName)
        reloadImportedMusic()
        ambienceMessage = "Removed \(file.displayName)"
    }

    private func loadAIProviderSettings(resetMessage: Bool = true) {
        let provider = selectedAIProvider
        selectedAIModel = HostedServiceConfig.selectedModel(for: provider)
        aiModelIsCustom = !provider.availableModels.contains(selectedAIModel)
        aiAPIKey = provider.requiresAPIKey ? (KeychainManager.load(key: provider.keychainKey) ?? "") : ""
        hasSavedAIAPIKey = provider.requiresAPIKey && !aiAPIKey.isEmpty
        ollamaURL = KeychainManager.load(key: OllamaConfig.keychainURLKey) ?? OllamaConfig.defaultURL
        if resetMessage {
            aiSettingsMessage = nil
        }
    }

    private func loadSTTBackendSettings(resetMessage: Bool = true) {
        let backend = selectedSTTBackend
        selectedSTTModel = STTBackend.selectedModel(for: backend)
        sttModelIsCustom = !backend.availableModels.isEmpty && !backend.availableModels.contains(selectedSTTModel)
        sttAPIKey = backend.requiresAPIKey ? (KeychainManager.load(key: backend.keychainKey) ?? "") : ""
        hasSavedSTTAPIKey = backend.requiresAPIKey && !sttAPIKey.isEmpty
        if resetMessage {
            sttSettingsMessage = nil
        }
    }

    private func loadTTSBackendSettings(resetMessage: Bool = true) {
        let backend = selectedTTSBackend
        selectedTTSModel = TTSBackend.selectedModel(for: backend)
        ttsModelIsCustom = !backend.availableModels.isEmpty && !backend.availableModels.contains(selectedTTSModel)
        ttsAPIKey = KeychainManager.load(key: backend.keychainKey) ?? ""
        hasSavedTTSAPIKey = !ttsAPIKey.isEmpty
        selectedOpenAITTSVoice = HostedServiceConfig.selectedOpenAITTSVoice()
        customTTSVoice = TTSBackend.selectedVoice(for: backend)
        ttsEndpoint = TTSBackend.selectedEndpoint(for: backend)
        if resetMessage {
            ttsSettingsMessage = nil
        }
    }

    private func saveAISettings() {
        dismissKeyboard()
        let defaults = UserDefaults.standard
        let provider = selectedAIProvider
        let model = selectedAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(provider.rawValue, forKey: "selectedProvider")
        defaults.set(model.isEmpty ? provider.defaultModel : model, forKey: provider.modelDefaultsKey)
        defaults.set(model.isEmpty ? provider.defaultModel : model, forKey: "selectedModel")

        if provider == .ollama {
            let url = ollamaURL.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = KeychainManager.save(key: OllamaConfig.keychainURLKey, value: url.isEmpty ? OllamaConfig.defaultURL : url)
        } else {
            saveKeyIfNeeded(aiAPIKey, key: provider.keychainKey)
        }

        hasSavedAIAPIKey = provider.requiresAPIKey && KeychainManager.exists(key: provider.keychainKey)
        aiSettingsMessage = "Saved"
        NotificationCenter.default.post(name: .amicaSettingsChanged, object: nil)
    }

    private func saveSTTSettings() {
        dismissKeyboard()
        let defaults = UserDefaults.standard
        let backend = selectedSTTBackend
        let model = selectedSTTModel.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(backend.rawValue, forKey: "amica_stt_backend")
        if !backend.availableModels.isEmpty {
            defaults.set(model.isEmpty ? backend.defaultModel : model, forKey: backend.modelDefaultsKey)
        }

        if backend.requiresAPIKey {
            saveKeyIfNeeded(sttAPIKey, key: backend.keychainKey)
        }

        hasSavedSTTAPIKey = backend.requiresAPIKey && KeychainManager.exists(key: backend.keychainKey)
        sttSettingsMessage = "Saved"
        NotificationCenter.default.post(name: .amicaSettingsChanged, object: nil)
    }

    private func saveTTSSettings() {
        dismissKeyboard()
        let defaults = UserDefaults.standard
        let backend = selectedTTSBackend
        let model = selectedTTSModel.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(backend.rawValue, forKey: "amica_tts_backend")
        defaults.set(model.isEmpty ? backend.defaultModel : model, forKey: backend.modelDefaultsKey)
        if backend == .elevenLabs {
            defaults.set(model.isEmpty ? backend.defaultModel : model, forKey: "amica_elevenlabs_model")
            saveSelectedVoice()
        } else if backend == .openAI {
            saveOpenAITTSVoice()
        } else if backend.usesCustomVoiceField {
            defaults.set(
                customTTSVoice.trimmingCharacters(in: .whitespacesAndNewlines),
                forKey: backend.voiceDefaultsKey
            )
            defaults.set(
                ttsEndpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                forKey: backend.endpointDefaultsKey
            )
        }
        saveKeyIfNeeded(ttsAPIKey, key: backend.keychainKey)

        hasSavedTTSAPIKey = KeychainManager.exists(key: backend.keychainKey)
        ttsSettingsMessage = "Saved"
        NotificationCenter.default.post(name: .amicaSettingsChanged, object: nil)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func saveKeyIfNeeded(_ value: String, key: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = KeychainManager.save(key: key, value: trimmed)
    }

    private func saveSelectedVoice() {
        let defaults = UserDefaults.standard
        HostedServiceConfig.applyBYOKDefaults()
        defaults.set(
            ScowldVoiceLibrary.voiceID(for: selectedVoicePickerID, customVoiceID: customVoiceID),
            forKey: "amica_elevenlabs_voiceid"
        )
        NotificationCenter.default.post(name: .amicaSettingsChanged, object: nil)
    }

    private func saveOpenAITTSVoice() {
        UserDefaults.standard.set(
            selectedOpenAITTSVoice,
            forKey: HostedServiceConfig.openAITTSVoiceDefaultsKey
        )
        NotificationCenter.default.post(name: .amicaSettingsChanged, object: nil)
    }

    private func saveLanguageSettings() {
        UserDefaults.standard.set(selectedLanguageID, forKey: HostedServiceConfig.serviceLanguageDefaultsKey)
        NotificationCenter.default.post(name: .amicaSettingsChanged, object: nil)
    }

    private func saveDisplaySettings() {
        UserDefaults.standard.set(showAICaption, forKey: "show_ai_caption")
        NotificationCenter.default.post(name: .amicaSettingsChanged, object: nil)
    }

    private func markCharacterChanged() {
        guard !isLoadingSettings else { return }
        hasCharacterChanges =
            characterName != savedCharacterName ||
            systemPrompt != savedSystemPrompt
    }

    private var canClearCharacter: Bool {
        !characterName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Reset the custom name and system prompt back to their placeholder defaults.
    /// Persisted on the next Save (empty name resolves to Bella; empty prompt to the default).
    private func clearCharacterDefaults() {
        dismissKeyboard()
        characterName = ""
        systemPrompt = ""
        markCharacterChanged()
    }

    private func saveAvatarSettings() {
        UserDefaults.standard.set(selectedAvatar, forKey: "selected_avatar")
        NotificationCenter.default.post(name: .amicaSettingsChanged, object: nil)
    }

    private func saveCharacterSettings() {
        dismissKeyboard()
        let defaults = UserDefaults.standard
        HostedServiceConfig.applyBYOKDefaults()

        let trimmedCharacterName = characterName.trimmingCharacters(in: .whitespacesAndNewlines)
        characterName = trimmedCharacterName
        defaults.set(trimmedCharacterName, forKey: "character_name")

        // An empty field means "use the default." Store the default text so the
        // effective prompt is unchanged, while the field keeps showing it as a placeholder.
        let trimmedSystemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(trimmedSystemPrompt.isEmpty ? Self.defaultSystemPrompt : systemPrompt, forKey: "system_prompt")

        savedCharacterName = trimmedCharacterName
        savedSystemPrompt = systemPrompt
        hasCharacterChanges = false
        NotificationCenter.default.post(name: .amicaSettingsChanged, object: nil)
    }

    private func playBundledVoicePreview() {
        previewError = nil
        previewPlayer?.stop()

        guard let url = BundledElevenLabsVoicePreviews.url(forVoiceID: selectedPreviewVoiceID) else {
            previewError = NSLocalizedString(
                "No bundled sample is available for this custom voice ID.",
                comment: "Missing voice preview error"
            )
            return
        }

        playPreviewAudio(from: url)
    }

    private func resetPreviewState() {
        previewPlayer?.stop()
        previewPlayer = nil
        previewError = nil
    }

    private func playPreviewAudio(from url: URL) {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default)
            try audioSession.setActive(true)

            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.play()
            previewPlayer = player
        } catch {
            previewError = String.localizedStringWithFormat(
                NSLocalizedString("Could not play sample: %@", comment: "Voice preview playback error"),
                error.localizedDescription
            )
        }
    }
}

private struct KeyboardDismissInstaller: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> InstallerView {
        InstallerView { window in
            context.coordinator.install(on: window)
        }
    }

    func updateUIView(_ view: InstallerView, context: Context) {
        view.onWindowChange = { window in
            context.coordinator.install(on: window)
        }
        context.coordinator.install(on: view.window)
    }

    static func dismantleUIView(_ view: InstallerView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class InstallerView: UIView {
        var onWindowChange: (UIWindow?) -> Void

        init(onWindowChange: @escaping (UIWindow?) -> Void) {
            self.onWindowChange = onWindowChange
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange(window)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var window: UIWindow?
        private var recognizer: UITapGestureRecognizer?

        func install(on window: UIWindow?) {
            guard self.window !== window else { return }
            uninstall()
            guard let window else { return }

            let recognizer = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)

            self.window = window
            self.recognizer = recognizer
        }

        func uninstall() {
            if let recognizer, let window {
                window.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            window = nil
        }

        @objc private func dismissKeyboard() {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            !isTextInput(touch.view)
        }

        private func isTextInput(_ view: UIView?) -> Bool {
            guard let view else { return false }
            if view is UITextField || view is UITextView {
                return true
            }
            return isTextInput(view.superview)
        }
    }
}
