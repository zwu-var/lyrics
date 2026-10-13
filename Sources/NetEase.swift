import Foundation

/// Client for NetEase Cloud Music (网易云音乐). Its API is unofficial and undocumented, but it covers Chinese-language
/// music far better than LRCLIB; open-source lyrics apps such as LyricsX use it too.
enum NetEase {
    private static let searchURL = URL(string: "https://music.163.com/api/cloudsearch/pc")!
    private static let lyricURL = URL(string: "https://music.163.com/api/song/lyric")!
    /// Each candidate costs a lyric request, and past the few best matches it's unlikely to be the right recording.
    private static let maxCandidates = 3
    /// NetEase reports success in the JSON body; the HTTP status is 200 either way.
    private static let successCode = 200

    /// Every response carries this; see `get`.
    private struct ResponseCode: Decodable {
        let code: Int
    }

    private struct SearchResponse: Decodable {
        struct Result: Decodable {
            let songs: [Song]?
        }

        let result: Result?
    }

    private struct Song: Decodable {
        struct Artist: Decodable {
            let name: String
            /// Other names, e.g. 吴雨霏 is also listed as "Kary Ng", the name Spotify shows.
            let alias: [String]?
        }

        let id: Int
        let name: String
        let artists: [Artist]
        let durationMilliseconds: Double

        enum CodingKeys: String, CodingKey {
            case id, name
            case artists = "ar"
            case durationMilliseconds = "dt"
        }

        var duration: TimeInterval { durationMilliseconds / 1000 }

        func isPerformed(byAnyOf comparableArtists: Set<String>) -> Bool {
            artists.contains { artist in
                ([artist.name] + (artist.alias ?? [])).contains { comparableArtists.contains(SongMatching.comparable($0)) }
            }
        }
    }

    private struct LyricResponse: Decodable {
        struct LRCText: Decodable {
            let lyric: String?
        }

        let lrc: LRCText?
    }

    static func fetchLyrics(for track: Track) async throws -> Lyrics {
        let title = SongMatching.baseTitle(track.title)
        var candidates = matchingSongs(try await search("\(title) \(track.artist)"), for: track)
        if candidates.isEmpty {
            // NetEase may not know Spotify's name for the artist (English names appear only as aliases, if at all).
            candidates = matchingSongs(try await search(title), for: track)
        }

        var foundMistimedLyrics = false
        for song in candidates.prefix(maxCandidates) {
            let lines = try await lyrics(forSongID: song.id)
            if SongMatching.isPlausible(lines, forDuration: track.duration) {
                return .synced(lines, from: .netEase)
            }
            foundMistimedLyrics = foundMistimedLyrics || !lines.isEmpty
        }
        return foundMistimedLyrics ? .unsyncedOnly : .notFound
    }

    /// Songs with the same base title and a matching duration, best first: the right artist, then the closest duration.
    /// Other artists are kept because Spotify may use a name NetEase doesn't list; the duration check still applies.
    private static func matchingSongs(_ songs: [Song], for track: Track) -> [Song] {
        let wantedTitle = SongMatching.comparable(SongMatching.baseTitle(track.title))
        // Spotify joins multiple artists into one string.
        let wantedArtists = Set(track.artist.split(separator: ",").map { SongMatching.comparable(String($0)) })
        let rank = { (song: Song) in
            (song.isPerformed(byAnyOf: wantedArtists) ? 0 : 1, abs(song.duration - track.duration))
        }
        return songs
            .filter { SongMatching.comparable(SongMatching.baseTitle($0.name)) == wantedTitle }
            .filter { abs($0.duration - track.duration) <= SongMatching.maxDurationMismatch }
            .sorted { rank($0) < rank($1) }
    }

    private static func search(_ query: String) async throws -> [Song] {
        // type=1 searches songs (other types are albums, artists, playlists, ...).
        let response: SearchResponse = try await get(searchURL, query: ["s": query, "type": "1", "limit": "20"])
        return response.result?.songs ?? []
    }

    private static func lyrics(forSongID id: Int) async throws -> [LyricLine] {
        // Without `lv`, the response leaves out the lyrics entirely.
        let response: LyricResponse = try await get(lyricURL, query: ["id": String(id), "lv": "1"])
        return LRC.parse(response.lrc?.lyric ?? "")
    }

    private static func get<Response: Decodable>(_ url: URL, query: [String: String]) async throws -> Response {
        let (status, body) = try await HTTP.get(url, query: query)
        guard status == 200 else {
            throw HTTP.UnexpectedResponse(url: url, detail: "HTTP \(status)")
        }
        // Decode the code on its own first: error responses (e.g. rate limiting) don't have the success shape.
        let code = try JSONDecoder().decode(ResponseCode.self, from: body).code
        guard code == successCode else {
            throw HTTP.UnexpectedResponse(url: url, detail: "NetEase code \(code)")
        }
        return try JSONDecoder().decode(Response.self, from: body)
    }
}
