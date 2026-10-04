import SwiftUI
import WebKit
import UIKit
import AVFoundation
import AudioToolbox
import os

private let logger = Logger(subsystem: "com.apoorvdarshan.Scowld", category: "Amica")

private enum InteractionFeedback {
    static func tap() {
        AudioServicesPlaySystemSound(SystemSoundID(1104))
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.55)
    }

    static func recordStart() {
        AudioServicesPlaySystemSound(SystemSoundID(1113))
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.75)
    }

    static func send() {
        AudioServicesPlaySystemSound(SystemSoundID(1105))
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func cancel() {
        AudioServicesPlaySystemSound(SystemSoundID(1053))
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func slideCancelArmed() {
        AudioServicesPlaySystemSound(SystemSoundID(1103))
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.8)
    }

    static func camera(isOn: Bool) {
        AudioServicesPlaySystemSound(SystemSoundID(isOn ? 1104 : 1103))
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: isOn ? 0.55 : 0.75)
    }
}

// MARK: - Home View

// Debug log shared between views
@Observable
class DebugLog {
    static let shared = DebugLog()
    var messages: [String] = []
    func add(_ msg: String) {
        DispatchQueue.main.async {
            self.messages.append(msg)
            if self.messages.count > 20 { self.messages.removeFirst() }
        }
    }
}

private struct VoiceTouchCaptureView: UIViewRepresentable {
    var isEnabled: Bool
    var onStart: () -> Void
    var onMove: (CGSize) -> Void
    var onEnd: (CGSize, TimeInterval) -> Void
    var onCancel: () -> Void

    func makeUIView(context: Context) -> VoiceTouchControl {
        let control = VoiceTouchControl()
        control.backgroundColor = .clear
        return control
    }

    func updateUIView(_ control: VoiceTouchControl, context: Context) {
        control.isCaptureEnabled = isEnabled
        control.isUserInteractionEnabled = true
        control.onStart = onStart
        control.onMove = onMove
        control.onEnd = onEnd
        control.onCancel = onCancel
    }
}

private final class VoiceTouchControl: UIControl {
    var isCaptureEnabled = true
    var onStart: (() -> Void)?
    var onMove: ((CGSize) -> Void)?
    var onEnd: ((CGSize, TimeInterval) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint = CGPoint.zero
    private var startedAt: Date?
    private var isTrackingCapture = false

    override var intrinsicContentSize: CGSize {
        CGSize(width: 48, height: 48)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isCaptureEnabled else { return false }
        startPoint = touch.location(in: self)
        startedAt = Date()
        isTrackingCapture = true
        onStart?()
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isTrackingCapture else { return false }
        onMove?(translationSize(for: touch))
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        guard isTrackingCapture, let startedAt else {
            resetTracking()
            return
        }

        let translation = touch.map { translationSize(for: $0) } ?? CGSize.zero
        onEnd?(translation, Date().timeIntervalSince(startedAt))
        resetTracking()
    }

    override func cancelTracking(with event: UIEvent?) {
        if isTrackingCapture {
            onCancel?()
        }
        resetTracking()
    }

    private func translationSize(for touch: UITouch) -> CGSize {
        let point = touch.location(in: self)
        return CGSize(width: point.x - startPoint.x, height: point.y - startPoint.y)
    }

    private func resetTracking() {
        startPoint = .zero
        startedAt = nil
        isTrackingCapture = false
    }
}

struct HomeView: View {
    var memoryStore: MemoryStore
    var isActive = true
    @State private var messageText = ""
    @State private var amicaCoordinator: AmicaFullView.Coordinator?
    /// Avatar value the page is currently showing, so a change can be swapped in
    /// at runtime instead of reloading the whole web view.
    @State private var appliedAvatarValue: String?
    /// Set when the viewer refuses a model, so the reason is not swallowed.
    @State private var avatarLoadError: String?
    @State private var cameraOn = true
    /// Whether the character is allowed to start a conversation on its own.
    /// `@AppStorage` so the menu label and the injected config cannot disagree.
    @AppStorage(ProactiveChatSettings.enabledKey) private var proactiveChatEnabled = true
    @State private var voiceManager = VoiceManager()
    @State private var handsFreeWakeListener = HandsFreeWakeListener()
    @State private var aiResponseText = ""
    @State private var isAwaitingAssistantResponse = false
    @State private var assistantUnlockTask: Task<Void, Never>?
    @State private var voicePressStartedAt: Date?
    @State private var voicePressTranslation: CGSize = .zero
    @State private var isVoicePressActive = false
    @State private var isTapVoiceRecording = false
    @State private var wasVoiceDragCancelArmed = false
    @State private var isHandsFreeCommandActive = false
    @State private var isAssistantSpeaking = false
    @State private var voicePermissionsGranted = false
    @State private var showHomeTips = false
    @State private var assistantSpeechUnlockTask: Task<Void, Never>?
    @State private var assistantSpeechEarliestEndAt: Date?
    @AppStorage("show_ai_caption") private var showAICaption = false
    @AppStorage("hands_free_mode_enabled") private var handsFreeModeEnabled = true
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var messageFieldFocused: Bool

    private let voiceTapMaximumDuration: TimeInterval = 0.95
    private let voiceTapMaximumMovement: CGFloat = 32
    private let voiceCancelDragThreshold: CGFloat = -84

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                AmicaFullView(memoryStore: memoryStore, onCoordinatorReady: { coord in
                    amicaCoordinator = coord
                    coord.setRuntimeActive(isActive)
                    // The page already loaded with this avatar, so remember it.
                    appliedAvatarValue = UserDefaults.standard.string(forKey: "selected_avatar") ?? "AvatarSample_A"
                })
                .ignoresSafeArea()

