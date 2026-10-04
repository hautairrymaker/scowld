import Foundation

/// Options for the character speaking first.
///
/// The page already ships a semi-autonomous mode — "Amica Life" upstream — that
/// notices when nothing has happened for a while and then starts talking on its
/// own. The app has always switched it off; these are the numbers it is given
/// when it is switched on.
///
/// The gap between utterances is deliberately a **range**, not a fixed delay.
/// A character that pipes up exactly every five minutes stops feeling like
/// someone in the room and starts feeling like an alarm.
enum ProactiveChatSettings {

    static let enabledKey = "proactive_chat_enabled"
    static let minIntervalKey = "proactive_chat_min_interval"
    static let maxIntervalKey = "proactive_chat_max_interval"
    static let idleThresholdKey = "proactive_chat_idle_threshold"
    static let sleepAfterKey = "proactive_chat_sleep_after"

    /// Defaults are registered rather than forced, so anything already stored wins.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            enabledKey: true,
            // Quiet for a minute, then it is "on its own".
            idleThresholdKey: 60,
            // Then somewhere between three and ten minutes between utterances.
            minIntervalKey: 180,
            maxIntervalKey: 600,
            // Half an hour without a word and it settles down.
            sleepAfterKey: 1800,
        ])
    }

    /// Everything the page needs, already clamped to sane values.
    struct Snapshot {
        let enabled: Bool
        let minInterval: Int
        let maxInterval: Int
        let idleThreshold: Int
        let sleepAfter: Int

        /// The page reads all of these as strings.
        var enabledJS: String { enabled ? "true" : "false" }
    }

    static func snapshot(defaults: UserDefaults = .standard) -> Snapshot {
        registerDefaults()

        let enabled = defaults.bool(forKey: enabledKey)

        let idle = max(10, defaults.integer(forKey: idleThresholdKey))
        let minInterval = max(idle + 30, defaults.integer(forKey: minIntervalKey))
        let maxInterval = max(minInterval + 30, defaults.integer(forKey: maxIntervalKey))
        let sleepAfter = max(maxInterval + 60, defaults.integer(forKey: sleepAfterKey))

        return Snapshot(
            enabled: enabled,
            minInterval: minInterval,
            maxInterval: maxInterval,
            idleThreshold: idle,
            sleepAfter: sleepAfter
        )
    }
}
