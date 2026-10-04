import AVFoundation
import Observation
import os

private let ambienceLogger = Logger(subsystem: "com.apoorvdarshan.Scowld", category: "Ambience")

// MARK: - Built-in ambience

/// The ambient recordings shipped in `Resources/Ambient`.
///
/// These are real recordings rather than anything synthesised, and all of them are
/// CC0 (public domain), so they can be shipped and played freely.
enum AmbientTrack: String, CaseIterable, Identifiable {
    case rain
    case seaWaves
    case wind
    case stream
    case fireplace
    case snowSteps
    case birds

    var id: String { rawValue }

    /// Base name of the bundled file, e.g. `sea-waves` for `sea-waves.mp3`.
    var resourceName: String {
        switch self {
        case .rain: "rain"
        case .seaWaves: "sea-waves"
        case .wind: "wind"
        case .stream: "stream"
        case .fireplace: "fireplace"
        case .snowSteps: "snow-steps"
        case .birds: "birds"
        }
    }

    var title: String {
        switch self {
        case .rain: "Rain"
        case .seaWaves: "Sea waves"
        case .wind: "Wind"
        case .stream: "Stream"
        case .fireplace: "Fireplace"
        case .snowSteps: "Snow"
        case .birds: "Birdsong"
        }
    }

    var systemImage: String {
        switch self {
        case .rain: "cloud.rain.fill"
        case .seaWaves: "water.waves"
        case .wind: "wind"
        case .stream: "drop.fill"
        case .fireplace: "flame.fill"
        case .snowSteps: "snowflake"
        case .birds: "bird.fill"
        }
    }
}

// MARK: - Player

/// Plays one ambient loop at a time.
///
/// Deliberately small and self-contained: it owns a single player, never touches
/// the audio session (the app already routes its speech through `.playback`, and
/// reconfiguring the session here would interrupt it), and treats "no track" as
/// the off state so the choice survives a restart through UserDefaults.
@Observable
@MainActor
final class AmbienceAudio {

    /// One player for the whole app, so the scene and any other surface share it.
    static let shared = AmbienceAudio()

    private enum DefaultsKey {
        static let track = "ambient_track"
        static let volume = "ambient_volume"
    }

    /// Currently playing ambience, or nil when it is off.
    private(set) var track: AmbientTrack?

    /// 0…1. Written through to the running player so a change is heard at once.
    var volume: Double {
        didSet {
            player?.volume = Float(volume)
            UserDefaults.standard.set(volume, forKey: DefaultsKey.volume)
        }
    }

    private var player: AVAudioPlayer?

    init() {
        let saved = UserDefaults.standard.double(forKey: DefaultsKey.volume)
        volume = saved > 0 ? min(1, saved) : 0.5
    }

    // MARK: - Playback

    /// Plays `track`, or stops when handed nil.
    func play(_ track: AmbientTrack?) {
        guard let track else {
            stop()
            return
        }
        guard let url = Self.fileURL(for: track) else {
            ambienceLogger.error("[Ambience] missing file for \(track.rawValue, privacy: .public)")
            stop()
            return
        }

        do {
            let next = try AVAudioPlayer(contentsOf: url)
            next.numberOfLoops = -1
            next.volume = Float(volume)
            next.prepareToPlay()
            next.play()

            player?.stop()
            player = next
            self.track = track
            UserDefaults.standard.set(track.rawValue, forKey: DefaultsKey.track)
            ambienceLogger.info("[Ambience] playing \(track.rawValue, privacy: .public)")
        } catch {
            ambienceLogger.error("[Ambience] could not play \(track.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            stop()
        }
    }

    /// Starts the track again when it is already the current one, otherwise stops.
    func toggle(_ track: AmbientTrack) {
        if self.track == track {
            stop()
        } else {
            play(track)
        }
    }

    func stop() {
        player?.stop()
        player = nil
        track = nil
        UserDefaults.standard.removeObject(forKey: DefaultsKey.track)
    }

    // MARK: - Lookup

    /// The bundle puts loose resources at the root, but an older layout used an
    /// `Ambient` subfolder — both are tried so neither arrangement breaks it.
    static func fileURL(for track: AmbientTrack) -> URL? {
        Bundle.main.url(forResource: track.resourceName, withExtension: "mp3")
            ?? Bundle.main.url(forResource: track.resourceName, withExtension: "mp3", subdirectory: "Ambient")
    }
}