                // Assistant captions
                assistantCaption
            }
            .navigationTitle("Scowld")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showHomeTips = true
                        InteractionFeedback.tap()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .accessibilityLabel("Show home tips")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composerBar
            }
        }
        .sheet(isPresented: $showHomeTips) {
            HomeTipsSheet(wakeName: CharacterPack.resolveCharacterName())
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            ScowldAudioSession.configureAmicaWebAudioPlayback()

            Task {
                let granted = await SpeechManager().requestPermissions()
                await MainActor.run {
                    voicePermissionsGranted = granted
                    updateHandsFreeWakeListener()
                }
            }

            setupVoice()
            amicaCoordinator?.setRuntimeActive(isActive)
            updateHandsFreeWakeListener()
        }
        .onDisappear {
            stopActiveConversation()
        }
        .onChange(of: isActive) {
            if isActive {
                amicaCoordinator?.setRuntimeActive(true)
                updateHandsFreeWakeListener()
            } else {
                stopActiveConversation()
            }
        }
        .onChange(of: voiceManager.readyCommand) {
            if let text = voiceManager.readyCommand {
                voiceManager.readyCommand = nil
                resetVoiceInteractionState()
                aiResponseText = ""
                messageText = text
                sendMessage()
            }
        }
        .onChange(of: voiceManager.state) {
            if voiceManager.state != .listening {
                resetVoiceInteractionState()
            }
            updateHandsFreeWakeListener()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ttsDone)) { _ in
            finishAssistantTurn()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ttsFailed)) { _ in
            finishAssistantTurn()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ttsPlaybackStarted)) { notification in
            let duration = notification.object as? TimeInterval ?? 20
            markAssistantSpeechStarted(estimatedDuration: duration)
        }
        .onReceive(NotificationCenter.default.publisher(for: .aiResponseReady)) { notification in
            if let text = notification.object as? String {
                aiResponseText = text
                scheduleAssistantUnlockFallback(after: estimatedFallbackDelay(for: text))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .amicaSettingsChanged)) { _ in
            updateHandsFreeWakeListener()
            applyAvatarIfChanged()
            runViewerScript(AmicaViewerBridge.applySceneScript())
        }
        .alert("Couldn't load that model", isPresented: Binding(
            get: { avatarLoadError != nil },
            set: { if !$0 { avatarLoadError = nil } }
        )) {
            Button("OK", role: .cancel) { avatarLoadError = nil }
        } message: {
            Text(avatarLoadError ?? "")
        }
        .onChange(of: handsFreeModeEnabled) {
            updateHandsFreeWakeListener()
        }
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .active:
                if isActive {
                    amicaCoordinator?.setRuntimeActive(true)
                    updateHandsFreeWakeListener()
                }
            case .inactive:
                break
            case .background:
                stopActiveConversation()
            @unknown default:
                break
            }
        }
    }

    private var messageField: some View {
        TextField("Message...", text: $messageText)
            .textFieldStyle(.plain)
            .submitLabel(.send)
            .onSubmit { if !isBusy { stopAndSend() } }
            .disabled(isBusy)
            .focused($messageFieldFocused)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.black.opacity(0.34))
            }
    }

    private var textSendButton: some View {
        Button {
            stopAndSend()
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundColor(canSendText ? .amicaBlue : .secondary)
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .disabled(!canSendText)
    }

    private var voiceButton: some View {
        ZStack {
            Image(systemName: voiceIconName)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(voiceIconColor)

            VoiceTouchCaptureView(
                isEnabled: canAttemptVoiceCapture || isVoicePressActive,
                onStart: beginVoicePress,
                onMove: updateVoicePress,
                onEnd: completeVoicePress,
                onCancel: cancelVoiceTouchTracking
            )
            .frame(width: 48, height: 48)
        }
        .frame(width: 48, height: 48)
        .contentShape(Rectangle())
        .opacity(canAttemptVoiceCapture ? 1 : 0.5)
        .accessibilityLabel("Record voice")
        .accessibilityHint("Tap to start recording, or hold and release to send. Slide left while holding to cancel.")
    }

    private var composerBar: some View {
        ZStack {
            standardComposerBar
                .opacity(isVoiceCaptureActive ? 0 : 1)
                .allowsHitTesting((!isVoiceCaptureActive && !isBusy) || isVoicePressActive)

            recordingComposerBar
                .opacity(isVoiceCaptureActive ? 1 : 0)
                .allowsHitTesting(isVoiceCaptureActive)
        }
        .animation(.easeInOut(duration: 0.18), value: isVoiceCaptureActive)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var standardComposerBar: some View {
        HStack(spacing: 7) {
            Button {
                toggleCamera()
            } label: {
                Image(systemName: cameraOn ? "eye.fill" : "eye.slash")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 44, height: 48)
                    .foregroundStyle(cameraOn ? .amicaBlue : .secondary)
            }
            .buttonStyle(.plain)

            handsFreeButton

            characterActionsMenu

            messageField

            voiceButton

            textSendButton
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .scowldComposerGlass()
    }

    // MARK: - Character actions

    /// What the character is currently saying, over the scene.
    ///
    /// A frosted panel rather than the flat black slab this used to be, and it
    /// fades in and drifts up so it does not simply blink into existence. The
    /// width is capped so a long sentence stays readable instead of stretching
    /// edge to edge.
    private var assistantCaption: some View {
        VStack(spacing: 0) {
            if showAICaption, !aiResponseText.isEmpty {
                Text(aiResponseText)
                    .font(.callout)
                    .lineSpacing(3)
                    .foregroundStyle(.white.opacity(0.95))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .frame(maxWidth: 520)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 126)
        .animation(.easeOut(duration: 0.28), value: aiResponseText)
        .animation(.easeOut(duration: 0.22), value: showAICaption)
        .allowsHitTesting(false)
    }

    /// Preset levels rather than a slider: a slider is awkward to drag inside a
    /// menu, and four steps are all an ambient loop needs.
    private static let volumeSteps: [Double] = [0.25, 0.5, 0.75, 1.0]

    /// Plays one ambient loop at a time. Kept in the actions menu rather than in
    /// Settings: that screen is the one that has taken the app down before, and a
    /// quick control next to the character is the more natural place anyway.
    private var ambience: AmbienceAudio { .shared }

    /// Manual triggers for the bundled body animations and VRM expressions.
    /// Before the viewer bridge existed there was no way for the user to make the
    /// character move on demand.
    private var characterActionsMenu: some View {
        Menu {
            Section("Actions") {
                ForEach(AmicaGesture.presets) { gesture in
                    Button {
                        runViewerScript(AmicaViewerBridge.playGestureScript(gesture.id))
                    } label: {
                        Label(gesture.title, systemImage: gesture.systemImage)
                    }
                }
            }

            Section("Expression") {
                ForEach(AmicaExpression.allCases) { expression in
                    Button {
                        runViewerScript(AmicaViewerBridge.expressionScript(expression.rawValue))
                    } label: {
                        Label(expression.title, systemImage: expression.systemImage)
                    }
                }
            }

            Section("Sound") {
                ForEach(AmbientTrack.allCases) { track in
                    Button {
                        ambience.toggle(track)
                    } label: {
                        Label(
                            LocalizedStringKey(track.title),
                            systemImage: ambience.track == track ? "stop.circle.fill" : track.systemImage
                        )
                    }
                }

                Menu {
                    ForEach(Self.volumeSteps, id: \.self) { level in
                        Button {
                            ambience.volume = level
                        } label: {
                            Label(
                                "\(Int(level * 100))%",
                                systemImage: abs(ambience.volume - level) < 0.01 ? "checkmark" : "circle"
                            )
                        }
                    }
                } label: {
                    Label("Volume", systemImage: "speaker.wave.2.fill")
                }
            }

            Section("Proactive") {
                Button {
                    proactiveChatEnabled.toggle()
                    ProactiveChatSettings.registerDefaults()
                    // The page reads this once, when it loads, so the change only
                    // takes effect after a reload — the same route a settings
                    // change already takes.
                    NotificationCenter.default.post(name: .amicaSettingsChanged, object: nil)
                } label: {
                    Label(
                        proactiveChatEnabled ? "Speak first: On" : "Speak first: Off",
                        systemImage: proactiveChatEnabled ? "checkmark.circle.fill" : "circle"
                    )
                }
            }

            Section {
                Button {
                    runViewerScript(AmicaViewerBridge.resetCameraScript)
                } label: {
                    Label("Reset camera", systemImage: "camera.metering.center.weighted")
                }
            }
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 40, height: 48)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Character actions")
    }

    /// Fire-and-forget Javascript into the 3D viewer.
    private func runViewerScript(_ script: String) {
        amicaCoordinator?.webView?.evaluateJavaScript(script) { _, error in
            if let error {
                DebugLog.shared.add("[Viewer] script failed: \(error.localizedDescription)")
            }
        }
    }

    /// Swaps the character model when the avatar selection changed. This runs
    /// without reloading the page, so an imported model appears immediately.
    private func applyAvatarIfChanged() {
        let stored = UserDefaults.standard.string(forKey: "selected_avatar") ?? "AvatarSample_A"
        guard stored != appliedAvatarValue else { return }
        appliedAvatarValue = stored

        guard let webView = amicaCoordinator?.webView else { return }

        let displayName = AmicaAvatarSelection.displayName(for: stored, characterName: "")
        let isImported = AmicaAvatarSelection.isImported(stored)
        let expectedBytes: Int64? = isImported
            ? AmicaUserMedia.slotOverrideFileURL().flatMap { url -> Int64? in
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                return (attributes?[.size] as? NSNumber)?.int64Value
            }
            : nil

        // The viewer reports `false` when nothing ended up on screen. Saying so is
        // the difference between "it didn't work" and knowing which file was
        // refused — and a model the runtime cannot afford looks identical to a
        // broken one until the size is checked.
        webView.evaluateJavaScript(
            AmicaViewerBridge.loadAvatarScript(
                url: AmicaAvatarSelection.vrmURL(for: stored),
                name: displayName
            )
        ) { result, error in
            if let error {
                DebugLog.shared.add("[Viewer] avatar swap failed: \(error.localizedDescription)")
            }
            guard (result as? Bool) != true else { return }
            var detail = ""
            if let expectedBytes, expectedBytes > 0 {
                detail = String(
                    format: "\n\nThe file is %.1f MB. Models above roughly 30 MB, or with 4096-pixel textures, are usually too large for this device.",
                    Double(expectedBytes) / 1_048_576
                )
            }
            DispatchQueue.main.async {
                avatarLoadError = "\"\(displayName)\" could not be loaded. The previous character is still shown.\(detail)"
            }
        }
    }
    private var recordingComposerBar: some View {
        HStack(spacing: 10) {
            Button {
                cancelVoiceCapture()
            } label: {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(canCancelVoiceCapture ? .red.opacity(0.9) : .secondary)
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .disabled(!canCancelVoiceCapture)

            HStack(spacing: 10) {
                Image(systemName: recordingStatusIconName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isVoiceDragCancelArmed ? .red.opacity(0.95) : .amicaBlue)

                Text(recordingStatusText)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(isVoiceDragCancelArmed ? .red.opacity(0.95) : .white.opacity(0.92))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill((isVoiceDragCancelArmed ? Color.red : Color.black).opacity(0.34))
            }

            Button {
                sendVoiceCapture()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(canSendVoiceCapture ? .amicaBlue : .secondary)
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .disabled(!canSendVoiceCapture)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .scowldComposerGlass()
    }

    private var isBusy: Bool {
        isAwaitingAssistantResponse ||
            isAssistantSpeaking ||
            !aiResponseText.isEmpty ||
            voiceManager.state == .listening ||
            voiceManager.state == .transcribing ||
            voiceManager.state == .waitingForTTS
    }

    private var canSendText: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isBusy
    }

    private var canBeginVoiceCapture: Bool {
        canAttemptVoiceCapture
    }

    private var canAttemptVoiceCapture: Bool {
        !isAwaitingAssistantResponse &&
            !isAssistantSpeaking &&
            aiResponseText.isEmpty &&
            voiceManager.state == .idle &&
            messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canListenForHandsFreeWake: Bool {
        isActive &&
            scenePhase == .active &&
            handsFreeModeEnabled &&
            voicePermissionsGranted &&
            canAttemptVoiceCapture
    }

    private var isVoiceCaptureActive: Bool {
        voiceManager.state == .listening || voiceManager.state == .transcribing
    }

    private var canSendVoiceCapture: Bool {
        voiceManager.state == .listening &&
            voiceManager.hasCapturedSpeech &&
            !isAwaitingAssistantResponse &&
            !isAssistantSpeaking &&
            aiResponseText.isEmpty
    }

    private var canCancelVoiceCapture: Bool {
        voiceManager.state == .listening
    }

    private var isVoiceDragCancelArmed: Bool {
        isVoicePressActive && voicePressTranslation.width <= voiceCancelDragThreshold
    }

    private var voiceIconName: String {
        if canBeginVoiceCapture {
            return "mic.circle.fill"
        }
        return "mic.slash.circle.fill"
    }

    private var voiceIconColor: Color {
        canBeginVoiceCapture ? .amicaBlue : .secondary
    }

    private var handsFreeButton: some View {
        Button {
            toggleHandsFreeMode()
        } label: {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 23, weight: .semibold))
                .frame(width: 44, height: 48)
                .foregroundStyle(handsFreeIconColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(handsFreeModeEnabled ? "Turn off hands-free mode" : "Turn on hands-free mode")
        .accessibilityHint("Listens for hey Bella or the custom character name.")
    }

    private var handsFreeIconColor: Color {
        guard handsFreeModeEnabled else { return .secondary }
        return handsFreeWakeListener.isRunning ? .amicaBlue : .white.opacity(0.74)
    }

    private var recordingStatusIconName: String {
        if isVoiceDragCancelArmed {
            return "xmark.circle.fill"
        }

        switch voiceManager.state {
        case .transcribing:
            return "arrow.up.circle.fill"
        default:
            return "waveform.circle.fill"
        }
    }

    private var recordingStatusText: String {
        if isVoiceDragCancelArmed {
            return NSLocalizedString("Release to cancel", comment: "Voice recording cancel instruction")
        }

        switch voiceManager.state {
        case .transcribing:
            return NSLocalizedString("Sending voice...", comment: "Voice recording send status")
        case .listening where isVoicePressActive:
            return NSLocalizedString("Release to send - slide left to cancel", comment: "Voice recording hold instruction")
        case .listening where isHandsFreeCommandActive:
            return NSLocalizedString("Hands-free recording...", comment: "Hands-free voice recording status")
        case .listening where isTapVoiceRecording:
            return NSLocalizedString("Recording... tap send when done", comment: "Tap voice recording instruction")
        case .listening:
            return NSLocalizedString("Recording...", comment: "Voice recording status")
        default:
            return NSLocalizedString("Voice", comment: "Voice input label")
        }
    }

    private func beginVoicePress() {
        guard canAttemptVoiceCapture else { return }
        voicePressStartedAt = Date()
        isVoicePressActive = true
        voicePressTranslation = .zero
        wasVoiceDragCancelArmed = false
        beginVoiceCapture()
    }

    private func updateVoicePress(_ translation: CGSize) {
        guard isVoicePressActive else { return }
        voicePressTranslation = translation
        updateSlideCancelFeedback()
    }

    private func completeVoicePress(_ translation: CGSize, _ duration: TimeInterval) {
        guard isVoicePressActive else { return }

        let movement = sqrt(pow(translation.width, 2) + pow(translation.height, 2))
        let shouldCancel = translation.width <= voiceCancelDragThreshold
        let shouldKeepRecording = (duration <= voiceTapMaximumDuration && movement <= voiceTapMaximumMovement) ||
            !voiceManager.hasCapturedSpeech

        voicePressStartedAt = nil
        voicePressTranslation = .zero
        isVoicePressActive = false

        if shouldCancel {
            cancelVoiceCapture()
        } else if shouldKeepRecording {
            isTapVoiceRecording = true
        } else {
            sendVoiceCapture()
        }
    }

    private func beginVoiceCapture() {
        guard canBeginVoiceCapture else { return }
        handsFreeWakeListener.stop()
        messageFieldFocused = false
        isTapVoiceRecording = false
        InteractionFeedback.recordStart()
        voiceManager.startCommandCapture()
    }

    private func sendVoiceCapture() {
        guard canSendVoiceCapture else { return }
        isTapVoiceRecording = false
        isHandsFreeCommandActive = false
        voiceManager.finishCommandCapture()
        InteractionFeedback.send()
    }

    private func cancelVoiceCapture(playFeedback: Bool = true) {
        guard voiceManager.state == .listening || voiceManager.state == .transcribing else { return }
        isTapVoiceRecording = false
        isHandsFreeCommandActive = false
        voicePressStartedAt = nil
        voicePressTranslation = .zero
        isVoicePressActive = false
        wasVoiceDragCancelArmed = false
        voiceManager.cancelCommandCapture()
        if playFeedback {
            InteractionFeedback.cancel()
        }
    }

    private func cancelVoiceTouchTracking() {
        guard isVoicePressActive else { return }
        voicePressStartedAt = nil
        voicePressTranslation = .zero
        isVoicePressActive = false
        wasVoiceDragCancelArmed = false

        if voiceManager.state == .listening {
            isTapVoiceRecording = true
        }
    }

    private func resetVoiceInteractionState() {
        voicePressStartedAt = nil
        voicePressTranslation = .zero
        isVoicePressActive = false
        isTapVoiceRecording = false
        isHandsFreeCommandActive = false
        wasVoiceDragCancelArmed = false
    }

    private func updateSlideCancelFeedback() {
        let isArmed = voicePressTranslation.width <= voiceCancelDragThreshold
        defer { wasVoiceDragCancelArmed = isArmed }

        if isArmed && !wasVoiceDragCancelArmed {
            InteractionFeedback.slideCancelArmed()
        }
    }

    private func toggleCamera() {
        cameraOn.toggle()
        InteractionFeedback.camera(isOn: cameraOn)
        let enabled = cameraOn ? "true" : "false"
        amicaCoordinator?.webView?.evaluateJavaScript(
            """
            (function() {
                window.__scowldCameraEnabled = \(enabled);
                if (window.__toggleWebcam) {
                    window.__toggleWebcam(\(enabled));
                }
                if (\(enabled) && window.__hideWebcamPreview) {
                    setTimeout(window.__hideWebcamPreview, 0);
                    setTimeout(window.__hideWebcamPreview, 250);
                }
                if (\(enabled) && window.__captureNativeVisionFrame) {
                    setTimeout(window.__captureNativeVisionFrame, 300);
                }
            })();
            """
        )
    }

    private func stopAndSend() {
        guard canSendText else { return }
        messageFieldFocused = false
        sendMessage()
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messageText = ""
        InteractionFeedback.send()
        isAwaitingAssistantResponse = true
        scheduleAssistantUnlockFallback(after: 45)

        ScowldAudioSession.configureAmicaWebAudioPlayback()

        logger.info("[HomeView] Sending message: \(text)")

        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")
        amicaCoordinator?.webView?.evaluateJavaScript(
            "window.__sendMessageFromNative && window.__sendMessageFromNative('\(escaped)');"
        ) { result, error in
            if let error {
                logger.info("[HomeView] JS error: \(error.localizedDescription)")
            } else {
                logger.info("[HomeView] Message sent OK")
            }
        }
    }

    private func toggleHandsFreeMode() {
        handsFreeModeEnabled.toggle()
        InteractionFeedback.tap()
        updateHandsFreeWakeListener()
    }

    private func updateHandsFreeWakeListener() {
        guard canListenForHandsFreeWake else {
            handsFreeWakeListener.stop()
            return
        }

        handsFreeWakeListener.start(wakeName: CharacterPack.resolveCharacterName()) {
            handleHandsFreeWake()
        }
    }

    private func handleHandsFreeWake() {
        handsFreeWakeListener.stop()
        guard handsFreeModeEnabled, canAttemptVoiceCapture else {
            updateHandsFreeWakeListener()
            return
        }

        messageFieldFocused = false
        isTapVoiceRecording = true
        isHandsFreeCommandActive = true
        InteractionFeedback.recordStart()
        voiceManager.startCommandCapture(autoFinishOnSilence: true)
    }


    // MARK: - Wake Word

    private func setupVoice() {
        HostedServiceConfig.applyBYOKDefaults()
        voiceManager.cancelCommandCapture()
    }

    private func stopActiveConversation() {
        messageFieldFocused = false
        assistantUnlockTask?.cancel()
        assistantUnlockTask = nil
        assistantSpeechUnlockTask?.cancel()
        assistantSpeechUnlockTask = nil
        assistantSpeechEarliestEndAt = nil
        resetVoiceInteractionState()
        handsFreeWakeListener.stop()
        voiceManager.cancelCommandCapture()
        isAwaitingAssistantResponse = false
        isAssistantSpeaking = false
        aiResponseText = ""
        stopTTS()
        amicaCoordinator?.cancelRuntimeWork()
    }

    private func finishAssistantTurn() {
        if isAssistantSpeaking,
           let earliestEnd = assistantSpeechEarliestEndAt,
           Date() < earliestEnd {
            scheduleAssistantSpeechUnlock(at: earliestEnd)
            return
        }
        completeAssistantTurn()
    }

    private func completeAssistantTurn() {
        assistantUnlockTask?.cancel()
        assistantUnlockTask = nil
        assistantSpeechUnlockTask?.cancel()
        assistantSpeechUnlockTask = nil
        assistantSpeechEarliestEndAt = nil
        aiResponseText = ""
        isAwaitingAssistantResponse = false
        isAssistantSpeaking = false
        voiceManager.onTTSDone()
        updateHandsFreeWakeListener()
    }

    private func markAssistantSpeechStarted(estimatedDuration: TimeInterval) {
        assistantUnlockTask?.cancel()
        assistantUnlockTask = nil
        isAwaitingAssistantResponse = true
        isAssistantSpeaking = true
        let lockedDuration = max(estimatedDuration + 0.75, 1.5)
        let earliestEnd = Date().addingTimeInterval(lockedDuration)
        assistantSpeechEarliestEndAt = earliestEnd
        scheduleAssistantSpeechUnlock(at: earliestEnd)
    }

    private func scheduleAssistantSpeechUnlock(at date: Date) {
        assistantSpeechUnlockTask?.cancel()
        assistantSpeechUnlockTask = Task { @MainActor in
            let delay = max(0.1, date.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            completeAssistantTurn()
        }
    }

    private func scheduleAssistantUnlockFallback(after delay: TimeInterval) {
        assistantUnlockTask?.cancel()
        assistantUnlockTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(1, delay)))
            guard !Task.isCancelled else { return }
            if isAwaitingAssistantResponse || !aiResponseText.isEmpty || voiceManager.state == .waitingForTTS {
                finishAssistantTurn()
            }
        }
    }

    private func estimatedFallbackDelay(for text: String) -> TimeInterval {
        let wordCount = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        let estimatedSpeechSeconds = Double(max(wordCount, 1)) / 2.4
        return min(max(estimatedSpeechSeconds + 8, 12), 45)
    }

    private func stopTTS() {
        amicaCoordinator?.webView?.evaluateJavaScript("""
            (function() {
                if (window.__stopScowldAudio) {
                    window.__stopScowldAudio();
                }
                // Stop all AudioContext sources
                if (window._allAudioContexts) {
                    window._allAudioContexts.forEach(function(ctx) {
                        try { ctx.close(); } catch(e) {}
                    });
                    window._allAudioContexts = [];
                }
                // Pause all HTML5 audio elements
                document.querySelectorAll('audio').forEach(function(a) {
                    a.pause();
                    a.currentTime = 0;
                });
                // Stop any speech synthesis
                if (window.speechSynthesis) {
                    window.speechSynthesis.cancel();
                }
            })();
        """)
    }
}

private struct HomeTipsSheet: View {
    let wakeName: String
    @Environment(\.dismiss) private var dismiss

    private var trimmedWakeName: String {
        let trimmed = wakeName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Bella" : trimmed
    }

    private var wakeText: String {
        if trimmedWakeName.caseInsensitiveCompare("Bella") == .orderedSame {
            return "Say \"Bella\" or \"hey Bella\". If you set a custom name, say that name or \"hey\" plus it."
        }

        return "Say \"\(trimmedWakeName)\" or \"hey \(trimmedWakeName)\" while hands-free is on. \"Bella\" still works too."
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    tipRow(icon: "dot.radiowaves.left.and.right", title: "Hands-free wake", text: wakeText)
                    tipRow(icon: "eye.fill", title: "Eye", text: "Turns camera vision on or off. When on, Bella can use the camera frame with your next message.")
                    tipRow(icon: "mic.circle.fill", title: "Voice", text: "Tap to start recording, or hold and release to send. Slide left while holding to cancel.")
                    tipRow(icon: "arrow.up.circle.fill", title: "Send", text: "Sends typed text or the recorded voice command when it is ready.")
                    tipRow(icon: "trash.circle.fill", title: "Trash", text: "Cancels the current voice recording.")
                }

                Section {
                    Text("Hands-free only listens when the app is open, idle, and the hands-free icon is enabled.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Home Tips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func tipRow(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.amicaBlue)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }
}

private enum ElevenLabsBYOKRequestBuilder {
    static func makeRequest(voiceID: String, body: Data?) throws -> URLRequest {
        guard let apiKey = KeychainManager.load(key: TTSBackend.elevenLabs.keychainKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty
        else {
            throw ElevenLabsBYOKError.missingAPIKey
        }

        let selectedVoiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? HostedServiceConfig.selectedElevenLabsVoiceID()
            : voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let escapedVoiceID = selectedVoiceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(escapedVoiceID)?output_format=mp3_44100_128")
        else {
            throw ElevenLabsBYOKError.invalidVoiceID
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: providerBody(from: body))
        return request
    }

    static func errorResponseBody(_ error: Error) -> Data {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return Data("{\"error\":\"\(jsonEscaped(message))\"}".utf8)
    }

    private static func providerBody(from data: Data?) -> [String: Any] {
        var body: [String: Any] = [:]

        if let data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            body = json
        }

        body["model_id"] = TTSBackend.selectedModel(for: .elevenLabs)
        if let languageCode = HostedServiceConfig.selectedServiceLanguageCode() {
            body["language_code"] = languageCode
        }
        if body["voice_settings"] == nil {
            body["voice_settings"] = [
                "stability": 0.55,
                "similarity_boost": 0.8,
                "style": 0.35,
                "use_speaker_boost": true,
            ]
        }

        return body
    }

    private static func jsonEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

private enum ElevenLabsBYOKError: LocalizedError {
    case missingAPIKey
    case invalidVoiceID

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "ElevenLabs API key is missing. Add it in Settings > Text-to-Speech."
        case .invalidVoiceID:
            "The selected ElevenLabs voice ID is invalid."
        }
    }
}

// MARK: - Local HTTP Server for Amica

/// Serves Amica's static files via a local HTTP server so fetch() works with normal CORS.
class AmicaLocalServer {
    static let shared = AmicaLocalServer()
    private var listener: (any NSObjectProtocol)?
    private var serverSocket: Int32 = -1
    var port: UInt16 = 0
    private var isRunning = false
    private let amicaBasePath: String

    init() {
        // Find amica.bundle in app bundle
        let bundle = Bundle.main.bundlePath
        let paths = [
            "\(bundle)/amica.bundle",
            bundle,
            "\(bundle)/amica"
        ]
        amicaBasePath = paths.first { FileManager.default.fileExists(atPath: "\($0)/index.html") } ?? bundle
        logger.info("[Server] Amica base: \(self.amicaBasePath)")
    }

    func start() {
        guard !isRunning else { return }

        // Create socket
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else { logger.info("[Server] Socket failed"); return }

        var yes: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0 // Let OS pick a port

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult >= 0 else { logger.info("[Server] Bind failed"); return }

        // Get assigned port
        var assignedAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assignedAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(serverSocket, $0, &addrLen)
            }
        }
        port = UInt16(bigEndian: assignedAddr.sin_port)

        guard listen(serverSocket, 10) >= 0 else { logger.info("[Server] Listen failed"); return }

        isRunning = true
        logger.info("[Server] Running on http://127.0.0.1:\(self.port)")

        // Accept connections in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while self?.isRunning == true {
                guard let self else { return }
                let client = accept(self.serverSocket, nil, nil)
                if client >= 0 {
                    // Downloading a big model takes long enough that the page can go
                    // away mid-transfer. Without this, the resulting write to a dead
                    // socket raises SIGPIPE and takes the whole app down.
                    Self.configureClientSocket(client)
                    DispatchQueue.global(qos: .userInitiated).async {
                        self.handleClient(client)
                    }
                }
            }
        }
    }

    private func handleClient(_ client: Int32) {
        defer { close(client) }

        // Read full request (headers + body)
        var allData = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
        var contentLength = 0
        var headerEnd = 0

        // First read — usually gets headers + body for small requests
        let firstRead = read(client, &buffer, buffer.count)
        guard firstRead > 0 else { return }
        allData.append(contentsOf: buffer[0..<firstRead])

        // Find header/body boundary
        guard let sepRange = allData.range(of: separator) else { return }
        headerEnd = sepRange.upperBound

        // Parse Content-Length
        if let hdrStr = String(data: allData[0..<sepRange.lowerBound], encoding: .utf8) {
            for line in hdrStr.components(separatedBy: "\r\n") {
                if line.lowercased().hasPrefix("content-length:") {
                    contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
        }

        // If we know Content-Length, read until we have it all
        if contentLength > 0 {
            let totalNeeded = headerEnd + contentLength
            while allData.count < totalNeeded {
                let n = read(client, &buffer, min(buffer.count, totalNeeded - allData.count))
                if n <= 0 { break }
                allData.append(contentsOf: buffer[0..<n])
            }
        } else {
            // No Content-Length — try reading more with a short poll
            var pollFd = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            while Darwin.poll(&pollFd, 1, 50) > 0 { // 50ms timeout
                let n = read(client, &buffer, buffer.count)
                if n <= 0 { break }
                allData.append(contentsOf: buffer[0..<n])
            }
        }

        // Body = everything after headers
        let requestBody: Data? = headerEnd < allData.count ? Data(allData[headerEnd...]) : nil

        let headerStr = String(data: allData[0..<sepRange.lowerBound], encoding: .utf8) ?? ""
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return }

        let method = String(parts[0])
        var path = String(parts[1])
        if path == "/" { path = "/index.html" }

        // URL decode
        path = path.removingPercentEncoding ?? path

        // MARK: - ElevenLabs TTS Proxy
        // Intercept /api/elevenlabs/* and proxy to api.elevenlabs.io (bypasses CORS)
        if path.hasPrefix("/api/elevenlabs/") {
            let elPath = String(path.dropFirst("/api/elevenlabs".count))
            handleElevenLabsProxy(client: client, method: method, elPath: elPath, body: requestBody)
            return
        }

        // MARK: - OpenAI TTS Proxy
        if path.hasPrefix("/api/openai-tts/") {
            let oaiPath = String(path.dropFirst("/api/openai-tts".count))
            handleOpenAITTSProxy(client: client, method: method, oaiPath: oaiPath, body: requestBody)
            return
        }

        // MARK: - Doubao / MiniMax / Fish Audio TTS proxies
        // The web app only knows one generic TTS slot. Each of these routes speaks
        // its provider's real protocol and answers with raw audio bytes.
        if path.hasPrefix("/api/doubao-tts/") {
            handleCloudTTSProxy(client: client, method: method, backend: .doubao, body: requestBody)
            return
        }

        if path.hasPrefix("/api/minimax-tts/") {
            handleCloudTTSProxy(client: client, method: method, backend: .minimax, body: requestBody)
            return
        }

        if path.hasPrefix("/api/fish-tts/") {
            handleCloudTTSProxy(client: client, method: method, backend: .fishAudio, body: requestBody)
            return
        }

        // MARK: - CORS Preflight
        if method == "OPTIONS" {
            sendCORSPreflight(client: client)
            return
        }

        // Remove query string
        if let qIndex = path.firstIndex(of: "?") {
            path = String(path[..<qIndex])
        }

        // MARK: - User media (imported avatars, background photos)
        // The bundle is read-only, so anything the user adds lives in Documents
        // and is served from here instead.
        if path.hasPrefix("/media/") {
            // Mapped, not copied: imported avatars can be tens of megabytes and a
            // full in-memory copy on top of the WebView is pure waste.
            guard let fileURL = AmicaUserMedia.fileURL(forPublicPath: path),
                  let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
                logger.info("[Server] user media not found: \(path)")
                sendResponse(client: client, data: Data("Not Found".utf8), mimeType: "text/plain", statusCode: 404)
                return
            }
            let ext = fileURL.pathExtension
            sendResponse(client: client, data: data, mimeType: Self.mimeType(for: ext), statusCode: 200)
            return
        }

        // MARK: - Custom avatar slot
        // The page only ever loads a model whose URL appears in the list it was
        // compiled with, and that list names four models while the bundle ships
        // three — `AvatarSample_D.vrm` has never existed. Imported models are
        // registered with the list at runtime, but this slot is the safety net:
        // it is always recognised, and it serves whichever imported model is
        // currently selected.
        if path == AmicaViewerBridge.customAvatarSlotURL {
            if let fileURL = AmicaUserMedia.slotOverrideFileURL(),
               let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) {
                logger.info("[Server] serving custom avatar through the D slot")
                sendResponse(client: client, data: data, mimeType: Self.mimeType(for: fileURL.pathExtension), statusCode: 200)
            } else {
                sendResponse(client: client, data: Data("Not Found".utf8), mimeType: "text/plain", statusCode: 404)
            }
            return
        }

        if path == "/vrm/thumb-AvatarSample_D.vrm.jpg" {
            let placeholder = "\(amicaBasePath)/vrm/thumb-placeholder.jpg"
            if let data = try? Data(contentsOf: URL(fileURLWithPath: placeholder), options: .mappedIfSafe) {
                sendResponse(client: client, data: data, mimeType: "image/jpeg", statusCode: 200)
            } else {
                sendResponse(client: client, data: Data("Not Found".utf8), mimeType: "text/plain", statusCode: 404)
            }
            return
        }

        // Remove leading slash
        let relativePath = String(path.dropFirst())

        let filePath = "\(amicaBasePath)/\(relativePath)"

        guard FileManager.default.fileExists(atPath: filePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: filePath), options: .mappedIfSafe) else {
            // Try with .html
            let htmlPath = "\(amicaBasePath)/\(relativePath).html"
            if FileManager.default.fileExists(atPath: htmlPath),
               let data = try? Data(contentsOf: URL(fileURLWithPath: htmlPath), options: .mappedIfSafe) {
                sendResponse(client: client, data: data, mimeType: "text/html", statusCode: 200)
                return
            }
            sendResponse(client: client, data: Data("Not Found".utf8), mimeType: "text/plain", statusCode: 404)
            return
        }

        let ext = (filePath as NSString).pathExtension
        let mimeType = Self.mimeType(for: ext)
        sendResponse(client: client, data: data, mimeType: mimeType, statusCode: 200)
    }

    private func sendResponse(client: Int32, data: Data, mimeType: String, statusCode: Int) {
        let statusText = statusCode == 200 ? "OK" : "Not Found"
        var header = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        header += "Content-Type: \(mimeType)\r\n"
        header += "Content-Length: \(data.count)\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Cache-Control: no-cache\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"

        let headerData = Data(header.utf8)
        Self.writeAll(client: client, data: headerData)
        Self.writeAll(client: client, data: data)
    }

    /// Makes a connection safe to write a large body to: no SIGPIPE when the peer
    /// disappears, and a send timeout so a stalled client cannot pin a thread.
    static func configureClientSocket(_ client: Int32) {
        var yes: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Writes every byte of `data` to a blocking socket.
    ///
    /// A single `write` is not enough: on a blocking socket the call returns as
    /// soon as the kernel send buffer is full, so it can report fewer bytes than
    /// requested. Ignoring that return value silently truncated large payloads —
    /// a big VRM arrived at the page as an unparseable file while small assets
    /// were fine. Retrying until the buffer is drained fixes every download.
    static func writeAll(client: Int32, data: Data) {
        let total = data.count
        guard total > 0 else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < total {
                let written = write(client, base.advanced(by: offset), total - offset)
                if written > 0 {
                    offset += written
                } else if written == -1 && errno == EINTR {
                    continue
                } else {
                    // EPIPE / ETIMEDOUT / EAGAIN: the peer is gone. Nothing to do
                    // but give up; the connection is closed by the caller.
                    break
                }
            }
        }
    }

    private func sendCORSPreflight(client: Int32) {
        var header = "HTTP/1.1 204 No Content\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        header += "Access-Control-Allow-Headers: Content-Type, xi-api-key, Authorization, Accept\r\n"
        header += "Access-Control-Max-Age: 86400\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"
        let headerData = Data(header.utf8)
        headerData.withUnsafeBytes { ptr in
            _ = write(client, ptr.baseAddress!, headerData.count)
        }
    }

    private func handleElevenLabsProxy(client: Int32, method: String, elPath: String, body: Data?) {
        let fullPath = elPath.hasPrefix("/") ? elPath : "/\(elPath)"
        let pathOnly = fullPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? fullPath
        let pathParts = pathOnly.split(separator: "/").map(String.init)

        guard pathParts.count >= 2, pathParts[0] == "text-to-speech" else {
            sendResponse(client: client, data: Data("{\"error\":\"Unsupported managed ElevenLabs proxy path\"}".utf8), mimeType: "application/json", statusCode: 404)
            return
        }
        let voiceID = pathParts[1]

        let urlRequest: URLRequest
        do {
            urlRequest = try ElevenLabsBYOKRequestBuilder.makeRequest(voiceID: voiceID, body: body)
        } catch {
            logger.error("[Proxy] ElevenLabs BYOK setup error: \(error.localizedDescription)")
            sendResponse(
                client: client,
                data: ElevenLabsBYOKRequestBuilder.errorResponseBody(error),
                mimeType: "application/json",
                statusCode: 401
            )
            return
        }

        logger.info("[Proxy] ElevenLabs BYOK \(method) \(fullPath) bodyLen=\(body?.count ?? 0)")

        let semaphore = DispatchSemaphore(value: 0)
        var responseData = Data()
        var responseCode = 500
        var responseMime = "application/octet-stream"

        let task = URLSession.shared.dataTask(with: urlRequest) { data, response, error in
            if let httpResp = response as? HTTPURLResponse {
                responseCode = httpResp.statusCode
                responseMime = httpResp.value(forHTTPHeaderField: "Content-Type") ?? "audio/mpeg"
            }
            if let data { responseData = data }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        logger.info("[Proxy] ElevenLabs BYOK \(method) \(fullPath) -> \(responseCode) (\(responseData.count) bytes)")
        if responseCode != 200, let errStr = String(data: responseData, encoding: .utf8) {
            logger.error("[Proxy] ElevenLabs BYOK error: \(errStr.prefix(300))")
        }
        sendResponse(client: client, data: responseData, mimeType: responseMime, statusCode: responseCode)
    }

    private func handleOpenAITTSProxy(client: Int32, method: String, oaiPath: String, body: Data?) {
        if method == "OPTIONS" {
            sendCORSPreflight(client: client)
            return
        }

        let apiKey = KeychainManager.load(key: AIProvider.openai.keychainKey) ?? ""
        guard !apiKey.isEmpty else {
            sendResponse(client: client, data: Data("{\"error\":\"No OpenAI API key\"}".utf8), mimeType: "application/json", statusCode: 401)
            return
        }

        // The web engine calls `<openai_tts_url>/v1/audio/speech`, and we inject
        // `openai_tts_url = /api/openai-tts`, so oaiPath already includes `/v1/...`.
        let fullPath = oaiPath.hasPrefix("/") ? oaiPath : "/\(oaiPath)"
        let urlStr = "https://api.openai.com\(fullPath)"
        guard let url = URL(string: urlStr) else {
            sendResponse(client: client, data: Data("Bad URL".utf8), mimeType: "text/plain", statusCode: 400)
            return
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if method == "POST" {
            urlRequest.httpBody = body
        }

        let semaphore = DispatchSemaphore(value: 0)
        var responseData = Data()
        var responseCode = 500
        var responseMime = "application/octet-stream"

        let task = URLSession.shared.dataTask(with: urlRequest) { data, response, error in
            if let httpResp = response as? HTTPURLResponse {
                responseCode = httpResp.statusCode
                responseMime = httpResp.value(forHTTPHeaderField: "Content-Type") ?? "audio/mpeg"
            }
            if let data { responseData = data }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        logger.info("[Proxy] OpenAI TTS \(method) \(fullPath) -> \(responseCode) (\(responseData.count) bytes)")
        sendResponse(client: client, data: responseData, mimeType: responseMime, statusCode: responseCode)
    }

    // MARK: - Doubao / MiniMax / Fish Audio proxies

    /// Blocking URLSession call, matching the style of the other proxies: the local
    /// server handles each client on its own background queue, so waiting here is safe.
    private func performBlockingRequest(_ request: URLRequest) -> (data: Data, statusCode: Int, contentType: String) {
        let semaphore = DispatchSemaphore(value: 0)
        var responseData = Data()
        var responseCode = 502
        var responseMime = "application/octet-stream"

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let httpResp = response as? HTTPURLResponse {
                responseCode = httpResp.statusCode
                responseMime = httpResp.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            }
            if let data, !data.isEmpty {
                responseData = data
            } else if error != nil {
                responseCode = 502
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return (responseData, responseCode, responseMime)
    }

    /// Shared entry point for the three extra TTS providers.
    ///
    /// The bundled page POSTs `{model, input, voice}` to
    /// `<openai_tts_url>/v1/audio/speech` and expects raw audio bytes back. These
    /// routes receive exactly that and translate it into the provider's own shape.
    private func handleCloudTTSProxy(client: Int32, method: String, backend: TTSBackend, body: Data?) {
        if method == "OPTIONS" {
            sendCORSPreflight(client: client)
            return
        }

        guard method == "POST" else {
            sendResponse(client: client, data: Data("Method Not Allowed".utf8), mimeType: "text/plain", statusCode: 405)
            return
        }

        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            sendResponse(client: client, data: Data("{\"error\":\"Invalid JSON body\"}".utf8), mimeType: "application/json", statusCode: 400)
            return
        }

        let text = (json["input"] as? String) ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sendResponse(client: client, data: Data("{\"error\":\"Empty input\"}".utf8), mimeType: "application/json", statusCode: 400)
            return
        }

        // The web page echoes back whatever we injected; fall back to the saved
        // preferences so the request still works if the page sends nothing.
        let model = ((json["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? TTSBackend.selectedModel(for: backend)
        let voice = ((json["voice"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? TTSBackend.selectedVoice(for: backend)

        guard let secret = KeychainManager.load(key: backend.keychainKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty else {
            sendResponse(
                client: client,
                data: Data("{\"error\":\"No \(backend.displayName) API key saved\"}".utf8),
                mimeType: "application/json",
                statusCode: 401
            )
            return
        }

        let endpoint = TTSBackend.selectedEndpoint(for: backend)
        logger.info("[Proxy] \(backend.displayName) TTS model=\(model) voice=\(voice) chars=\(text.count)")

        switch backend {
        case .doubao:
            handleDoubaoRequest(client: client, endpoint: endpoint, secret: secret, cluster: model, voice: voice, text: text)
        case .minimax:
            handleMiniMaxRequest(client: client, endpoint: endpoint, secret: secret, model: model, voice: voice, text: text)
        case .fishAudio:
            handleFishAudioRequest(client: client, endpoint: endpoint, secret: secret, model: model, voice: voice, text: text)
        default:
            sendResponse(client: client, data: Data("{\"error\":\"Unsupported backend\"}".utf8), mimeType: "application/json", statusCode: 400)
        }
    }

    /// Volcano Engine Doubao TTS. The Keychain value must be `appid:access_token`.
    private func handleDoubaoRequest(client: Int32, endpoint: String, secret: String, cluster: String, voice: String, text: String) {
        let parts = secret.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            sendResponse(
                client: client,
                data: Data("{\"error\":\"Doubao credentials must be saved as appid:access_token\"}".utf8),
                mimeType: "application/json",
                statusCode: 401
            )
            return
        }
        let appID = parts[0]
        let accessToken = parts[1]

        guard let url = URL(string: endpoint) else {
            sendResponse(client: client, data: Data("{\"error\":\"Bad endpoint\"}".utf8), mimeType: "application/json", statusCode: 400)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Volcano's docs require the literal "Bearer;" prefix — a semicolon, not a space.
        request.setValue("Bearer;\(accessToken)", forHTTPHeaderField: "Authorization")

        let payload: [String: Any] = [
            "app": ["appid": appID, "token": accessToken, "cluster": cluster],
            "user": ["uid": "scowld-ios"],
            "audio": [
                "voice_type": voice,
                "encoding": "mp3",
                "speed_ratio": 1.0,
                "volume_ratio": 1.0,
                "pitch_ratio": 1.0,
            ],
            "request": [
                "reqid": UUID().uuidString,
                "text": text,
                "text_type": "plain",
                "operation": "query",
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let result = performBlockingRequest(request)
        guard result.statusCode == 200 else {
            logger.error("[Proxy] Doubao error \(result.statusCode)")
            sendResponse(client: client, data: result.data, mimeType: "application/json", statusCode: result.statusCode)
            return
        }

        // {"code":3000,"data":"<base64 mp3>"}
        guard let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any] else {
            sendResponse(client: client, data: Data("{\"error\":\"Unreadable Doubao response\"}".utf8), mimeType: "application/json", statusCode: 502)
            return
        }
        if let code = json["code"] as? Int, code != 3000 {
            sendResponse(client: client, data: result.data, mimeType: "application/json", statusCode: 502)
            return
        }
        guard let base64 = json["data"] as? String, let audio = Data(base64Encoded: base64) else {
            sendResponse(client: client, data: Data("{\"error\":\"Doubao returned no audio\"}".utf8), mimeType: "application/json", statusCode: 502)
            return
        }

        logger.info("[Proxy] Doubao ok: \(audio.count) bytes")
        sendResponse(client: client, data: audio, mimeType: "audio/mpeg", statusCode: 200)
    }

    /// MiniMax T2A. Returns hex-encoded audio that we decode back to bytes.
    private func handleMiniMaxRequest(client: Int32, endpoint: String, secret: String, model: String, voice: String, text: String) {
        guard let url = URL(string: endpoint) else {
            sendResponse(client: client, data: Data("{\"error\":\"Bad endpoint\"}".utf8), mimeType: "application/json", statusCode: 400)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")

        let payload: [String: Any] = [
            "model": model,
            "text": text,
            "stream": false,
            "voice_setting": [
                "voice_id": voice,
                "speed": 1.0,
                "vol": 1.0,
                "pitch": 0,
            ],
            "audio_setting": [
                "sample_rate": 32000,
                "bitrate": 128000,
                "format": "mp3",
                "channel": 1,
            ],
            "output_format": "hex",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let result = performBlockingRequest(request)
        guard result.statusCode == 200 else {
            logger.error("[Proxy] MiniMax error \(result.statusCode)")
            sendResponse(client: client, data: result.data, mimeType: "application/json", statusCode: result.statusCode)
            return
        }

        // {"data":{"audio":"<hex>"},"base_resp":{"status_code":0}}
        guard let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any] else {
            sendResponse(client: client, data: Data("{\"error\":\"Unreadable MiniMax response\"}".utf8), mimeType: "application/json", statusCode: 502)
            return
        }
        if let baseResp = json["base_resp"] as? [String: Any],
           let statusCode = baseResp["status_code"] as? Int, statusCode != 0 {
            logger.error("[Proxy] MiniMax status \(statusCode)")
            sendResponse(client: client, data: result.data, mimeType: "application/json", statusCode: 502)
            return
        }
        guard let dataObject = json["data"] as? [String: Any],
              let hex = dataObject["audio"] as? String,
              let audio = Self.dataFromHexString(hex) else {
            sendResponse(client: client, data: Data("{\"error\":\"MiniMax returned no audio\"}".utf8), mimeType: "application/json", statusCode: 502)
            return
        }

        logger.info("[Proxy] MiniMax ok: \(audio.count) bytes")
        sendResponse(client: client, data: audio, mimeType: "audio/mpeg", statusCode: 200)
    }

    /// Fish Audio TTS. Returns raw audio bytes on success.
    private func handleFishAudioRequest(client: Int32, endpoint: String, secret: String, model: String, voice: String, text: String) {
        guard let url = URL(string: endpoint) else {
            sendResponse(client: client, data: Data("{\"error\":\"Bad endpoint\"}".utf8), mimeType: "application/json", statusCode: 400)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue(model.isEmpty ? "s1" : model, forHTTPHeaderField: "model")

        var payload: [String: Any] = [
            "text": text,
            "format": "mp3",
            "mp3_bitrate": 128,
            "chunk_length": 200,
            "normalize": true,
            "latency": "normal",
        ]
        // `reference_id` selects a cloned or preset voice; without one Fish uses its
        // default voice, which is still a valid request.
        if !voice.isEmpty {
            payload["reference_id"] = voice
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let result = performBlockingRequest(request)
        guard result.statusCode == 200 else {
            logger.error("[Proxy] Fish Audio error \(result.statusCode)")
            sendResponse(client: client, data: result.data, mimeType: "application/json", statusCode: result.statusCode)
            return
        }
        guard !result.data.isEmpty else {
            sendResponse(client: client, data: Data("{\"error\":\"Fish Audio returned no audio\"}".utf8), mimeType: "application/json", statusCode: 502)
            return
        }

        logger.info("[Proxy] Fish Audio ok: \(result.data.count) bytes")
        sendResponse(client: client, data: result.data, mimeType: "audio/mpeg", statusCode: 200)
    }

    /// MiniMax hands audio back as a hex string rather than base64.
    static func dataFromHexString(_ hex: String) -> Data? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            guard let next = cleaned.index(index, offsetBy: 2, limitedBy: cleaned.endIndex) else { return nil }
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "css": return "text/css"
        case "js": return "application/javascript"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "wasm": return "application/wasm"
        case "vrm", "glb": return "model/gltf-binary"
        case "vrma": return "model/gltf-binary"
        case "mp3": return "audio/mpeg"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Amica Full View

struct AmicaFullView: UIViewRepresentable {
    var memoryStore: MemoryStore
    var onCoordinatorReady: ((Coordinator) -> Void)?

    func makeCoordinator() -> Coordinator {
        let coord = Coordinator(memoryStore: memoryStore)
        DispatchQueue.main.async { onCoordinatorReady?(coord) }
        return coord
    }

    func makeUIView(context: Context) -> WKWebView {
        // Start local server
        AmicaLocalServer.shared.start()
        let port = AmicaLocalServer.shared.port

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let contentController = config.userContentController
        contentController.add(context.coordinator, name: "nativeAI")

        let interactionBlockerScript = WKUserScript(
            source: """
            (function() {
                if (window.__scowldInteractionBlockerInstalled) return;
                window.__scowldInteractionBlockerInstalled = true;

                function installStyle() {
                    try {
                        if (document.getElementById('scowld-interaction-blocker-style')) return;
                        var style = document.createElement('style');
                        style.id = 'scowld-interaction-blocker-style';
                        style.textContent = '*{-webkit-touch-callout:none!important;-webkit-user-select:none!important;user-select:none!important;-webkit-user-drag:none!important}::selection{background:transparent!important;color:inherit!important}';
                        (document.head || document.documentElement).appendChild(style);
                    } catch(e) {}
                }

                function preventNativeMenu(event) {
                    event.preventDefault();
                    event.stopPropagation();
                    return false;
                }

                ['contextmenu', 'selectstart', 'dragstart', 'copy', 'cut'].forEach(function(type) {
                    document.addEventListener(type, preventNativeMenu, true);
                });
                installStyle();
                document.addEventListener('DOMContentLoaded', installStyle);
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        contentController.addUserScript(interactionBlockerScript)

        // Inject native config before page loads
        let defaults = UserDefaults.standard
        HostedServiceConfig.applyBYOKDefaults()
        let ttsBackendRaw = defaults.string(forKey: "amica_tts_backend") ?? TTSBackend.elevenLabs.rawValue
        let ttsBackend = TTSBackend(rawValue: ttsBackendRaw) ?? .elevenLabs
        let ttsWebBackend = ttsBackend.webBackendKey
        let ttsProxyPath = ttsBackend.proxyPath
        let ttsModel = TTSBackend.selectedModel(for: ttsBackend)
        let ttsVoice = TTSBackend.selectedVoice(for: ttsBackend)
        let sttBackend = defaults.string(forKey: "amica_stt_backend") ?? STTBackend.nativeIOS.rawValue
        let visionEnabledJS = "true"
        let visionBackend = "native_ios"
        let elevenLabsVoiceId = HostedServiceConfig.selectedElevenLabsVoiceID()
        let elevenLabsModel = TTSBackend.selectedModel(for: .elevenLabs)
        let keychainSentinel = TTSBackend.keychainSentinel
        let characterName = CharacterPack.resolveCharacterName()
        let selectedAvatar = defaults.string(forKey: "selected_avatar") ?? "AvatarSample_A"
        let avatarURL = AmicaAvatarSelection.vrmURL(for: selectedAvatar)
        let sceneBackgroundURL = AmicaSceneSettings.backgroundURL(defaults: defaults)
        let extraVrmsJS = AmicaUserMedia.importedAvatarPublicPaths()
            .map { "'\($0)'" }
            .joined(separator: ", ")
        let proactive = ProactiveChatSettings.snapshot(defaults: defaults)

        let settingsScript = WKUserScript(
            source: """
            // Clear ALL old cached config from localStorage
            try {
                var keys = Object.keys(localStorage);
                for (var i = 0; i < keys.length; i++) {
                    if (keys[i].startsWith('chatvrm_')) {
                        localStorage.removeItem(keys[i]);
                    }
                }
                localStorage.setItem('chatvrm_tts_muted', 'false');
                localStorage.setItem('chatvrm_tts_backend', '\(ttsWebBackend)');
                localStorage.setItem('chatvrm_elevenlabs_voiceid', '\(elevenLabsVoiceId)');
                localStorage.setItem('chatvrm_elevenlabs_model', '\(elevenLabsModel)');
                localStorage.setItem('chatvrm_rvc_enabled', 'false');
                localStorage.setItem('chatvrm_amica_life_enabled', '\(proactive.enabledJS)');
            } catch(e) {}
            window.__nativeConfig = {
                chatbot_backend: 'native_ios',
                tts_muted: 'false',
                tts_backend: '\(ttsWebBackend)',
                stt_backend: '\(sttBackend)',
                vision_backend: '\(visionBackend)',
                elevenlabs_apikey: '\(keychainSentinel)',
                elevenlabs_voiceid: '\(elevenLabsVoiceId)',
                elevenlabs_model: '\(elevenLabsModel)',
                rvc_enabled: 'false',
                amica_life_enabled: '\(proactive.enabledJS)',
                time_before_idle_sec: '\(proactive.idleThreshold)',
                min_time_interval_sec: '\(proactive.minInterval)',
                max_time_interval_sec: '\(proactive.maxInterval)',
                time_to_sleep_sec: '\(proactive.sleepAfter)',
                reasoning_engine_enabled: 'false',
                external_api_enabled: 'false',
                idle_text_prompt: '',
                openai_tts_apikey: '\(keychainSentinel)',
                openai_tts_url: '\(ttsProxyPath)',
                openai_tts_model: '\(ttsModel)',
                openai_tts_voice: '\(ttsVoice)',
                name: '\(characterName)',
                system_prompt: 'You are \(characterName), a warm, cheerful, and expressive AI companion.',
                bg_url: '\(sceneBackgroundURL)',
                bg_color: '',
                vrm_url: '\(avatarURL)'
            };
            // Imported models, for the page's own model list. Without this the
            // built-in list has no entry matching `vrm_url` and the page loads
            // nothing at all.
            window.__scowldExtraVrms = [\(extraVrmsJS)];
            window.__scowldVisionEnabled = \(visionEnabledJS);
            // Force full screen coverage
            var meta = document.createElement('meta');
            meta.name = 'viewport';
            meta.content = 'width=device-width, initial-scale=1.0, viewport-fit=cover';
            document.head?.appendChild(meta);
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(settingsScript)

        // Console forwarding
        let consoleScript = WKUserScript(
            source: """
            (function() {
                var origLog = console.log, origError = console.error;
                function send(level, args) {
                    try { window.webkit.messageHandlers.nativeAI.postMessage(JSON.stringify({
                        type: 'console', level: level, message: Array.from(args).map(String).join(' ')
                    })); } catch(e) {}
                }
                console.log = function() { send('log', arguments); origLog.apply(console, arguments); };
                console.error = function() { send('error', arguments); origError.apply(console, arguments); };
                window.onerror = function(msg, url, line) { send('error', ['JS: ' + msg + ' at ' + url + ':' + line]); };
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        contentController.addUserScript(consoleScript)

        // Force front camera and hide Amica's webcam preview without stopping the stream.
        let cameraScript = WKUserScript(
            source: """
            (function() {
                function applyHiddenPreviewStyle(element) {
                    if (!element || !element.style) return;
                    element.setAttribute('data-native-webcam-hidden', 'true');
                    element.style.setProperty('position', 'fixed', 'important');
                    element.style.setProperty('top', '-10000px', 'important');
                    element.style.setProperty('left', '-10000px', 'important');
                    element.style.setProperty('right', 'auto', 'important');
                    element.style.setProperty('bottom', 'auto', 'important');
                    element.style.setProperty('width', '1px', 'important');
                    element.style.setProperty('height', '1px', 'important');
                    element.style.setProperty('opacity', '0', 'important');
                    element.style.setProperty('visibility', 'hidden', 'important');
                    element.style.setProperty('pointer-events', 'none', 'important');
                    element.style.setProperty('z-index', '-1', 'important');
                    element.style.setProperty('overflow', 'hidden', 'important');
                }

                function hideWebcamPreview() {
                    var count = 0;
                    document.querySelectorAll('video').forEach(function(video) {
                        applyHiddenPreviewStyle(video);
                        if (video.parentElement && !video.parentElement.querySelector('canvas')) {
                            applyHiddenPreviewStyle(video.parentElement);
                        }
                        count += 1;
                    });
                    return count;
                }

                window.__hideWebcamPreview = hideWebcamPreview;
                window.__scowldCameraEnabled = window.__scowldCameraEnabled !== false;

                function findCameraVideo() {
                    var videos = Array.prototype.slice.call(document.querySelectorAll('video'));
                    return videos.find(function(video) {
                        return video &&
                            video.srcObject &&
                            video.readyState >= 2 &&
                            video.videoWidth > 0 &&
                            video.videoHeight > 0;
                    }) || null;
                }

                window.__captureNativeVisionFrame = function() {
                    try {
                        if (window.__scowldCameraEnabled === false) return null;
                        var video = findCameraVideo();
                        if (!video) return window.__latestWebcamFrame || null;
                        var canvas = window.__nativeVisionCanvas || document.createElement('canvas');
                        window.__nativeVisionCanvas = canvas;
                        var maxSide = 512;
                        var scale = Math.min(1, maxSide / Math.max(video.videoWidth, video.videoHeight));
                        canvas.width = Math.max(1, Math.round(video.videoWidth * scale));
                        canvas.height = Math.max(1, Math.round(video.videoHeight * scale));
                        var ctx = canvas.getContext('2d');
                        ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
                        var frame = canvas.toDataURL('image/jpeg', 0.65).replace(/^data:image\\/jpeg;base64,/, '');
                        window.__latestWebcamFrame = frame;
                        window.__lastNativeVisionFrameAt = Date.now();
                        return frame;
                    } catch (e) {
                        return window.__latestWebcamFrame || null;
                    }
                };

                function patchNativeAIForVision() {
                    try {
                        if (window.__nativeAIVisionPatchInstalled) return true;
                        var nativeAI = window.webkit &&
                            window.webkit.messageHandlers &&
                            window.webkit.messageHandlers.nativeAI;
                        if (!nativeAI || !nativeAI.postMessage) return false;
                        var originalPostMessage = nativeAI.postMessage.bind(nativeAI);
                        nativeAI.postMessage = function(payload) {
                            try {
                                var body = typeof payload === 'string' ? JSON.parse(payload) : payload;
                                var lastText = '';
                                if (body && Array.isArray(body.messages) && body.messages.length) {
                                    var lastMessage = body.messages[body.messages.length - 1];
                                    lastText = String((lastMessage && lastMessage.content) || '').toLowerCase();
                                }
                                var wantsVision = /(see|seeing|look|looking|camera|photo|picture|image|screen|wearing|holding|behind me|in front of me|around me|what am i|do i look)/.test(lastText);
                                if (body &&
                                    body.type === 'chat' &&
                                    !body.imageData &&
                                    wantsVision &&
                                    window.__scowldVisionEnabled !== false &&
                                    window.__scowldCameraEnabled !== false) {
                                    var frame = window.__captureNativeVisionFrame
                                        ? window.__captureNativeVisionFrame()
                                        : window.__latestWebcamFrame;
                                    if (frame) {
                                        body.imageData = frame;
                                        return originalPostMessage(JSON.stringify(body));
                                    }
                                }
                            } catch (e) {}
                            return originalPostMessage(payload);
                        };
                        window.__nativeAIVisionPatchInstalled = true;
                        return true;
                    } catch (e) {
                        return false;
                    }
                }

                function startPreviewHider() {
                    hideWebcamPreview();
                    window.__captureNativeVisionFrame && window.__captureNativeVisionFrame();
                    if (window.__webcamPreviewObserver) return;
                    var root = document.documentElement || document.body;
                    if (!root || !window.MutationObserver) return;
                    window.__webcamPreviewObserver = new MutationObserver(function() {
                        hideWebcamPreview();
                    });
                    window.__webcamPreviewObserver.observe(root, { childList: true, subtree: true });
                }

                startPreviewHider();
                document.addEventListener('DOMContentLoaded', startPreviewHider);
                patchNativeAIForVision();
                setTimeout(patchNativeAIForVision, 500);
                setInterval(function() {
                    if (window.__scowldCameraEnabled !== false && window.__captureNativeVisionFrame) {
                        window.__captureNativeVisionFrame();
                    }
                }, 1000);

                if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) return;
                var origGetUserMedia = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
                navigator.mediaDevices.getUserMedia = function(constraints) {
                    if (constraints && constraints.video) {
                        if (typeof constraints.video === 'boolean') {
                            constraints.video = { facingMode: { exact: 'user' } };
                        } else if (typeof constraints.video === 'object') {
                            constraints.video.facingMode = { exact: 'user' };
                        }
                    }
                    return origGetUserMedia(constraints).then(function(stream) {
                        setTimeout(hideWebcamPreview, 0);
                        setTimeout(function() { window.__captureNativeVisionFrame && window.__captureNativeVisionFrame(); }, 100);
                        setTimeout(hideWebcamPreview, 100);
                        setTimeout(hideWebcamPreview, 500);
                        return stream;
                    });
                };
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(cameraScript)

        // Keep Amica's WebAudio graph alive for TTS audio playback and lip sync.
        let audioResumeScript = WKUserScript(
            source: """
            (function() {
                if (window.__scowldAudioPatchInstalled) {
                    return;
                }
                window.__scowldAudioPatchInstalled = true;

                var OriginalAudioContext = window.AudioContext || window.webkitAudioContext;
                window.__allScowldAudioContexts = window.__allScowldAudioContexts || [];
                window.__activeAudioCount = 0;
                window.__activeScowldAudioSources = window.__activeScowldAudioSources || new Set();
                var _ttsDoneTimer = null;

                function rememberContext(ctx) {
                    if (!ctx) {
                        return;
                    }
                    if (window.__allScowldAudioContexts.indexOf(ctx) === -1) {
                        window.__allScowldAudioContexts.push(ctx);
                    }
                }

                function resumeContext(ctx) {
                    try {
                        if (!ctx || ctx.state === 'closed') {
                            return;
                        }
                        rememberContext(ctx);
                        if (ctx.state !== 'running' && typeof ctx.resume === 'function') {
                            ctx.resume().then(function() {
                                console.log('[Audio] Resumed AudioContext, state: ' + ctx.state);
                            }).catch(function(e) {
                                console.warn('[Audio] AudioContext resume failed: ' + e);
                            });
                        }
                    } catch(e) {
                        console.warn('[Audio] resumeContext failed: ' + e);
                    }
                }

                function resumeAll() {
                    try {
                        rememberContext(window._audioContext);
                        rememberContext(window.audioContext);
                        (window.__allScowldAudioContexts || []).forEach(resumeContext);
                    } catch(e) {
                        console.warn('[Audio] resumeAll failed: ' + e);
                    }
                }
                window.__resumeScowldAudioContexts = resumeAll;

                if (OriginalAudioContext) {
                    var WrappedAudioContext = function(opts) {
                        var ctx = new OriginalAudioContext(opts);
                        rememberContext(ctx);
                        console.log('[Audio] New AudioContext created, state: ' + ctx.state);
                        return ctx;
                    };
                    Object.getOwnPropertyNames(OriginalAudioContext).forEach(function(k) {
                        try {
                            if (k !== 'prototype') {
                                WrappedAudioContext[k] = OriginalAudioContext[k];
                            }
                        } catch(e) {}
                    });
                    WrappedAudioContext.prototype = OriginalAudioContext.prototype;
                    window.AudioContext = WrappedAudioContext;
                    window.webkitAudioContext = WrappedAudioContext;
                }

                document.addEventListener('touchstart', resumeAll, {once: false});
                document.addEventListener('click', resumeAll, {once: false});
                setInterval(function() {
                    (window.__allScowldAudioContexts || []).forEach(resumeContext);
                }, 1000);

                function notifyTTSDone() {
                    window.__activeAudioCount--;
                    if (window.__activeAudioCount <= 0) {
                        window.__activeAudioCount = 0;
                        // Short debounce so controls unlock quickly after speech finishes.
                        if (_ttsDoneTimer) clearTimeout(_ttsDoneTimer);
                        _ttsDoneTimer = setTimeout(function() {
                            if (window.__activeAudioCount <= 0) {
                                try {
                                    window.webkit.messageHandlers.nativeAI.postMessage(JSON.stringify({type: 'tts_done'}));
                                } catch(e) {}
                            }
                        }, 250);
                    }
                }
                window.__stopScowldAudio = function() {
                    if (_ttsDoneTimer) clearTimeout(_ttsDoneTimer);
                    _ttsDoneTimer = null;
                    window.__activeAudioCount = 0;
                    try {
                        document.querySelectorAll('audio').forEach(function(a) {
                            try { a.pause(); } catch(e) {}
                            try { a.currentTime = 0; } catch(e) {}
                        });
                    } catch(e) {}
                    try {
                        (window.__activeScowldAudioSources || new Set()).forEach(function(src) {
                            try { src.stop(0); } catch(e) {}
                            try { src.disconnect(); } catch(e) {}
                        });
                        window.__activeScowldAudioSources.clear();
                    } catch(e) {}
                    try {
                        if (window.speechSynthesis) window.speechSynthesis.cancel();
                    } catch(e) {}
                };

                if (window.HTMLAudioElement && HTMLAudioElement.prototype && HTMLAudioElement.prototype.play) {
                    var _origAudioPlay = HTMLAudioElement.prototype.play;
                    HTMLAudioElement.prototype.play = function() {
                        var self = this;
                        window.__activeAudioCount++;
                        window.__activeScowldAudioSources.add(self);
                        function cleanupAudioElement() {
                            window.__activeScowldAudioSources.delete(self);
                            notifyTTSDone();
                        }
                        self.addEventListener('ended', cleanupAudioElement, {once: true});
                        self.addEventListener('error', cleanupAudioElement, {once: true});
                        return _origAudioPlay.apply(self, arguments);
                    };
                }

                if (OriginalAudioContext && OriginalAudioContext.prototype && OriginalAudioContext.prototype.createBufferSource) {
                    var _origCreateBS = OriginalAudioContext.prototype.createBufferSource;
                    OriginalAudioContext.prototype.createBufferSource = function() {
                        rememberContext(this);
                        var src = _origCreateBS.apply(this, arguments);
                        var _origStart = src.start.bind(src);
                        src.start = function() {
                            resumeContext(src.context);
                            window.__activeAudioCount++;
                            window.__activeScowldAudioSources.add(src);
                            src.addEventListener('ended', function() {
                                window.__activeScowldAudioSources.delete(src);
                                notifyTTSDone();
                            }, {once: true});
                            return _origStart.apply(src, arguments);
                        };
                        return src;
                    };
                }

                setTimeout(resumeAll, 0);
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(audioResumeScript)

        // Viewer bridge: exposes gesture / expression / camera / background control.
        // Must be registered before the scene script below, which uses its helpers.
        contentController.addUserScript(WKUserScript(
            source: AmicaViewerBridge.bootstrapScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        // Apply the saved background, subject offset and zoom range once the
        // viewer exists (it is created asynchronously by the web app).
        contentController.addUserScript(WKUserScript(
            source: AmicaViewerBridge.initialSceneScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.underPageBackgroundColor = .black
        webView.allowsLinkPreview = false
        webView.scrollView.bounces = false
        // The 3D viewer implements its own pinch-zoom and pan through
        // OrbitControls. WKWebView's built-in scroll/pinch recognizers would
        // swallow those two-finger gestures, so both are turned off here and the
        // touches are delivered to the page instead.
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        // Load from local HTTP server (not custom scheme — so fetch() works with CORS)
        if port > 0 {
            let url = URL(string: "http://127.0.0.1:\(port)/index.html")!
            logger.info("[Amica] Loading from \(url)")
            webView.load(URLRequest(url: url))
        }

        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    // MARK: - Coordinator

    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        weak var webView: WKWebView?
        let memoryStore: MemoryStore
        let speechManager = SpeechManager()

        private var settingsObserver: NSObjectProtocol?
        private var isRuntimeActive = true
        private var runtimeGeneration = 0

        init(memoryStore: MemoryStore) {
            self.memoryStore = memoryStore
            super.init()
            settingsObserver = NotificationCenter.default.addObserver(
                forName: .amicaSettingsChanged, object: nil, queue: .main
            ) { [weak self] _ in
                self?.pushUpdatedConfig()
            }
        }

        deinit {
            if let observer = settingsObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func setRuntimeActive(_ active: Bool) {
            if active {
                isRuntimeActive = true
            } else {
                cancelRuntimeWork()
            }
        }

        func cancelRuntimeWork() {
            runtimeGeneration += 1
            isRuntimeActive = false
            speechManager.stopSpeaking()
            stopWebAudio()
        }

        private func canDeliver(_ generation: Int) -> Bool {
            isRuntimeActive && generation == runtimeGeneration
        }

        private func stopWebAudio() {
            webView?.evaluateJavaScript("""
                (function() {
                    if (window.__stopScowldAudio) {
                        window.__stopScowldAudio();
                    }
                    try {
                        document.querySelectorAll('audio').forEach(function(a) {
                            try { a.pause(); } catch(e) {}
                            try { a.currentTime = 0; } catch(e) {}
                        });
                    } catch(e) {}
                    try {
                        if (window.speechSynthesis) window.speechSynthesis.cancel();
                    } catch(e) {}
                })();
            """)
        }

        private func pushUpdatedConfig() {
            let defaults = UserDefaults.standard
            HostedServiceConfig.applyBYOKDefaults()
            let ttsBackendRaw = defaults.string(forKey: "amica_tts_backend") ?? TTSBackend.elevenLabs.rawValue
            let ttsBackend = TTSBackend(rawValue: ttsBackendRaw) ?? .elevenLabs
            let ttsWebBackend = ttsBackend.webBackendKey
            let ttsProxyPath = ttsBackend.proxyPath
            let ttsModel = TTSBackend.selectedModel(for: ttsBackend)
            let ttsVoice = TTSBackend.selectedVoice(for: ttsBackend)
            let sttBackend = defaults.string(forKey: "amica_stt_backend") ?? STTBackend.nativeIOS.rawValue
            let elevenLabsVoiceId = HostedServiceConfig.selectedElevenLabsVoiceID()
            let elevenLabsModel = TTSBackend.selectedModel(for: .elevenLabs)
            let keychainSentinel = TTSBackend.keychainSentinel
            let visionEnabledJS = "true"
            let visionBackend = "native_ios"
            let characterName = CharacterPack.resolveCharacterName()
            let selectedAvatar = defaults.string(forKey: "selected_avatar") ?? "AvatarSample_A"
            let avatarURL = AmicaAvatarSelection.vrmURL(for: selectedAvatar)
            let sceneBackgroundURL = AmicaSceneSettings.backgroundURL(defaults: defaults)
            let extraVrmsJS = AmicaUserMedia.importedAvatarPublicPaths()
                .map { "'\($0)'" }
                .joined(separator: ", ")
            let proactive = ProactiveChatSettings.snapshot(defaults: defaults)

            let js = """
                try {
                    localStorage.setItem('chatvrm_tts_muted', 'false');
                    localStorage.setItem('chatvrm_tts_backend', '\(ttsWebBackend)');
                    localStorage.setItem('chatvrm_elevenlabs_voiceid', '\(elevenLabsVoiceId)');
                    localStorage.setItem('chatvrm_elevenlabs_model', '\(elevenLabsModel)');
                    localStorage.setItem('chatvrm_rvc_enabled', 'false');
                    localStorage.setItem('chatvrm_amica_life_enabled', '\(proactive.enabledJS)');
                } catch(e) {}
                window.__nativeConfig = {
                    chatbot_backend: 'native_ios',
                    tts_muted: 'false',
                    tts_backend: '\(ttsWebBackend)',
                    stt_backend: '\(sttBackend)',
                    vision_backend: '\(visionBackend)',
                    elevenlabs_apikey: '\(keychainSentinel)',
                    elevenlabs_voiceid: '\(elevenLabsVoiceId)',
                    elevenlabs_model: '\(elevenLabsModel)',
                    rvc_enabled: 'false',
                    amica_life_enabled: '\(proactive.enabledJS)',
                    time_before_idle_sec: '\(proactive.idleThreshold)',
                    min_time_interval_sec: '\(proactive.minInterval)',
                    max_time_interval_sec: '\(proactive.maxInterval)',
                    time_to_sleep_sec: '\(proactive.sleepAfter)',
                    reasoning_engine_enabled: 'false',
                    external_api_enabled: 'false',
                    idle_text_prompt: '',
                    openai_tts_apikey: '\(keychainSentinel)',
                    openai_tts_url: '\(ttsProxyPath)',
                    openai_tts_model: '\(ttsModel)',
                    openai_tts_voice: '\(ttsVoice)',
                    name: '\(characterName)',
                    system_prompt: 'You are \(characterName), a warm, cheerful, and expressive AI companion.',
                    bg_url: '\(sceneBackgroundURL)',
                    bg_color: '',
                    vrm_url: '\(avatarURL)'
                };
                window.__scowldExtraVrms = [\(extraVrmsJS)];
                window.__scowldVisionEnabled = \(visionEnabledJS);
            """
            // Update the user script with new config, then reload
            if let webView {
                let contentController = webView.configuration.userContentController
                let newScript = WKUserScript(
                    source: js,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
                contentController.addUserScript(newScript)
                webView.reload()
            }
            logger.info("[Amica] Updated config script and reloaded WebView")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            logger.info("[Amica] Page loaded")
            // Force full-screen coverage via CSS
            webView.evaluateJavaScript("""
                var s = document.createElement('style');
                s.textContent = 'html, body { margin: 0; padding: 0; width: 100%; height: 100%; } body { padding: env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left); box-sizing: border-box; } canvas { position: fixed !important; top: 0 !important; left: 0 !important; width: 100vw !important; height: 100vh !important; }';
                document.head.appendChild(s);
                var vm = document.querySelector('meta[name=viewport]');
                if (vm) vm.content = 'width=device-width, initial-scale=1.0, viewport-fit=cover, user-scalable=no';
            """)
            // Enable front camera by default, no preview
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                webView.evaluateJavaScript("""
                    (function enableCam() {
                        if (window.__toggleWebcam) {
                            window.__scowldCameraEnabled = true;
                            window.__toggleWebcam(true);
                            // Hide preview but keep the camera stream alive.
                            (function hidePreview() {
                                var hiddenCount = window.__hideWebcamPreview ? window.__hideWebcamPreview() : 0;
                                if (window.__captureNativeVisionFrame) {
                                    window.__captureNativeVisionFrame();
                                }
                                if (hiddenCount > 0) {
                                    // Notify native that app is ready (preview hidden) after 1s buffer
                                    setTimeout(function() {
                                        try {
                                            window.webkit.messageHandlers.nativeAI.postMessage(JSON.stringify({type: 'app_ready'}));
                                        } catch(e) {}
                                    }, 1000);
                                }
                                setTimeout(hidePreview, 2000);
                            })();
                        } else {
                            setTimeout(enableCam, 1000);
                        }
                    })();
                """)
            }
            // Zoom out camera after a delay (viewer needs time to initialize)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                webView.evaluateJavaScript("""
                    if (window.__viewer?.camera) {
                        window.__viewer.camera.position.z += 0.5;
                    }
                    // Try Amica's resetCamera with offset
                    try {
                        var cam = document.querySelector('canvas')?.__three_camera;
                        if (!cam) {
                            // Find camera in Three.js scene
                            var scenes = Object.values(window).filter(v => v && v.isScene);
                        }
                    } catch(e) {}
                """)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            logger.info("[Amica] Navigation failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            logger.info("[Amica] Provisional navigation failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            return .allow
        }

        func webView(_ webView: WKWebView,
                     requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo,
                     type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            logger.info("[Amica] Auto-granting camera permission")
            decisionHandler(.grant)
        }

        func webView(_ webView: WKWebView,
                     contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                     completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
            completionHandler(nil)
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? String,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { return }

            switch type {
            case "chat":
                guard let callbackId = json["callbackId"] as? String,
                      let messages = json["messages"] as? [[String: String]] else { return }
                guard isRuntimeActive else { return }
                let imageData = json["imageData"] as? String
                let generation = runtimeGeneration
                Task { await handleChatRequest(callbackId: callbackId, messages: messages, imageData: imageData, generation: generation) }
            case "tts_elevenlabs":
                guard let callbackId = json["callbackId"] as? String,
                      let voiceId = json["voiceId"] as? String,
                      let bodyStr = json["body"] as? String else { return }
                guard isRuntimeActive else { return }
                let generation = runtimeGeneration
                Task { await handleElevenLabsTTS(callbackId: callbackId, voiceId: voiceId, body: bodyStr, generation: generation) }
            case "speak":
                if isRuntimeActive, let text = json["text"] as? String {
                    speechManager.speak(text)
                }
            case "tts_done":
                guard isRuntimeActive else { return }
                logger.info("[Amica] TTS playback finished")
                NotificationCenter.default.post(name: .ttsDone, object: nil)
            case "app_ready":
                logger.info("[Amica] App ready — preview hidden")
                NotificationCenter.default.post(name: .appReady, object: nil)
            case "console":
                let level = json["level"] as? String ?? "log"
                let msg = json["message"] as? String ?? ""
                logger.info("[Amica-JS] [\(level)] \(msg)")
                DebugLog.shared.add("[\(level)] \(msg)")
            default:
                break
            }
        }

        // MARK: Native AI

        private func handleChatRequest(callbackId: String, messages: [[String: String]], imageData: String? = nil, generation: Int) async {
            guard canDeliver(generation) else { return }

            let chatMessages = messages.compactMap { dict -> ChatMessage? in
                guard let roleStr = dict["role"], let content = dict["content"] else { return nil }
                let role: MessageRole = roleStr == "user" ? .user : roleStr == "assistant" ? .assistant : .system
                return ChatMessage(role: role, content: content)
            }

            // Build system prompt with active saved-chat context and character name
            let contextBuilder = ContextBuilder(memoryStore: memoryStore)
            let systemPrompt = contextBuilder.buildSystemPrompt()

            do {
                let runtimeProvider = try buildCurrentProvider()
                let response: String
                if runtimeProvider.supportsVision,
                   let imageBase64 = imageData,
                   !imageBase64.isEmpty,
                   let imgData = Data(base64Encoded: imageBase64),
                   let image = UIImage(data: imgData) {
                    // Vision request — send image with the message
                    logger.info("[Amica] Vision request with image: \(imgData.count) bytes")
                    response = try await runtimeProvider.provider.generateWithVision(
                        messages: chatMessages, systemPrompt: systemPrompt, image: image
                    )
                } else {
                    response = try await runtimeProvider.provider.generate(messages: chatMessages, systemPrompt: systemPrompt)
                }

                let finalResponse = response
                let lastUserMessage = chatMessages.last(where: { $0.role == .user })?.content ?? ""

                await MainActor.run {
                    guard self.canDeliver(generation) else { return }
                    deliverResponse(callbackId: callbackId, response: finalResponse)
                    memoryStore.saveExchange(
                        userMessage: lastUserMessage,
                        assistantResponse: finalResponse
                    )
                }
            } catch {
                await MainActor.run {
                    guard self.canDeliver(generation) else { return }
                    deliverError(callbackId: callbackId, error: error.localizedDescription)
                }
            }
        }

        // MARK: - Native ElevenLabs TTS

        private func handleElevenLabsTTS(callbackId: String, voiceId: String, body: String, generation: Int) async {
            guard canDeliver(generation) else { return }
            let request: URLRequest
            do {
                request = try ElevenLabsBYOKRequestBuilder.makeRequest(
                    voiceID: voiceId.isEmpty ? HostedServiceConfig.selectedElevenLabsVoiceID() : voiceId,
                    body: Data(body.utf8)
                )
            } catch {
                logger.error("[TTS] ElevenLabs BYOK setup error: \(error.localizedDescription)")
                await MainActor.run {
                    guard self.canDeliver(generation) else { return }
                    let escaped = error.localizedDescription.replacingOccurrences(of: "'", with: "\\'")
                    webView?.evaluateJavaScript("window['__ttsError_\(callbackId)'] && window['__ttsError_\(callbackId)']('\(escaped)')")
                    notifyTTSFailed()
                }
                return
            }

            logger.info("[TTS] ElevenLabs BYOK request: voice=\(voiceId) bodyLen=\(body.count)")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    await MainActor.run {
                        guard self.canDeliver(generation) else { return }
                        notifyTTSFailed()
                    }
                    return
                }

                if httpResponse.statusCode == 200 {
                    let base64 = data.base64EncodedString()
                    logger.info("[TTS] ElevenLabs BYOK success: \(data.count) bytes")
                    await MainActor.run {
                        guard self.canDeliver(generation) else { return }
                        guard let webView else {
                            notifyTTSFailed()
                            return
                        }
                        ScowldAudioSession.configureAmicaWebAudioPlayback()
                        let callbackScript = """
                        (function() {
                            if (window.__resumeScowldAudioContexts) {
                                window.__resumeScowldAudioContexts();
                            }
                            var callback = window['__ttsCallback_\(callbackId)'];
                            if (!callback) {
                                console.error('[ScowldTTS] Missing callback \(callbackId)');
                                return false;
                            }
                            try {
                                callback('\(base64)');
                                if (window.__resumeScowldAudioContexts) {
                                    setTimeout(window.__resumeScowldAudioContexts, 0);
                                    setTimeout(window.__resumeScowldAudioContexts, 120);
                                    setTimeout(window.__resumeScowldAudioContexts, 400);
                                }
                                console.log('[ScowldTTS] Delivered ElevenLabs audio \(data.count) bytes');
                                return true;
                            } catch (e) {
                                console.error('[ScowldTTS] Callback failed: ' + e);
                                return false;
                            }
                        })();
                        """
                        webView.evaluateJavaScript(callbackScript) { result, error in
                            if error != nil {
                                self.notifyTTSFailed()
                                return
                            }
                            if (result as? Bool) == true {
                                self.notifyTTSPlaybackStarted(byteCount: data.count)
                            } else {
                                self.notifyTTSFailed()
                            }
                        }
                    }
                } else {
                    let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                    logger.error("[TTS] ElevenLabs BYOK error \(httpResponse.statusCode): \(errorBody)")
                    await MainActor.run {
                        guard self.canDeliver(generation) else { return }
                        let detail = errorBody.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\n", with: " ").prefix(200)
                        webView?.evaluateJavaScript("window['__ttsError_\(callbackId)'] && window['__ttsError_\(callbackId)']('ElevenLabs \(httpResponse.statusCode): \(detail)')")
                        notifyTTSFailed()
                    }
                }
            } catch {
                logger.error("[TTS] ElevenLabs BYOK network error: \(error.localizedDescription)")
                await MainActor.run {
                    guard self.canDeliver(generation) else { return }
                    let escaped = error.localizedDescription.replacingOccurrences(of: "'", with: "\\'")
                    webView?.evaluateJavaScript("window['__ttsError_\(callbackId)'] && window['__ttsError_\(callbackId)']('\(escaped)')")
                    notifyTTSFailed()
                }
            }
        }

        private func notifyTTSPlaybackStarted(byteCount: Int) {
            NotificationCenter.default.post(
                name: .ttsPlaybackStarted,
                object: estimatedTTSPlaybackDelay(byteCount: byteCount)
            )
        }

        private func notifyTTSFailed() {
            NotificationCenter.default.post(name: .ttsFailed, object: nil)
        }

        private func estimatedTTSPlaybackDelay(byteCount: Int) -> TimeInterval {
            // Hosted ElevenLabs route requests mp3_44100_128, so 16 KB is roughly one second.
            let estimatedAudioSeconds = Double(byteCount) / 16_000
            return min(max(estimatedAudioSeconds + 2, 3), 60)
        }

        private func deliverResponse(callbackId: String, response: String) {
            let responseForAmica = ttsReadyResponse(response)
            let escaped = responseForAmica
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "")
            webView?.evaluateJavaScript("window.nativeAIResponse && window.nativeAIResponse('\(callbackId)', '\(escaped)')")
            NotificationCenter.default.post(name: .aiResponseReady, object: response)
        }

        private func ttsReadyResponse(_ response: String) -> String {
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return response }
            if trimmed.range(of: #"[.!?。！？]$"#, options: .regularExpression) != nil {
                return response
            }
            return response + "."
        }

        private func deliverError(callbackId: String, error: String) {
            let escaped = error.replacingOccurrences(of: "'", with: "\\'")
            webView?.evaluateJavaScript("window.nativeAIError && window.nativeAIError('\(callbackId)', '\(escaped)')")
        }

        private func buildCurrentProvider() throws -> RuntimeLLMProvider {
            HostedServiceConfig.applyBYOKDefaults()
            let defaults = UserDefaults.standard
            let providerID = defaults.string(forKey: "selectedProvider") ?? AIProvider.gemini.rawValue
            let provider = AIProvider(rawValue: providerID) ?? .gemini
            let model = HostedServiceConfig.selectedModel(for: provider)

            switch provider {
            case .gemini:
                return RuntimeLLMProvider(
                    provider: GeminiProvider(apiKey: try apiKey(for: provider), model: model),
                    supportsVision: provider.supportsVision
                )
            case .openai:
                return RuntimeLLMProvider(
                    provider: OpenAIProvider(apiKey: try apiKey(for: provider), model: model),
                    supportsVision: provider.supportsVision
                )
            case .claude:
                return RuntimeLLMProvider(
                    provider: ClaudeProvider(apiKey: try apiKey(for: provider), model: model),
                    supportsVision: provider.supportsVision
                )
            case .ollama:
                let baseURL = KeychainManager.load(key: OllamaConfig.keychainURLKey) ?? OllamaConfig.defaultURL
                return RuntimeLLMProvider(
                    provider: OllamaProvider(baseURL: baseURL, model: model),
                    supportsVision: provider.supportsVision
                )
            case .groq, .openRouter, .xai, .togetherAI, .huggingFace, .veniceAI, .moonshot, .deepseek, .glm:
                guard let baseURL = provider.baseURL else {
                    throw LLMError.invalidResponse
                }
                return RuntimeLLMProvider(
                    provider: OpenAICompatibleProvider(
                        baseURL: baseURL,
                        apiKey: try apiKey(for: provider),
                        model: model,
                        includeTemperature: provider.includesSamplingTemperature
                    ),
                    supportsVision: provider.supportsVision
                )
            }
        }

        private func apiKey(for provider: AIProvider) throws -> String {
            guard !provider.requiresAPIKey else {
                guard let key = KeychainManager.load(key: provider.keychainKey)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !key.isEmpty
                else {
                    throw LLMError.noAPIKey
                }
                return key
            }

            return ""
        }
    }
}

private struct RuntimeLLMProvider {
    let provider: any LLMProvider
    let supportsVision: Bool
}

private extension View {
    @ViewBuilder
    func scowldComposerGlass() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                )
        }
    }
}

// MARK: - Notification for Settings Changes

extension Notification.Name {
    static let amicaSettingsChanged = Notification.Name("amicaSettingsChanged")
    static let ttsDone = Notification.Name("ttsDone")
    static let ttsPlaybackStarted = Notification.Name("ttsPlaybackStarted")
    static let ttsFailed = Notification.Name("ttsFailed")
    static let aiResponseReady = Notification.Name("aiResponseReady")
    static let appReady = Notification.Name("appReady")
}
