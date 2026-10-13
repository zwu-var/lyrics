import AppKit

enum LyricsLookup {
    case loading
    case loaded(Lyrics)
    /// `at` is system uptime; the lookup is retried after `AppDelegate.lyricsRetryInterval`.
    case failed(at: TimeInterval)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Polling catches seeks, which Spotify's playback notification doesn't reliably announce.
    /// It's a local Apple Event, so once a second is cheap.
    private static let spotifyPollInterval: TimeInterval = 1.0
    /// Fast enough that a new line appears on time; the title is only touched when the line actually changes.
    private static let renderInterval: TimeInterval = 0.1
    /// Avoids hammering the lyrics sources every poll while offline.
    private static let lyricsRetryInterval: TimeInterval = 30

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let infoMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var spotify: Result<SpotifyStatus, SpotifyError> = .success(.notRunning)
    private var lyricsByTrack: [SpotifyTrackID: LyricsLookup] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.menu = makeMenu()

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(spotifyPlaybackChanged),
            name: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil
        )
        addTimer(every: Self.spotifyPollInterval, selector: #selector(syncWithSpotify))
        addTimer(every: Self.renderInterval, selector: #selector(render))

        syncWithSpotify()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        infoMenuItem.isEnabled = false
        menu.addItem(infoMenuItem)
        menu.addItem(.separator())
        let reload = NSMenuItem(title: "Reload Lyrics", action: #selector(reloadLyrics), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)
        menu.addItem(NSMenuItem(title: "Quit LyricsBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func addTimer(every interval: TimeInterval, selector: Selector) {
        let timer = Timer(timeInterval: interval, target: self, selector: selector, userInfo: nil, repeats: true)
        // `.common` keeps the lyrics moving while the menu is open (the run loop is in tracking mode then).
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func spotifyPlaybackChanged(_ notification: Notification) {
        syncWithSpotify()
    }

    @objc private func syncWithSpotify() {
        do {
            spotify = .success(try Spotify.currentStatus())
        } catch {
            spotify = .failure(error)
        }
        if case .success(.active(let nowPlaying)) = spotify {
            fetchLyricsIfNeeded(for: nowPlaying.track)
        }
        render()
    }

    private func fetchLyricsIfNeeded(for track: Track) {
        let shouldFetch = switch lyricsByTrack[track.id] {
        case nil: true
        case .loading, .loaded: false
        case .failed(let failedAt): ProcessInfo.processInfo.systemUptime - failedAt >= Self.lyricsRetryInterval
        }
        guard shouldFetch else { return }

        lyricsByTrack[track.id] = .loading
        Task {
            do {
                lyricsByTrack[track.id] = .loaded(try await LyricsSources.fetchLyrics(for: track))
            } catch {
                NSLog("LyricsBar: lyrics lookup failed for %@ by %@: %@", track.title, track.artist, String(describing: error))
                lyricsByTrack[track.id] = .failed(at: ProcessInfo.processInfo.systemUptime)
            }
            render()
        }
    }

    @objc private func reloadLyrics() {
        if case .success(.active(let nowPlaying)) = spotify {
            lyricsByTrack[nowPlaying.track.id] = nil
            fetchLyricsIfNeeded(for: nowPlaying.track)
        }
    }

    @objc private func render() {
        let text = menuBarText(now: ProcessInfo.processInfo.systemUptime)
        if statusItem.button?.title != text {
            statusItem.button?.title = text
        }
    }

    private func menuBarText(now: TimeInterval) -> String {
        switch spotify {
        case .failure(.notAuthorized):
            return "♪ Allow LyricsBar to control Spotify: System Settings › Privacy & Security › Automation"
        case .failure(.script):
            return "♪ ⚠︎"
        case .success(.notRunning), .success(.stopped):
            return "♪"
        case .success(.active(let nowPlaying)):
            let track = nowPlaying.track
            let songName = "♪ \(track.title) – \(track.artist)"
            let text = switch lyricsByTrack[track.id] {
            case .loaded(.synced(let lines, _)):
                switch LRC.line(in: lines, at: nowPlaying.estimatedPosition(at: now)) {
                // Before the first line, or an instrumental break (LRC marks those with an empty line).
                case nil: songName
                case let line? where line.text.isEmpty: songName
                case let line?: line.text
                }
            case .loaded(.unsyncedOnly), .loaded(.instrumental), .loaded(.notFound), .loading, .failed, nil:
                songName
            }
            return nowPlaying.isPlaying ? text : "⏸ \(text)"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        infoMenuItem.title = statusDescription()
    }

    private func statusDescription() -> String {
        switch spotify {
        case .failure(.notAuthorized):
            return "Not allowed to control Spotify"
        case .failure(.script(let message)):
            return "Spotify error: \(message)"
        case .success(.notRunning):
            return "Spotify is not running"
        case .success(.stopped):
            return "Spotify is stopped"
        case .success(.active(let nowPlaying)):
            let lyricsStatus = switch lyricsByTrack[nowPlaying.track.id] {
            case .loaded(.synced(let lines, let provider)): "synced lyrics from \(provider.rawValue), \(lines.count) lines"
            case .loaded(.unsyncedOnly): "found lyrics, but none timed to this recording"
            case .loaded(.instrumental): "instrumental"
            case .loaded(.notFound): "no lyrics found on LRCLIB or NetEase"
            case .loading, nil: "looking up lyrics…"
            case .failed: "lookup failed, will retry"
            }
            return "\(nowPlaying.track.title) – \(nowPlaying.track.artist): \(lyricsStatus)"
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// No Dock icon, even when the binary is run outside the .app bundle (the bundle sets LSUIElement too).
app.setActivationPolicy(.accessory)
app.run()
