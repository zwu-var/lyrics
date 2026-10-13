import AppKit

struct SpotifyTrackID: Hashable {
    let rawValue: String
}

struct Track {
    let id: SpotifyTrackID
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
}

struct NowPlaying {
    let track: Track
    let isPlaying: Bool
    /// Playback position Spotify reported at `capturedAt` (both in seconds; `capturedAt` is system uptime).
    let position: TimeInterval
    let capturedAt: TimeInterval

    /// Extrapolates between polls so the displayed line can advance faster than we poll Spotify.
    func estimatedPosition(at now: TimeInterval) -> TimeInterval {
        if isPlaying {
            position + (now - capturedAt)
        } else {
            position
        }
    }
}

enum SpotifyStatus {
    case notRunning
    case stopped
    case active(NowPlaying)
}

enum SpotifyError: Error {
    /// The user denied (or hasn't yet granted) LyricsBar permission to control Spotify.
    case notAuthorized
    case script(String)
}

@MainActor
enum Spotify {
    private static let bundleID = "com.spotify.client"

    private static let script: NSAppleScript? = NSAppleScript(source: """
        tell application "Spotify"
            set currentState to player state as string
            if currentState is "stopped" then return {currentState}
            set t to current track
            return {currentState, player position, id of t, name of t, artist of t, album of t, duration of t}
        end tell
        """)

    // Apple Event error codes (MacErrors.h).
    private static let errAEEventNotPermitted = -1743
    private static let errAEEventWouldRequireUserConsent = -1744
    private static let procNotFound = -600

    static func currentStatus() throws(SpotifyError) -> SpotifyStatus {
        // `tell application "Spotify"` would launch Spotify if it isn't running.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            return .notRunning
        }
        guard let script else { throw .script("failed to create AppleScript") }

        var errorInfo: NSDictionary?
        let reply = script.executeAndReturnError(&errorInfo)
        let capturedAt = ProcessInfo.processInfo.systemUptime

        if let errorInfo {
            switch errorInfo[NSAppleScript.errorNumber] as? Int {
            case errAEEventNotPermitted, errAEEventWouldRequireUserConsent:
                throw .notAuthorized
            case procNotFound:
                // Spotify quit between the running check and the Apple Event.
                return .notRunning
            default:
                throw .script(errorInfo[NSAppleScript.errorMessage] as? String ?? "\(errorInfo)")
            }
        }

        switch reply.atIndex(1)?.stringValue {
        case "stopped":
            return .stopped
        case let state? where state == "playing" || state == "paused":
            guard
                let id = reply.atIndex(3)?.stringValue,
                let title = reply.atIndex(4)?.stringValue,
                let artist = reply.atIndex(5)?.stringValue,
                let album = reply.atIndex(6)?.stringValue,
                let position = reply.atIndex(2)?.doubleValue,
                let rawDuration = reply.atIndex(7)?.doubleValue
            else {
                throw .script("unexpected reply from Spotify: \(reply)")
            }
            let track = Track(
                id: SpotifyTrackID(rawValue: id),
                title: title,
                artist: artist,
                album: album,
                duration: durationInSeconds(rawDuration)
            )
            return .active(NowPlaying(track: track, isPlaying: state == "playing", position: position, capturedAt: capturedAt))
        case let other:
            throw .script("unexpected player state: \(other ?? "nil")")
        }
    }

    /// Spotify's scripting dictionary documents `duration` in seconds, but the app has long returned milliseconds.
    /// No song is 10,000+ seconds (~2.8 hours) long, so a larger value can only be milliseconds.
    private static func durationInSeconds(_ raw: Double) -> TimeInterval {
        raw > 10_000 ? raw / 1000 : raw
    }
}
