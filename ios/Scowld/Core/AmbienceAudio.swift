import AVFoundation
import Observation
import os

private let ambienceLogger = Logger(subsystem: "com.apoorvdarshan.Scowld", category: "Ambience")

// MARK: - Built-in ambience

/// The ambient recordings shipped in `Resources/Ambient`.
///
/// These are real recordings rather than anything generated, and all of them are
/// CC0 (public domain), so they can be shipped and used freely.
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

/// Plays the built-in ambience and the user's own music as two fully independent
/// channels.
///
/// Two separate players rather than one, because the point is that they can run
/// together — rain behind a song — and be mixed and stopped independently. Neither
/// touches the audio session: the app already routes WebAudio through `.playback`,
/// and reconfiguring it here would interrupt speech.
@Observable
@MainActor
final class AmbienceAudio: NSObject, AVAudioPlayerDelegate {

    /// One player for the whole app, so Settings and the scene share the channels.
    static let shared = AmbienceAudio()

    enum DefaultsKey {
        static let track = "ambient_track"
        static let noiseVolume = "ambient_volume"
        static let musicVolume = "music_volume"
    }

    /// Currently selected ambience, or nil when ambience is off.
    private(set) var track: AmbientTrack?
    var noiseVolume: Double {
        didSet {
            noisePlayer?.volume = Float(noiseVolume)
            UserDefaults.standard.set(noiseVolume, forKey: DefaultsKey.noiseVolume)
        }
    }

    var musicVolume: Double {
        didSet {
            musicPlayer?.volume = Float(musicVolume)
            UserDefaults.standard.set(musicVolume, forKey: DefaultsKey.musicVolume)
        }
    }

    private(set) var musicTracks: [AmicaMediaFile] = []
    private(set) var currentTrack: AmicaMediaFile?
    private(set) var isMusicPlaying = false
    /// Plays the library on a loop instead of stopping after the last track.
    var playsAllInLoop = true

    private var noisePlayer: AVAudioPlayer?
    private var musicPlayer: AVAudioPlayer?

    override init() {
        let defaults = UserDefaults.standard
        let storedVolume = defaults.object(forKey: DefaultsKey.noiseVolume) as? Double
        let storedMusic = defaults.object(forKey: DefaultsKey.musicVolume) as? Double
        self.noiseVolume = storedVolume ?? 0.5
        self.musicVolume = storedMusic ?? 0.6
        super.init()
        refreshMusicLibrary()
    }

    // MARK: - Ambience

    /// Turns ambience on (or off when passed nil) and loops it forever.
    func play(_ newTrack: AmbientTrack?) {
        noisePlayer?.stop()
        noisePlayer = nil
        track = newTrack
        UserDefaults.standard.set(newTrack?.rawValue ?? "", forKey: DefaultsKey.track)

        guard let newTrack else { return }
        guard let url = Bundle.main.url(forResource: newTrack.resourceName, withExtension: "mp3") else {
            ambienceLogger.error("[Ambience] \(newTrack.resourceName, privacy: .public).mp3 missing from the bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = Float(noiseVolume)
            player.prepareToPlay()
            player.play()
            noisePlayer = player
        } catch {
            ambienceLogger.error("[Ambience] could not play \(newTrack.resourceName, privacy: .public): \(error.localizedDescription)")
        }
    }

    var isAmbiencePlaying: Bool { noisePlayer?.isPlaying ?? false }

    func stopAmbience() {
        play(nil)
    }

    // MARK: - Music

    func refreshMusicLibrary() {
        musicTracks = AmicaUserMedia.importedMusic()
        if let current = currentTrack, !musicTracks.contains(where: { $0.id == current.id }) {
            // The playing file was deleted.
            stopMusic()
            currentTrack = nil
        }
    }

    func playMusic(_ file: AmicaMediaFile) {
        guard let url = AmicaUserMedia.fileURL(forPublicPath: file.publicPath) else { return }
        musicPlayer?.stop()
        musicPlayer = nil

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.volume = Float(musicVolume)
            player.prepareToPlay()
            player.play()
            musicPlayer = player
            currentTrack = file
            isMusicPlaying = true
        } catch {
            ambienceLogger.error("[Ambience] could not play \(file.fileName, privacy: .public): \(error.localizedDescription)")
            isMusicPlaying = false
        }
    }

    func toggleMusicPlayback() {
        if let player = musicPlayer {
            if player.isPlaying {
                player.pause()
                isMusicPlaying = false
            } else {
                player.play()
                isMusicPlaying = true
            }
            return
        }
        // Nothing loaded yet — start whatever is first in the library.
        refreshMusicLibrary()
        if let first = musicTracks.first { playMusic(first) }
    }

    func stopMusic() {
        musicPlayer?.stop()
        musicPlayer = nil
        isMusicPlaying = false
    }

    func nextTrack() {
        advance(by: 1)
    }

    func previousTrack() {
        advance(by: -1)
    }

    private func advance(by offset: Int) {
        refreshMusicLibrary()
        guard !musicTracks.isEmpty else { return }
        let currentIndex = currentTrack.flatMap { current in
            musicTracks.firstIndex { $0.id == current.id }
        } ?? -1
        var next = currentIndex + offset
        if next < 0 { next = musicTracks.count - 1 }
        if next >= musicTracks.count { next = 0 }
        playMusic(musicTracks[next])
    }

    /// Both channels off. Used when the conversation screen goes away.
    func stopAll() {
        stopAmbience()
        stopMusic()
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.playsAllInLoop, self.musicTracks.count > 1 else {
                self?.isMusicPlaying = false
                return
            }
            self.advance(by: 1)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        ambienceLogger.error("[Ambience] decode error: \(error?.localizedDescription ?? "unknown", privacy: .public)")
    }
}
