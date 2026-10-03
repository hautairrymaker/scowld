@preconcurrency import AVFoundation
import Speech
import os

private let handsFreeLogger = Logger(subsystem: "com.apoorvdarshan.Scowld", category: "HandsFree")

/// Listens for the wake phrase so a conversation can start hands-free.
///
/// Two details matter more than anything else here:
///
/// * **The recogniser language has to match the language the phrase is spoken in.**
///   Following the app language alone broke English names: a Chinese recogniser
///   hears "hey Bella" as 嘿贝拉, so a phrase built from "Bella" could never match.
///   The phrase list and the recogniser are therefore chosen together, and both
///   scripts of the name are always accepted.
/// * **Matching ignores spacing.** Chinese transcription has no spaces between
///   words, so a phrase test built around `" name "` can never fire. Text is
///   stripped to letters and digits on both sides before comparing.
@Observable
@MainActor
final class HandsFreeWakeListener: NSObject {
    var isRunning = false
    var heardText = ""

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var restartTimer: Timer?
    private var retryTimer: Timer?
    private var wakeName = ""
    private var normalizedWakeName = ""
    private var wakePhrases: [String] = []
    private var contextualStrings: [String] = []
    private var recognizerLocale = Locale(identifier: "en-US")
    private var onWake: (() -> Void)?
    private var isStoppingForWake = false
    private var hasInstalledInputTap = false
    private var lastWakeAt = Date.distantPast
    /// Set when on-device recognition fails, so the next attempt may use the
    /// network. On-device is preferred, but it is much less accurate and simply
    /// unavailable until the language model has been downloaded.
    private var allowServerRecognition = false

    private static let recognitionRestartInterval: TimeInterval = 55
    private static let wakeDebounceInterval: TimeInterval = 2.5
    private static let unavailableRetryInterval: TimeInterval = 2.0

