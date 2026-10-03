import Foundation
import UIKit

// MARK: - User media

/// Stores assets the user adds (background photos, imported VRM avatars) inside
/// the app's Documents directory.
///
/// `amica.bundle` is read-only and lives inside the app bundle, so anything the
/// user supplies has to live outside it and be handed to the 3D viewer through
/// the local HTTP server. Files are addressed as `/media/<kind>/<file>`, which
/// `AmicaLocalServer` resolves back to a real path with
/// `AmicaUserMedia.fileURL(forPublicPath:)`.
enum AmicaUserMedia {

    enum Kind: String {
        case backgrounds
        case avatars
        case music
    }

    /// Everything the user adds lives under here.
    static var rootURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("ScowldMedia", isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    static func directoryURL(for kind: Kind) -> URL {
        let directory = rootURL.appendingPathComponent(kind.rawValue, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    /// Path the viewer requests, e.g. `/media/avatars/my-avatar.vrm`.
    static func publicPath(for kind: Kind, fileName: String) -> String {
        "/media/\(kind.rawValue)/\(fileName)"
    }

    /// Resolve a `/media/...` request back to a file, refusing anything that
    /// escapes the media root.
    static func fileURL(forPublicPath path: String) -> URL? {
        var trimmed = path
        if trimmed.hasPrefix("/") { trimmed.removeFirst() }
        guard trimmed.hasPrefix("media/") else { return nil }

        let relative = String(trimmed.dropFirst("media/".count))
        guard !relative.isEmpty, !relative.contains("..") else { return nil }

        let candidate = rootURL.appendingPathComponent(relative)
        // Defence in depth: the resolved path must stay inside the media root.
        guard candidate.standardizedFileURL.path.hasPrefix(rootURL.standardizedFileURL.path) else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    // MARK: - Backgrounds

    /// Saves a picked photo and returns its public path.
    static func saveBackgroundImage(_ image: UIImage) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        let name = "bg-\(UUID().uuidString).jpg"
        let url = directoryURL(for: .backgrounds).appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return publicPath(for: .backgrounds, fileName: name)
        } catch {
            return nil
        }
    }

    // MARK: - Avatars

    /// Copies a picked `.vrm` into the media folder. Returns its public path.
    static func importAvatar(from sourceURL: URL) -> String? {
        let needsScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScope { sourceURL.stopAccessingSecurityScopedResource() } }

        let name = uniqueAvatarFileName(sanitized(sourceURL.lastPathComponent))
        let destination = directoryURL(for: .avatars).appendingPathComponent(name)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return publicPath(for: .avatars, fileName: name)
        } catch {
            return nil
        }
    }

    static func importedAvatars() -> [AmicaImportedAvatar] {
        let directory = directoryURL(for: .avatars)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { $0.pathExtension.lowercased() == "vrm" }
            .map { url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return AmicaImportedAvatar(
                    fileName: url.lastPathComponent,
                    byteSize: Int64(size)
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static func deleteAvatar(fileName: String) {
        let url = directoryURL(for: .avatars).appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }

    /// Every imported model as a `/media/...` path.
    ///
    /// The bundled page resolves "which model to show" by looking the configured
    /// `vrm_url` up in a list held in memory, and that list only ever contains the
    /// four model URLs compiled into it. Imported files therefore have to be added
    /// to that list at runtime — see the `__scowldExtraVrms` hook in the patched
    /// `index-aadeae00c0804a21.js`.
    static func importedAvatarPublicPaths() -> [String] {
        importedAvatars().map(\.publicPath)
    }

    /// File that the free `AvatarSample_D.vrm` slot should serve.
    ///
    /// The bundled list declares four models but ships only three files, so
    /// `AvatarSample_D` is a permanent 404. Pointing it at whatever imported model
    /// is selected gives the viewer a whitelisted address to fall back on.
    static func slotOverrideFileURL(defaults: UserDefaults = .standard) -> URL? {
        let selected = defaults.string(forKey: "selected_avatar") ?? ""
        guard selected.hasPrefix("/") else { return nil }
        return fileURL(forPublicPath: selected)
    }

    // MARK: - Music

    /// Extensions the system can decode and that we accept from the picker.
    static let musicExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "ogg", "opus",
    ]

    /// Copies a picked audio file into the media folder. Returns its public path.
    static func importMusic(from sourceURL: URL) -> String? {
        let needsScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScope { sourceURL.stopAccessingSecurityScopedResource() } }

        let ext = sourceURL.pathExtension.lowercased()
        guard musicExtensions.contains(ext) else { return nil }

        let name = uniqueFileName(sanitized(sourceURL.lastPathComponent), in: .music)
        let destination = directoryURL(for: .music).appendingPathComponent(name)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return publicPath(for: .music, fileName: name)
        } catch {
            return nil
        }
    }

