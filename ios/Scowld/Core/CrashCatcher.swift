import Foundation
import UIKit

/// Records how far the app got, and — if it dies — why.
///
/// This exists because the usual route was closed: the app is installed by
/// re-signing an unsigned package, and no crash log for it could be found on the
/// device. Guessing at an invisible crash wastes a build every time.
///
/// So the app keeps its own trail. `breadcrumb` writes a line the moment
/// something happens, and the handlers below append the exception or signal plus
/// the stack that led to it. The next launch puts that report on screen, where it
/// can be read and copied.
enum CrashCatcher {

    private static let folderName = "ScowldMedia"
    private static let fileName = "diagnostic.log"
    private static let crashMarkers = ["=== SIGNAL", "=== UNCAUGHT EXCEPTION"]

    /// Report left behind by the previous run, if it ended badly.
    private(set) static var pendingReport: String?

    private static let lock = NSLock()
    private static var installed = false

    // MARK: - Location

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent(folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder.appendingPathComponent(fileName)
    }

    // MARK: - Install

    static func install() {
        guard !installed else { return }
        installed = true

        // Whatever is on disk was written by the run that just ended. It is only
        // worth showing if it actually contains a crash.
        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            if crashMarkers.contains(where: { text.contains($0) }) {
                pendingReport = tail(of: text)
            }
        }
        try? FileManager.default.removeItem(at: fileURL)

        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.joined(separator: "\n")
            append("""


            === UNCAUGHT EXCEPTION ===
            \(exception.name.rawValue): \(exception.reason ?? "no reason given")
            \(stack)

            """)
        }

        for number in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(number) { caught in
                let stack = Thread.callStackSymbols.joined(separator: "\n")
                append("""


                === SIGNAL \(caught) ===
                \(stack)

                """)
                // Hand back to the system so the app still dies the way it should.
                signal(caught, SIG_DFL)
                raise(caught)
            }
        }

        breadcrumb("app launched")
    }

    // MARK: - Trail

    /// Marks progress. Called from places that are about to do something that has
    /// taken the app down before, so the last line in the file names the culprit.
    static func breadcrumb(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        let stamp = timestamp()
        append("[\(stamp)] \(text)\n")
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    /// Appends and flushes immediately. A buffered write would be lost with the
    /// process, which is exactly when the text matters.
    private static func append(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let path = fileURL.path
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.synchronize()
        } else {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    private static func tail(of text: String, limit: Int = 160) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > limit else { return text }
        return "... " + String(lines.count - limit) + " earlier lines omitted ...\n"
            + lines.suffix(limit).joined(separator: "\n")
    }

    // MARK: - Housekeeping

    static func clearPendingReport() {
        pendingReport = nil
        try? FileManager.default.removeItem(at: fileURL)
    }
}