    private var speechRecognizer: SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: recognizerLocale)
    }

    func start(wakeName: String, onWake: @escaping () -> Void) {
        let trimmedName = wakeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            stop()
            return
        }

        let normalizedName = Self.compact(trimmedName)
        self.onWake = onWake

        if isRunning, normalizedName == normalizedWakeName {
            return
        }

        stop()
        self.wakeName = trimmedName
        self.normalizedWakeName = normalizedName
        self.recognizerLocale = Self.recognizerLocale(for: trimmedName)
        self.wakePhrases = Self.spokenPhrases(for: trimmedName, locale: recognizerLocale)
        self.contextualStrings = Self.contextualHints(for: trimmedName)
        self.allowServerRecognition = false
        startRecognition()
    }

    func stop() {
        restartTimer?.invalidate()
        restartTimer = nil
        retryTimer?.invalidate()
        retryTimer = nil

        stopAudioEngine()

        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isRunning = false
        heardText = ""
        isStoppingForWake = false
    }

    private func stopAudioEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }

        if hasInstalledInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledInputTap = false
        }

        audioEngine.reset()
    }

    private func startRecognition() {
        guard !wakePhrases.isEmpty else { return }

        guard let speechRecognizer else {
            handsFreeLogger.info("[HandsFree] No recogniser for \(self.recognizerLocale.identifier, privacy: .public)")
            scheduleRetry()
            return
        }

        // `isAvailable` is false for a moment after launch and whenever the
        // recogniser is being reconfigured. The old code returned here and never
        // came back, which looked exactly like "voice activation does nothing".
        guard speechRecognizer.isAvailable else {
            handsFreeLogger.info("[HandsFree] Recogniser not available yet, will retry")
            scheduleRetry()
            return
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = !allowServerRecognition && supportsOnDeviceRecognition
            // Biasing the recogniser towards the phrases we actually look for is
            // the single biggest accuracy win available; it is what stops a wake
            // word being transcribed as a near-miss.
            if !contextualStrings.isEmpty {
                request.contextualStrings = contextualStrings
            }
            recognitionRequest = request

            recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }

                    if let result {
                        let transcript = result.bestTranscription.formattedString
                        self.heardText = transcript
                        self.handleTranscript(transcript)
                    }

                    if let error {
                        self.handleRecognitionError(error)
                    }

                    if error != nil || result?.isFinal == true {
                        self.restartIfNeeded()
                    }
                }
            }

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                handsFreeLogger.error("[HandsFree] Invalid input format")
                stop()
                return
            }

            stopAudioEngine()
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }
            hasInstalledInputTap = true

            audioEngine.prepare()
            try audioEngine.start()
            isRunning = true
            retryTimer?.invalidate()
            retryTimer = nil
            handsFreeLogger.info("[HandsFree] Listening on \(self.recognizerLocale.identifier, privacy: .public) for \(self.wakePhrases.joined(separator: " / "), privacy: .public)")

            restartTimer?.invalidate()
            restartTimer = Timer.scheduledTimer(withTimeInterval: Self.recognitionRestartInterval, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.restartIfNeeded()
                }
            }
        } catch {
            handsFreeLogger.error("[HandsFree] Failed to start wake listener: \(error.localizedDescription)")
            stop()
            scheduleRetry()
        }
    }

    /// On-device recognition reports an error immediately when the language model
    /// is missing. Rather than failing forever, allow the network on the next pass.
    private func handleRecognitionError(_ error: Error) {
        guard !allowServerRecognition else { return }
        let code = (error as NSError).code
        let unavailableOnDevice = code == 203 || code == 1101 || code == 1110 || code == 216 || code == 102
        if unavailableOnDevice || !supportsOnDeviceRecognition {
            allowServerRecognition = true
            handsFreeLogger.info("[HandsFree] Falling back to server recognition")
        }
    }

    /// Whether this device has an on-device model for the chosen language at all.
    private var supportsOnDeviceRecognition: Bool {
        speechRecognizer?.supportsOnDeviceRecognition ?? false
    }

    /// Retries shortly instead of giving up. Keeps a short delay so a permanently
    /// unavailable recogniser does not spin.
    private func scheduleRetry() {
        retryTimer?.invalidate()
        guard !wakePhrases.isEmpty else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: Self.unavailableRetryInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isRunning, !self.wakePhrases.isEmpty else { return }
                self.startRecognition()
            }
        }
    }

    private func restartIfNeeded() {
        guard isRunning, !isStoppingForWake else { return }
        stop()
        guard !wakePhrases.isEmpty else { return }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !self.wakePhrases.isEmpty else { return }
            self.startRecognition()
        }
    }

    private func handleTranscript(_ transcript: String) {
        guard Date().timeIntervalSince(lastWakeAt) > Self.wakeDebounceInterval else { return }
        guard matchesWakePhrase(transcript) else { return }

        lastWakeAt = Date()
        isStoppingForWake = true
        handsFreeLogger.info("[HandsFree] Wake phrase detected")
        let wakeAction = onWake
        stop()
        wakeAction?()
    }

    private func matchesWakePhrase(_ text: String) -> Bool {
        let spoken = Self.compact(text)
        guard !spoken.isEmpty else { return false }

        return wakePhrases.contains { phrase in
            let target = Self.compact(phrase)
            guard target.count >= 2 else { return false }
            return spoken.contains(target)
        }
    }

    // MARK: - Language and phrases

    /// True when the name itself is written in Chinese.
    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3400...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value)
        }
    }

    /// The recogniser must speak the language the wake phrase is spoken in.
    ///
    /// A Chinese recogniser cannot produce "Bella" — it writes 贝拉 — so an English
    /// name needs an English recogniser even when the rest of the app is Chinese.
    /// When the app is Chinese the Chinese forms of the name are used instead, and
    /// then a Chinese recogniser is the right one.
    private static func recognizerLocale(for name: String) -> Locale {
        if containsCJK(name) { return HostedServiceConfig.speechRecognizerLocale() }
        if HostedServiceConfig.speechRecognizerLocaleIdentifier().hasPrefix("zh"),
           !chineseAliases(for: name).isEmpty {
            return HostedServiceConfig.speechRecognizerLocale()
        }
        return Locale(identifier: "en-US")
    }

    /// How a Latin name is likely to come back from a Chinese recogniser.
    private static func chineseAliases(for name: String) -> [String] {
        let base = compact(name)
        let table: [String: [String]] = [
            "bella": ["贝拉", "贝啦", "倍拉", "贝拉你"],
            "bela": ["贝拉", "贝啦"],
            "aria": ["阿丽亚", "阿莉亚", "阿里亚"],
            "clara": ["克拉拉", "克莱拉"],
            "celine": ["赛琳", "塞琳", "瑟琳"],
            "ciel": ["希尔", "西尔"],
            "ariai": ["阿丽亚"],
        ]
        if let alias = table[base] { return alias }
        // Unknown Latin name: only the name itself is offered.
        return []
    }

    /// Every phrase that should start a conversation, in the language in use.
    private static func spokenPhrases(for name: String, locale: Locale) -> [String] {
        let base = compact(name)
        var phrases = Set<String>()

        let chinese = locale.identifier.hasPrefix("zh")
        if chinese {
            let names = (containsCJK(name) ? [name] : chineseAliases(for: name)) + [name, base]
            for variant in names {
                for form in ["嘿", "嗨", "你好", "喂", ""] {
                    phrases.insert(form + variant)
                }
            }
            // A Chinese recogniser still emits Latin words now and then.
            phrases.insert("hey " + base)
        } else {
            for form in ["hey ", "hi ", "hello ", ""] {
                phrases.insert(form + base)
            }
            if base == "bella" { phrases.formUnion(["hey bela", "hey bella"]) }
            if base == "aria" { phrases.formUnion(["hey area", "hey arya"]) }
            if base == "ciel" { phrases.formUnion(["hey seal", "hey seel"]) }
        }

        return phrases.filter { compact($0).count >= 2 }
    }

    /// Phrases handed to the recogniser as hints, in both scripts.
    private static func contextualHints(for name: String) -> [String] {
        let base = compact(name)
        var hints = Set<String>()
        for variant in [name, base] + chineseAliases(for: name) {
            for form in ["hey ", "hi ", "嘿", "嗨", "你好", ""] {
                hints.insert(form + variant)
            }
        }
        return Array(hints).filter { compact($0).count >= 2 }
    }

    /// Keeps only letters and digits, lowercased.
    ///
    /// This is what makes Chinese phrases matchable: `SFSpeechRecognizer` returns
    /// 嘿贝拉你在吗 with no spaces, so any comparison that expects a spaced-out
    /// name silently never fires.
    private static func compact(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var out = ""
        for scalar in folded.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            out.unicodeScalars.append(scalar)
        }
        return out.lowercased()
    }
}
