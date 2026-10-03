import Foundation
import AudioToolbox
import Observation
import UserNotifications
import os

private let focusLogger = Logger(subsystem: "com.apoorvdarshan.Scowld", category: "FocusTimer")

// MARK: - Settings

/// UserDefaults-backed options for the focus timer, editable from Settings.
enum FocusTimerSettings {
    static let enabledKey = "focus_timer_enabled"
    static let modeKey = "focus_timer_mode"
    static let focusMinutesKey = "focus_timer_focus_minutes"
    static let restMinutesKey = "focus_timer_rest_minutes"
    static let autoRestKey = "focus_timer_auto_rest"
    static let chimeKey = "focus_timer_chime"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            enabledKey: true,
            modeKey: FocusTimerMode.countdown.rawValue,
            focusMinutesKey: 25,
            restMinutesKey: 5,
            autoRestKey: true,
            chimeKey: true,
        ])
    }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    static func mode(defaults: UserDefaults = .standard) -> FocusTimerMode {
        FocusTimerMode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .countdown
    }

    static func focusMinutes(defaults: UserDefaults = .standard) -> Int {
        let value = defaults.integer(forKey: focusMinutesKey)
        return value > 0 ? min(180, value) : 25
    }

    static func restMinutes(defaults: UserDefaults = .standard) -> Int {
        let value = defaults.integer(forKey: restMinutesKey)
        return value > 0 ? min(60, value) : 5
    }

    static func autoRest(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: autoRestKey)
    }

    static func playsChime(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: chimeKey)
    }

    /// Preset lengths offered in Settings. A short list beats a stepper here:
    /// nobody needs a 37-minute session, and picking from options is one tap.
    static let focusLengthOptions = [10, 15, 20, 25, 30, 45, 60, 90]
    static let restLengthOptions = [3, 5, 10, 15, 20, 30]
}

// MARK: - Modes

/// Whether a session counts down to zero or counts upwards.
///
/// Declared outside `FocusTimer` so Settings can reach it without touching a
/// main-actor-isolated type.
enum FocusTimerMode: String, CaseIterable, Identifiable {
    case countdown
    case countUp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .countdown: "Countdown"
        case .countUp: "Count up"
        }
    }

    var explanation: String {
        switch self {
        case .countdown: "Counts down from the focus length, then alerts you."
        case .countUp: "Counts upwards with no end, for open-ended sessions."
        }
    }
}

/// Which half of a session is running.
enum FocusTimerPhase {
    case focus
    case rest

    var title: String {
        switch self {
        case .focus: "Focus"
        case .rest: "Break"
        }
    }
}

// MARK: - Timer

/// A focus session that runs while the device is held in landscape.
///
/// Landscape is what starts it and portrait does not stop it, so turning the
/// device around mid-session keeps the clock running — the card is simply hidden.
/// There are deliberately no controls on the home screen; everything lives in
/// Settings.
@Observable
@MainActor
final class FocusTimer {

    typealias Mode = FocusTimerMode
    typealias Phase = FocusTimerPhase

    /// One timer for the whole app: the card in the scene and the controls in
    /// Settings have to be looking at the same session.
    static let shared = FocusTimer()

    private(set) var isRunning = false
    private(set) var phase: Phase = .focus
    private(set) var elapsed: TimeInterval = 0
    private(set) var total: TimeInterval = 0
    /// True once a countdown has reached zero, until the next session starts.
    private(set) var hasFinished = false

    private var ticker: Timer?
    private var lastTick: Date?
    private var pendingNotificationID: String?

    /// Seconds left in a countdown, or nil when counting upwards.
    var remaining: TimeInterval? {
        guard mode == .countdown, total > 0 else { return nil }
        return max(0, total - elapsed)
    }

    var mode: Mode { FocusTimerSettings.mode() }

