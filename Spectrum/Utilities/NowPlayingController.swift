import AppKit
import Foundation
import Observation
import OSLog

enum NowPlayingTarget: String, Sendable, Equatable {
    case music
    case spotify

    init?(bundleID: String?) {
        switch bundleID {
        case "com.apple.Music", "com.apple.iTunes":
            self = .music
        case "com.spotify.client":
            self = .spotify
        default:
            return nil
        }
    }

    var scriptBundleID: String {
        switch self {
        case .music: "com.apple.Music"
        case .spotify: "com.spotify.client"
        }
    }

    /// Scripting name. Spotify answers commands by bundle ID but often only
    /// exposes `current track` through the application name.
    var scriptName: String {
        switch self {
        case .music: "Music"
        case .spotify: "Spotify"
        }
    }

    var windowSourceName: String {
        switch self {
        case .music: "Apple Music"
        case .spotify: "Spotify"
        }
    }
}

/// Reads title and sends Play / Stop / Next / Previous to Music or Spotify via AppleScript.
/// Stays off the DSP and capture path.
@MainActor
@Observable
final class NowPlayingController {
    private(set) var title = ""
    private(set) var artist = ""
    private(set) var isPlaying = false
    private(set) var isAvailable = false
    private(set) var needsAutomationPermission = false
    private(set) var sourceDisplayName: String?
    private(set) var artworkImage: NSImage?

    var displayTitle: String {
        if !isAvailable { return "" }
        if needsAutomationPermission, title.isEmpty {
            return "Allow Automation for Music or Spotify in System Settings"
        }
        let track = Self.trackDisplay(songTitle: title, artist: artist)
        if track.isEmpty {
            return isPlaying ? "Title unavailable" : "Not playing"
        }
        return track
    }

    var windowTitle: String {
        Self.windowTitle(sourceName: sourceDisplayName, trackDisplay: Self.trackDisplay(songTitle: title, artist: artist), isAvailable: isAvailable)
    }

    nonisolated static func trackDisplay(songTitle: String, artist: String) -> String {
        let song = songTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let performer = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if song.isEmpty { return "" }
        if performer.isEmpty { return song }
        return "\(song) by \(performer)"
    }

    nonisolated static func windowTitle(sourceName: String?, trackDisplay: String, isAvailable: Bool) -> String {
        guard isAvailable, let sourceName, !sourceName.isEmpty else { return "Spectrum" }
        let track = trackDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
        if track.isEmpty { return "Spectrum - \(sourceName)" }
        return "Spectrum - \(sourceName) playing \(track)"
    }

    private var target: NowPlayingTarget?
    private var pollTask: Task<Void, Never>?
    private var attachToken = 0
    private var artworkKey = ""

    nonisolated static func supports(bundleID: String?) -> Bool {
        NowPlayingTarget(bundleID: bundleID) != nil
    }

    nonisolated static func supports(_ source: AudioSource) -> Bool {
        guard case .application(let process) = source else { return false }
        return supports(bundleID: process.bundleID)
    }

    func attach(to process: AudioProcess) {
        guard let next = NowPlayingTarget(bundleID: process.bundleID) else {
            detach()
            return
        }
        if target == next, isAvailable {
            return
        }
        detach()
        target = next
        sourceDisplayName = next.windowSourceName
        isAvailable = true
        startPolling()
    }

    func detach() {
        attachToken += 1
        pollTask?.cancel()
        pollTask = nil
        target = nil
        sourceDisplayName = nil
        isAvailable = false
        title = ""
        artist = ""
        isPlaying = false
        needsAutomationPermission = false
        artworkImage = nil
        artworkKey = ""
    }

    func play() { send(.play) }
    func stop() { send(.stop) }
    func next() { send(.next) }
    func previous() { send(.previous) }

    private enum Command {
        case play, stop, next, previous

        func source(for target: NowPlayingTarget) -> String {
            let verb: String
            switch (self, target) {
            case (.play, _): verb = "play"
            case (.stop, .music): verb = "stop"
            case (.stop, .spotify): verb = "pause"
            case (.next, _): verb = "next track"
            case (.previous, _): verb = "previous track"
            }
            return """
            tell application "\(target.scriptName)"
                \(verb)
            end tell
            """
        }
    }

