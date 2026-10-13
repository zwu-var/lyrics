import Foundation

struct LyricLine {
    let time: TimeInterval
    let text: String
}

enum Lyrics {
    case synced([LyricLine])
    /// LRCLIB knows the song but has no timestamps for it, so there is nothing to sync.
    case unsyncedOnly
    case instrumental
    case notFound
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

enum LRCLibError: Error {
    case http(status: Int)
}

/// Client for https://lrclib.net, a free, open lyrics database (no API key).
enum LRCLib {
    private static let baseURL = URL(string: "https://lrclib.net/api")!

    /// Search results come back loosely matched; a different cut of the song (radio edit, live) would have
    /// differently timed lyrics. LRCLIB's own exact lookup allows ±2 s, so this is a bit more lenient.
    private static let maxDurationMismatch: TimeInterval = 5

    private struct Record: Decodable {
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    static func fetchLyrics(for track: Track) async throws -> Lyrics {
        // LRCLIB answers some exact-lookup misses with 503 rather than 404, so any failure here falls through to
        // search. If LRCLIB is actually unreachable, search throws and the caller sees that.
        let exact = try? await getExact(track)
        let exactSynced = exact?.syncedLyrics.map(LRC.parse) ?? []
        if !exactSynced.isEmpty {
            return .synced(exactSynced)
        }
        if exact?.instrumental == true {
            return .instrumental
        }

        var candidates = try await search(title: track.title, artist: track.artist)
        let simplified = simplifiedTitle(track.title)
        if simplified != track.title {
            candidates += try await search(title: simplified, artist: track.artist)
        }

        let closestSynced = candidates
            .compactMap { record -> (mismatch: TimeInterval, lines: [LyricLine])? in
                guard let duration = record.duration, let synced = record.syncedLyrics else { return nil }
                let lines = LRC.parse(synced)
                return lines.isEmpty ? nil : (abs(duration - track.duration), lines)
            }
            .filter { $0.mismatch <= maxDurationMismatch }
            .min { $0.mismatch < $1.mismatch }

        switch closestSynced {
        case let match?:
            return .synced(match.lines)
        case nil where exact?.plainLyrics != nil || candidates.contains(where: { $0.plainLyrics != nil }):
            return .unsyncedOnly
        case nil:
            return .notFound
        }
    }

    /// Spotify titles often carry suffixes that LRCLIB entries lack,
    /// e.g. "Song - Remastered 2011" or "Song (feat. Someone)".
    static func simplifiedTitle(_ title: String) -> String {
        let withoutDashSuffix = title.range(of: " - ").map { String(title[..<$0.lowerBound]) } ?? title
        return withoutDashSuffix
            .replacingOccurrences(
                of: #"\s*[(\[](feat\.?|ft\.?|with)\s[^)\]]*[)\]]"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .trimmingCharacters(in: .whitespaces)
    }

    private static func getExact(_ track: Track) async throws -> Record? {
        let data = try await request(path: "get", query: [
            "track_name": track.title,
            "artist_name": track.artist,
            "album_name": track.album,
            "duration": String(Int(track.duration.rounded())),
        ])
        return try data.map { try JSONDecoder().decode(Record.self, from: $0) }
    }

    private static func search(title: String, artist: String) async throws -> [Record] {
        let data = try await request(path: "search", query: ["track_name": title, "artist_name": artist])
        return try data.map { try JSONDecoder().decode([Record].self, from: $0) } ?? []
    }

    /// Returns nil on 404, which LRCLIB uses for "no such track".
    private static func request(path: String, query: [String: String]) async throws -> Data? {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents leaves "+" unescaped, and servers commonly decode a bare "+" as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")

        var request = URLRequest(url: components.url!)
        // LRCLIB asks clients to identify themselves.
        request.setValue("LyricsBar/1.0 (personal use)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        switch status {
        case 200:
            return data
        case 404:
            return nil
        default:
            throw LRCLibError.http(status: status ?? -1)
        }
    }
}