    var progress: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, elapsed / total))
    }

    /// The big number on the card.
    var displayText: String {
        let seconds = Int(mode == .countdown ? (remaining ?? elapsed) : elapsed)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var subtitle: String {
        switch phase {
        case .focus: mode == .countUp ? "Elapsed" : "Focus"
        case .rest: "Break"
        }
    }

    /// Duration of the phase currently running, used for the ring.
    private func duration(for phase: Phase) -> TimeInterval {
        switch phase {
        case .focus: TimeInterval(FocusTimerSettings.focusMinutes() * 60)
        case .rest: TimeInterval(FocusTimerSettings.restMinutes() * 60)
        }
    }

    // MARK: - Lifecycle

    /// Starts a focus session unless one is already in flight.
    func startIfIdle() {
        guard FocusTimerSettings.isEnabled(), !isRunning else { return }
        start(phase: .focus)
    }

    func start(phase newPhase: Phase) {
        stopTicking()
        phase = newPhase
        total = mode == .countUp ? 0 : duration(for: newPhase)
        elapsed = 0
        hasFinished = false
        isRunning = true
        lastTick = Date()
        requestNotificationPermissionIfNeeded()
        startTicking()
        refreshScheduledNotification()
        focusLogger.info("[Focus] started \(newPhase.title, privacy: .public) for \(Int(self.total))s")
    }

    func stop() {
        stopTicking()
        isRunning = false
        hasFinished = false
        elapsed = 0
        total = 0
        phase = .focus
        cancelPendingNotification()
    }

    func finishNow() {
        stop()
    }

    // MARK: - Ticking

    private func startTicking() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
        lastTick = nil
    }

    private func tick() {
        guard isRunning else { return }
        let now = Date()
        let delta = now.timeIntervalSince(lastTick ?? now)
        lastTick = now
        elapsed += max(0, delta)

        if mode == .countdown, total > 0, elapsed >= total {
            completePhase()
        }
    }

    private func completePhase() {
        stopTicking()
        isRunning = false
        hasFinished = true
        elapsed = total

        if FocusTimerSettings.playsChime() {
            AudioServicesPlaySystemSound(1005)
        }
        cancelPendingNotification()

        let finishedPhase = phase
        if finishedPhase == .focus, FocusTimerSettings.autoRest() {
            // A short pause so the chime is heard before the break begins.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, self.hasFinished, self.phase == .focus else { return }
                self.start(phase: .rest)
            }
        }
        focusLogger.info("[Focus] \(finishedPhase.title, privacy: .public) complete")
    }

    // MARK: - Notifications

    /// Asks once. A plain local notification needs no special entitlement, which
    /// matters because the app is installed by re-signing an unsigned build.
    private func requestNotificationPermissionIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    focusLogger.error("[Focus] notification permission failed: \(error.localizedDescription)")
                } else {
                    focusLogger.info("[Focus] notification permission granted: \(granted)")
                }
            }
        }
    }

    /// Schedules the alert for the exact moment the countdown ends, so it still
    /// arrives when the app is in the background.
    private func scheduleCompletionNotification(after seconds: TimeInterval) {
        guard seconds > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = phase == .focus ? "Focus session complete" : "Break over"
        content.body = phase == .focus
            ? "Nice work. Time for a break."
            : "Ready to focus again?"
        content.sound = .default

        let identifier = "focus-timer-\(phase == .focus ? "focus" : "rest")"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        pendingNotificationID = identifier
        let center = UNUserNotificationCenter.current()
        center.add(request) { error in
            if let error {
                focusLogger.error("[Focus] scheduling notification failed: \(error.localizedDescription)")
            }
        }
    }

    private func cancelPendingNotification() {
        guard let identifier = pendingNotificationID else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        pendingNotificationID = nil
    }

    /// Called whenever the timer (re)starts so the background alert tracks the
    /// real remaining time. Safe to call repeatedly.
    func refreshScheduledNotification() {
        cancelPendingNotification()
        guard mode == .countdown, isRunning, let remaining else { return }
        scheduleCompletionNotification(after: remaining)
    }
}