    private func startPolling() {
        attachToken += 1
        let token = attachToken
        let target = self.target
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.refresh(target: target, token: token)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                await self?.refresh(target: target, token: token)
            }
        }
    }

    private func send(_ command: Command) {
        guard let target else { return }
        let token = attachToken
        let source = command.source(for: target)
        Task { [weak self] in
            _ = await Task.detached(priority: .utility) {
                AppleScriptRunner.run(source)
            }.value
            await self?.refresh(target: target, token: token)
        }
    }

    private func refresh(target: NowPlayingTarget?, token: Int) async {
        guard let target, token == attachToken else { return }
        let statusScript = Self.statusScript(for: target)
        let titleScript = Self.titleOnlyScript(for: target)
        let raw = await Task.detached(priority: .utility) {
            let status = AppleScriptRunner.run(statusScript)
            if status.lowercased().hasPrefix("error") || status.isEmpty {
                let title = AppleScriptRunner.run(titleScript)
                if title.lowercased().hasPrefix("error") || title.isEmpty {
                    return status.isEmpty ? "error|0|empty" : status
                }
                return "playing\t\(title)"
            }
            return status
        }.value
        guard token == attachToken else { return }
        apply(status: raw)
    }

    private func apply(status raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("error") || trimmed.isEmpty {
            let detail = trimmed.lowercased()
            let automationDenied =
                detail.contains("not authorized")
                || detail.contains("1743")
                || detail.contains("1002")
                || detail.contains("-1743")
                || detail.contains("access not allowed")
            if automationDenied {
                needsAutomationPermission = true
            }
            AppLog.permissions.debug("Now Playing script: \(raw, privacy: .public)")
            return
        }

        needsAutomationPermission = false
        let parts = trimmed.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let state = parts.first?.lowercased() ?? ""
        let name = parts.count > 1 ? parts[1] : ""
        let performer = parts.count > 2 ? parts[2] : ""
        if !name.isEmpty {
            title = name
            artist = performer
        }
        isPlaying = state.contains("playing") || (name.isEmpty == false && !state.contains("paus") && !state.contains("stop"))
        if state.contains("stop"), name.isEmpty {
            title = ""
            artist = ""
            isPlaying = false
            artworkImage = nil
            artworkKey = ""
        }
        refreshArtworkIfNeeded()
    }

    private func refreshArtworkIfNeeded() {
        guard let target, !title.isEmpty else {
            artworkImage = nil
            artworkKey = ""
            return
        }
        let key = "\(target.rawValue)|\(title)|\(artist)"
        guard key != artworkKey else { return }
        artworkKey = key
        let token = attachToken
        let expectedKey = key
        Task { [weak self] in
            let image = await Self.loadArtwork(for: target)
            guard let self, token == self.attachToken, self.artworkKey == expectedKey else { return }
            self.artworkImage = image
        }
    }

    nonisolated private static func loadArtwork(for target: NowPlayingTarget) async -> NSImage? {
        await Task.detached(priority: .utility) {
            switch target {
            case .music:
                return loadMusicArtwork()
            case .spotify:
                return loadSpotifyArtwork()
            }
        }.value
    }

    nonisolated private static func loadMusicArtwork() -> NSImage? {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("dk.byrdal.Spectrum.art.\(UUID().uuidString).img")
        let posix = dest.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Music"
            try
                if (count of artworks of current track) is 0 then return ""
                set d to raw data of artwork 1 of current track
            on error
                return ""
            end try
        end tell
        try
            set f to open for access POSIX file "\(posix)" with write permission
            set eof f to 0
            write d to f
            close access f
            return "\(posix)"
        on error
            try
                close access POSIX file "\(posix)"
            end try
            return ""
        end try
        """
        let path = AppleScriptRunner.run(script)
        defer { try? FileManager.default.removeItem(at: dest) }
        guard !path.isEmpty, !path.lowercased().hasPrefix("error") else { return nil }
        return NSImage(contentsOf: URL(fileURLWithPath: path))
    }

    nonisolated private static func loadSpotifyArtwork() -> NSImage? {
        let script = """
        tell application "Spotify"
            try
                return artwork url of current track
            on error errMsg number errNum
                return "error|" & errNum & "|" & errMsg
            end try
        end tell
        """
        let raw = AppleScriptRunner.run(script)
        let urlString = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty, !urlString.lowercased().hasPrefix("error"),
              let url = URL(string: urlString)
        else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    private static func statusScript(for target: NowPlayingTarget) -> String {
        let app = target.scriptName
        return """
        tell application "\(app)"
            try
                set stateText to "stopped"
                if player state is playing then
                    set stateText to "playing"
                else if player state is paused then
                    set stateText to "paused"
                end if
                set t to ""
                set a to ""
                try
                    set t to (name of current track) as text
                    set a to (artist of current track) as text
                end try
                return stateText & tab & t & tab & a
            on error errMsg number errNum
                return "error|" & errNum & "|" & errMsg
            end try
        end tell
        """
    }

    private static func titleOnlyScript(for target: NowPlayingTarget) -> String {
        """
        tell application "\(target.scriptName)"
            try
                return (name of current track) as text & tab & (artist of current track) as text
            on error errMsg number errNum
                return "error|" & errNum & "|" & errMsg
            end try
        end tell
        """
    }
}

enum AppleScriptRunner {
    static func run(_ source: String) -> String {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dk.byrdal.Spectrum.nowplaying.\(UUID().uuidString).applescript")
        do {
            try source.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            return "error|0|\(error.localizedDescription)"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [scriptURL.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: scriptURL)
            return "error|0|\(error.localizedDescription)"
        }

        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in group.leave() }
        if group.wait(timeout: .now() + 2.5) == .timedOut {
            process.terminate()
            try? FileManager.default.removeItem(at: scriptURL)
            return "error|timeout|AppleScript timed out"
        }

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try? FileManager.default.removeItem(at: scriptURL)
        if process.terminationStatus == 0, !out.isEmpty {
            return out
        }
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !out.isEmpty { return out }
        if !err.isEmpty { return "error|\(process.terminationStatus)|\(err)" }
        return "error|\(process.terminationStatus)|osascript failed"
    }
}
