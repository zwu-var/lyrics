import Foundation

/// Client for https://lrclib.net, a free, open lyrics database (no API key).
enum LRCLib {
    private static let baseURL = URL(string: "https://lrclib.net/api")!

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
        if SongMatching.isPlausible(exactSynced, forDuration: track.duration) {
            return .synced(exactSynced, from: .lrclib)
        }
        if exact?.instrumental == true {
            return .instrumental
        }

        var candidates = try await search(title: track.title, artist: track.artist)
        let baseTitle = SongMatching.baseTitle(track.title)
        if baseTitle != track.title {
            candidates += try await search(title: baseTitle, artist: track.artist)
        }

        let closestSynced = candidates
            .compactMap { record -> (mismatch: TimeInterval, lines: [LyricLine])? in
                guard let duration = record.duration, let synced = record.syncedLyrics else { return nil }
                let lines = LRC.parse(synced)
                return SongMatching.isPlausible(lines, forDuration: track.duration)
                    ? (abs(duration - track.duration), lines)
                    : nil
            }
            .filter { $0.mismatch <= SongMatching.maxDurationMismatch }
            .min { $0.mismatch < $1.mismatch }

        switch closestSynced {
        case let match?:
            return .synced(match.lines, from: .lrclib)
        case nil where exact?.plainLyrics != nil || candidates.contains(where: { $0.plainLyrics != nil }):
            return .unsyncedOnly
        case nil:
            return .notFound
        }
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
        let url = baseURL.appendingPathComponent(path)
        let (status, body) = try await HTTP.get(url, query: query)
        switch status {
        case 200:
            return body
        case 404:
            return nil
        default:
            throw HTTP.UnexpectedResponse(url: url, detail: "HTTP \(status)")
        }
    }
}
