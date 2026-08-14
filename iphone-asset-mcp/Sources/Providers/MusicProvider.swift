import Foundation
import MediaPlayer

final class MusicProvider: ToolProvider {

    let domain = ToolDomain.music

    lazy var tools: [MCPTool] = [
        MCPTool(
            name: "music_search_library",
            title: "음악 보관함 검색",
            description: """
            기기 음악 보관함에서 곡·앨범·아티스트를 찾는다.
            Apple Music 카탈로그가 아니라 이 기기에 담긴 항목만 대상이다.
            """,
            inputSchema: Schema.object([
                "query": Schema.string("검색어. 생략하면 최근 추가순으로 나열."),
                "scope": Schema.string("검색 대상", values: ["song", "album", "artist"], defaultValue: "song"),
                "limit": Schema.integer("최대 개수", minimum: 1, maximum: 200, defaultValue: 30)
            ]),
            domain: .music
        ),

        MCPTool(
            name: "music_playlists",
            title: "재생목록",
            description: "기기에 저장된 재생목록과 각 목록의 곡 수.",
            inputSchema: Schema.object([
                "include_items": Schema.boolean("각 재생목록의 곡 목록도 포함", defaultValue: false),
                "limit": Schema.integer("최대 재생목록 수", minimum: 1, maximum: 100, defaultValue: 30)
            ]),
            domain: .music
        ),

        MCPTool(
            name: "music_now_playing",
            title: "재생 중인 곡",
            description: "시스템 음악 플레이어가 지금 재생 중인 곡 정보와 재생 상태.",
            domain: .music
        )
    ]

    private func ensureAuthorized() throws {
        switch MPMediaLibrary.authorizationStatus() {
        case .notDetermined:
            throw ToolError("음악 보관함 권한이 아직 요청되지 않았습니다. iPhone 에서 AssetBridge 앱을 열어 허용하세요.")
        case .denied, .restricted:
            throw ToolError("음악 보관함 접근이 거부되어 있습니다. 설정 > 개인정보 보호 > 미디어 및 Apple Music 에서 허용하세요.")
        default:
            return
        }
    }

    @discardableResult
    func requestAuthorization() async -> MPMediaLibraryAuthorizationStatus {
        await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    func call(_ name: String, arguments: [String: Any]) async throws -> ToolOutput {
        switch name {
        case "music_search_library":
            try ensureAuthorized()
            return searchLibrary(arguments)
        case "music_playlists":
            try ensureAuthorized()
            return playlists(arguments)
        case "music_now_playing":
            return await nowPlaying()
        default:
            throw ToolError("알 수 없는 도구: \(name)")
        }
    }

    private func searchLibrary(_ arguments: [String: Any]) -> ToolOutput {
        let limit = arguments.clampedInt("limit", default: 30, min: 1, max: 200)
        let scope = arguments.string("scope") ?? "song"
        let needle = arguments.string("query")?.trimmingCharacters(in: .whitespaces)

        let query: MPMediaQuery
        switch scope {
        case "album": query = MPMediaQuery.albums()
        case "artist": query = MPMediaQuery.artists()
        default: query = MPMediaQuery.songs()
        }

        if let needle, !needle.isEmpty {
            let property: String
            switch scope {
            case "album": property = MPMediaItemPropertyAlbumTitle
            case "artist": property = MPMediaItemPropertyArtist
            default: property = MPMediaItemPropertyTitle
            }
            query.addFilterPredicate(MPMediaPropertyPredicate(value: needle,
                                                              forProperty: property,
                                                              comparisonType: .contains))
        }

        if scope == "song" {
            let items = query.items ?? []
            let trimmed = Array(items.prefix(limit))
            return .json([
                "scope": scope,
                "count": trimmed.count,
                "total": items.count,
                "songs": trimmed.map { Self.describe($0) }
            ])
        }

        let collections = query.collections ?? []
        let trimmed = Array(collections.prefix(limit))
        return .json([
            "scope": scope,
            "count": trimmed.count,
            "total": collections.count,
            "results": trimmed.map { collection -> [String: Any] in
                let representative = collection.representativeItem
                return [
                    "title": scope == "artist"
                        ? (representative?.artist ?? "알 수 없음")
                        : (representative?.albumTitle ?? "알 수 없음"),
                    "artist": JSONUtil.value(representative?.artist),
                    "track_count": collection.count
                ]
            }
        ])
    }

    private func playlists(_ arguments: [String: Any]) -> ToolOutput {
        let limit = arguments.clampedInt("limit", default: 30, min: 1, max: 100)
        let includeItems = arguments.bool("include_items") ?? false
        let collections = MPMediaQuery.playlists().collections ?? []

        let results = collections.prefix(limit).map { collection -> [String: Any] in
            var payload: [String: Any] = [
                "name": (collection.value(forProperty: MPMediaPlaylistPropertyName) as? String) ?? "이름 없음",
                "track_count": collection.count
            ]
            if includeItems {
                payload["tracks"] = collection.items.prefix(100).map { Self.describe($0) }
            }
            return payload
        }

        return .json(["count": results.count, "total": collections.count, "playlists": Array(results)])
    }

    @MainActor
    private func nowPlaying() -> ToolOutput {
        let player = MPMusicPlayerController.systemMusicPlayer
        guard let item = player.nowPlayingItem else {
            return .json(["playing": false, "state": Self.stateName(player.playbackState)])
        }
        var payload = Self.describe(item)
        payload["playing"] = player.playbackState == .playing
        payload["state"] = Self.stateName(player.playbackState)
        payload["position_sec"] = player.currentPlaybackTime.rounded()
        return .json(payload)
    }

    private static func describe(_ item: MPMediaItem) -> [String: Any] {
        var payload: [String: Any] = [
            "title": item.title ?? "제목 없음",
            "artist": JSONUtil.value(item.artist),
            "album": JSONUtil.value(item.albumTitle),
            "duration_sec": item.playbackDuration.rounded()
        ]
        if item.playCount > 0 { payload["play_count"] = item.playCount }
        if let genre = item.genre { payload["genre"] = genre }
        if let lastPlayed = item.lastPlayedDate {
            payload["last_played"] = JSONUtil.value(DateParse.iso8601(lastPlayed))
        }
        return payload
    }

    private static func stateName(_ state: MPMusicPlaybackState) -> String {
        switch state {
        case .playing: return "playing"
        case .paused: return "paused"
        case .stopped: return "stopped"
        case .interrupted: return "interrupted"
        case .seekingForward: return "seeking_forward"
        case .seekingBackward: return "seeking_backward"
        @unknown default: return "unknown"
        }
    }
}