    static func importedMusic() -> [AmicaMediaFile] {
        files(in: .music) { url in
            musicExtensions.contains(url.pathExtension.lowercased())
        }
    }

    static func deleteMusic(fileName: String) {
        let url = directoryURL(for: .music).appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Lists

    /// Every file of a kind, newest name ordering aside. Shared by the avatar and
    /// music pickers.
    static func files(
        in kind: Kind,
        matching isIncluded: (URL) -> Bool = { _ in true }
    ) -> [AmicaMediaFile] {
        let directory = directoryURL(for: kind)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter(isIncluded)
            .map { url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return AmicaMediaFile(kind: kind, fileName: url.lastPathComponent, byteSize: Int64(size))
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // MARK: - Helpers

    private static func sanitized(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let result = String(cleaned)
        return result.isEmpty ? "avatar.vrm" : result
    }

    private static func uniqueFileName(_ name: String, in kind: Kind) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var counter = 2
        while FileManager.default.fileExists(
            atPath: directoryURL(for: kind).appendingPathComponent(candidate).path
        ) {
            candidate = "\(base)-\(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    private static func uniqueAvatarFileName(_ name: String) -> String {
        uniqueFileName(name, in: .avatars)
    }
}

// MARK: - Imported avatar

/// A file the user added, in whichever media folder it lives.
struct AmicaMediaFile: Identifiable, Hashable {
    let kind: AmicaUserMedia.Kind
    let fileName: String
    let byteSize: Int64

    var id: String { "\(kind.rawValue)/\(fileName)" }

    var displayName: String { (fileName as NSString).deletingPathExtension }

    /// Where the viewer or player can read it, e.g. `/media/music/song.mp3`.
    var publicPath: String { AmicaUserMedia.publicPath(for: kind, fileName: fileName) }

    var sizeLabel: String { String(format: "%.1f MB", Double(byteSize) / 1_048_576) }
}

struct AmicaImportedAvatar: Identifiable, Hashable {
    let fileName: String
    let byteSize: Int64

    var id: String { fileName }

    var displayName: String { (fileName as NSString).deletingPathExtension }

    /// What gets stored in `selected_avatar` and handed to the viewer.
    var publicPath: String { AmicaUserMedia.publicPath(for: .avatars, fileName: fileName) }

    var sizeLabel: String { String(format: "%.1f MB", Double(byteSize) / 1_048_576) }
}

// MARK: - Avatar selection

/// Maps the stored `selected_avatar` value onto a URL the viewer can load.
enum AmicaAvatarSelection {
    /// Imported avatars are stored as a `/media/...` path, built-ins as a plain
    /// file name such as `AvatarSample_A`.
    static func vrmURL(for storedValue: String) -> String {
        storedValue.hasPrefix("/") ? storedValue : "/vrm/\(storedValue).vrm"
    }

    static func isImported(_ storedValue: String) -> Bool {
        storedValue.hasPrefix("/")
    }

    /// Name shown for the current selection, falling back to the pack name.
    static func displayName(for storedValue: String, characterName: String) -> String {
        if storedValue.hasPrefix("/") {
            let file = (storedValue as NSString).lastPathComponent
            return (file as NSString).deletingPathExtension
        }
        return CharacterPack.defaultPacks.first { $0.fileName == storedValue }?.displayName ?? characterName
    }
}
