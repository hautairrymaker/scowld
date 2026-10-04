import Foundation
import Observation
import os

private let proactiveLogger = Logger(subsystem: "com.apoorvdarshan.Scowld", category: "Proactive")

// MARK: - Settings

/// Options for the character speaking first.
///
/// The gap between utterances is deliberately a **range**, not a fixed delay.
/// A character that pipes up exactly every five minutes stops feeling like
/// someone in the room and starts feeling like an alarm clock.
enum ProactiveChatSettings {

    static let enabledKey = "proactive_chat_enabled"
    static let minIntervalKey = "proactive_chat_min_interval"
    static let maxIntervalKey = "proactive_chat_max_interval"
    static let idleThresholdKey = "proactive_chat_idle_threshold"
    static let dailyCapKey = "proactive_chat_daily_cap"
    static let quietStartKey = "proactive_chat_quiet_start"
    static let quietEndKey = "proactive_chat_quiet_end"

    /// Instructions handed to the model when nothing has been said for a while.
    ///
    /// Written as a stage direction, because the page delivers it as the most
    /// recent turn, and models read a parenthetical that way.
    static let defaultPrompt = """
    (The user has been quiet for a while and has not said anything. \
    Say one short, natural sentence to start a conversation, as yourself and in \
    character. Bring up something you remember about them if it fits. Do not \
    mention the silence, do not explain yourself, and do not say more than one \
    sentence.)
    """

    /// Registered rather than forced, so anything already stored wins.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            enabledKey: true,
            // Quiet for a minute, then the clock starts.
            idleThresholdKey: 60,
            // Then somewhere between three and ten minutes between utterances.
            minIntervalKey: 180,
            maxIntervalKey: 600,
            // Plenty for a long sitting, few enough to stay welcome.
            dailyCapKey: 12,
            quietStartKey: 23,
            quietEndKey: 8,
        ])
    }

    struct Snapshot {
        let enabled: Bool
        let minInterval: TimeInterval
        let maxInterval: TimeInterval
        let idleThreshold: TimeInterval
        let dailyCap: Int
        let quietStart: Int
        let quietEnd: Int
    }

    static func snapshot(defaults: UserDefaults = .standard) -> Snapshot {
        registerDefaults()

        let idle = TimeInterval(max(10, defaults.integer(forKey: idleThresholdKey)))
        let minInterval = TimeInterval(max(Int(idle) + 30, defaults.integer(forKey: minIntervalKey)))
        let maxInterval = TimeInterval(max(Int(minInterval) + 30, defaults.integer(forKey: maxIntervalKey)))

        return Snapshot(
            enabled: defaults.bool(forKey: enabledKey),
            minInterval: minInterval,
            maxInterval: maxInterval,
            idleThreshold: idle,
            dailyCap: max(1, defaults.integer(forKey: dailyCapKey)),
            quietStart: defaults.integer(forKey: quietStartKey),
            quietEnd: defaults.integer(forKey: quietEndKey)
        )
    }
}

// MARK: - Messenger

/// Decides when the character is allowed to break the silence, and hands the
/// words to be used.
///
/// The page already has a semi-autonomous mode of its own, but it speaks from a
/// fixed phrase list: the model is never consulted. This drives the same
/// machinery from the other end — the page is given a hidden turn to answer, so
/// the reply is generated with the real model, using the memory and the
/// conversation that are already in place, and then spoken through the existing
/// voice and caption pipeline.
///
/// Everything about *when* lives here, and the rules are deliberately
/// conservative: one short line, a random gap, a daily ceiling, silence at
/// night, and never while a conversation is in progress.
@Observable
@MainActor
final class ProactiveMessenger {

    static let shared = ProactiveMessenger()

    /// Whether a conversation is currently in progress. These are pushed in by
    /// the view rather than read back out of it: the view is a value type, so a
    /// closure holding a copy of it would keep answering with the state it had
    /// when the closure was made.
    var isForeground = false
    var isChatVisible = false
    var isSpeaking = false
    var isAwaitingReply = false
    var isRecording = false
    var isTyping = false

    /// Sends the hidden turn. Set by the view so this stays free of WebKit.
    var deliver: ((String) -> Void)?

    private(set) var lastSpokenAt = Date.distantPast
    private var lastInteractionAt = Date()
    private var nextGap: TimeInterval = 0
    private var spokenToday = 0
    private var dayStamp = Date()
    private var timer: Timer?
    private var isRunning = false

    private static let tickInterval: TimeInterval = 20

    /// Everything that has to be true before it is welcome to speak.
    private var isQuietEnoughToSpeak: Bool {
        isForeground && isChatVisible && !isSpeaking && !isAwaitingReply
            && !isRecording && !isTyping
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        scheduleNextGap()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        proactiveLogger.info("[Proactive] watching")
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    /// Called for anything the user does — a message, a spoken turn, a tap that
    /// clearly means "I am here". Pushes the window back and draws a fresh gap.
    func noteInteraction() {
        lastInteractionAt = Date()
        scheduleNextGap()
    }

    // MARK: - Timing

    private func scheduleNextGap() {
        let settings = ProactiveChatSettings.snapshot()
        let low = settings.minInterval
        let high = max(low + 1, settings.maxInterval)
        nextGap = TimeInterval.random(in: low...high)
        proactiveLogger.info("[Proactive] next line in \(Int(self.nextGap))s")
    }

    private func tick() {
        let now = Date()
        rolloverIfNeeded(now)

        let settings = ProactiveChatSettings.snapshot()
        guard settings.enabled else { return }
        guard spokenToday < settings.dailyCap else { return }
        guard !isQuietHour(now, settings: settings) else { return }
        guard now.timeIntervalSince(lastInteractionAt) >= settings.idleThreshold else { return }
        guard now.timeIntervalSince(lastSpokenAt) >= nextGap else { return }
        guard isQuietEnoughToSpeak else { return }

        speak()
    }

    private func speak() {
        lastSpokenAt = Date()
        spokenToday += 1
        // Draw the next gap now, so the rhythm keeps moving even if nothing else
        // happens in between.
        scheduleNextGap()
        proactiveLogger.info("[Proactive] speaking (line \(self.spokenToday) today)")
        deliver?(ProactiveChatSettings.defaultPrompt)
    }

    // MARK: - Bookkeeping

    private func rolloverIfNeeded(_ now: Date) {
        guard !Calendar.current.isDate(now, inSameDayAs: dayStamp) else { return }
        dayStamp = now
        spokenToday = 0
    }

    private func isQuietHour(_ now: Date, settings: ProactiveChatSettings.Snapshot) -> Bool {
        let hour = Calendar.current.component(.hour, from: now)
        let start = settings.quietStart
        let end = settings.quietEnd

        if start == end { return false }
        if start < end {
            return hour >= start && hour < end
        }
        // Window wraps past midnight, e.g. 23 → 8.
        return hour >= start || hour < end
    }
}
