import Foundation

struct LyricLine {
    let time: TimeInterval
    let text: String
}

enum LyricsProvider: String {
    case lrclib = "LRCLIB"
    case netEase = "NetEase"
}

enum Lyrics {
    case synced([LyricLine], from: LyricsProvider)
    /// The song was found, but without timestamps that fit this recording.
    case unsyncedOnly
    case instrumental
    case notFound
}

enum LyricsSources {
    /// LRCLIB first: it's an open database with a documented API. NetEase's API is unofficial, but it covers
    /// Chinese-language music (e.g. 90s Cantopop) that LRCLIB lacks.
    private static let lookupOrder: [LyricsProvider] = [.lrclib, .netEase]

    /// Throws only when no provider had synced lyrics and at least one failed, so the caller retries later
    /// instead of remembering a "not found" that was really a network error.
    static func fetchLyrics(for track: Track) async throws -> Lyrics {
        var firstError: (any Error)?
        var foundUnsynced = false
        for provider in lookupOrder {
            do {
                let lyrics = try await fetchLyrics(for: track, from: provider)
                switch lyrics {
                case .synced, .instrumental:
                    return lyrics
                case .unsyncedOnly:
                    foundUnsynced = true
                case .notFound:
                    break
                }
            } catch {
                NSLog("LyricsBar: %@ lookup failed for %@: %@", provider.rawValue, track.title, String(describing: error))
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
        return foundUnsynced ? .unsyncedOnly : .notFound
    }

    private static func fetchLyrics(for track: Track, from provider: LyricsProvider) async throws -> Lyrics {
        switch provider {
        case .lrclib: try await LRCLib.fetchLyrics(for: track)
        case .netEase: try await NetEase.fetchLyrics(for: track)
        }
    }
}

enum LRC {
    /// Parses LRC text such as "[01:23.45]some line". A repeated line may carry several timestamps
    /// ("[00:10.00][01:20.00]chorus"). Lines without a timestamp, including metadata tags like "[ar:...]", are dropped.
    static func parse(_ text: String) -> [LyricLine] {
        text.split(whereSeparator: \.isNewline)
            .flatMap(parseLine)
            .sorted { $0.time < $1.time }
    }

    private static func parseLine(_ line: Substring) -> [LyricLine] {
        var rest = line
        var times: [TimeInterval] = []
        while rest.hasPrefix("["),
              let close = rest.firstIndex(of: "]"),
              let time = parseTimestamp(rest[rest.index(after: rest.startIndex)..<close]) {
            times.append(time)
            rest = rest[rest.index(after: close)...]
        }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return times.map { LyricLine(time: $0, text: text) }
    }

    /// "mm:ss.xx" → seconds.
    private static func parseTimestamp(_ timestamp: Substring) -> TimeInterval? {
        let parts = timestamp.split(separator: ":")
        guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) else {
            return nil
        }
        return minutes * 60 + seconds
    }

    /// The line being sung at `position`, or nil before the first line starts.
    static func line(in lines: [LyricLine], at position: TimeInterval) -> LyricLine? {
        lines.last { $0.time <= position }
    }
}

/// Deciding whether a lyrics database entry is the song Spotify is playing.
enum SongMatching {
    /// Lyrics are timed to one recording, and a different cut (radio edit, live) usually differs in length by more
    /// than this. LRCLIB's own exact lookup allows ±2 s; this is a little more lenient.
    static let maxDurationMismatch: TimeInterval = 5

    /// Strips what Spotify and lyrics databases tend to disagree on: suffixes like " - Remastered 2011" and bracketed
    /// parts like "(feat. Someone)" or "(Live)". Different versions are told apart by duration instead.
    static func baseTitle(_ title: String) -> String {
        let withoutDashSuffix = title.range(of: " - ").map { String(title[..<$0.lowerBound]) } ?? title
        let withoutBrackets = withoutDashSuffix
            .replacingOccurrences(of: #"\s*[(\[（【][^)\]）】]*[)\]）】]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // A title that is nothing but brackets, e.g. "(Untitled)", is its own base title.
        return withoutBrackets.isEmpty ? title : withoutBrackets
    }

    /// A form of a title or artist name for comparing across sources: ignores case, full-width vs half-width
    /// characters, whitespace, and Traditional vs Simplified Chinese (Spotify has 吻別, NetEase stores 吻别).
    static func comparable(_ name: String) -> String {
        let simplified = name.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? name
        return simplified
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { !$0.isWhitespace }
    }

    /// Rejects lyrics that can't be timed to this recording: untimed text with every line stamped at the same moment,
    /// or lines running past the end of the song (e.g. a NetEase entry copied from a longer version).
    static func isPlausible(_ lines: [LyricLine], forDuration duration: TimeInterval) -> Bool {
        guard let first = lines.first, let last = lines.last else { return false }
        return last.time > first.time && last.time <= duration
    }
}

enum HTTP {
    struct UnexpectedResponse: Error {
        let url: URL
        let detail: String
    }

    static func get(_ url: URL, query: [String: String]) async throws -> (status: Int, body: Data) {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents leaves "+" unescaped, and servers commonly decode a bare "+" as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")

        var request = URLRequest(url: components.url!)
        // LRCLIB asks clients to identify themselves; every source gets the same honest User-Agent.
        request.setValue("LyricsBar/1.0 (personal use)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (body, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UnexpectedResponse(url: url, detail: "not an HTTP response")
        }
        return (http.statusCode, body)
    }
}
