import Photos
import UIKit

/// 다운로드 링크는 앱이 실제로 듣고 있는 주소로 만들어야 한다.
enum DownloadLink {

    static func url(forKey key: String) -> String {
        let host = NetworkInfo.preferredIPv4() ?? "127.0.0.1"
        return "http://\(host):\(RuntimeConfig.shared.port)/download/\(key)"
    }

    static func curl(forKey key: String, filename: String) -> String {
        "curl -H \"Authorization: Bearer $ASSETBRIDGE_TOKEN\" -o \"\(filename)\" \"\(url(forKey: key))\""
    }
}

final class PhotosProvider: ToolProvider {

    let domain = ToolDomain.photos
    private let library = PhotoLibraryService.shared

    /// 한 장의 사진이 base64 로 실려갈 때의 상한. 모델 컨텍스트를 지키기 위한 값.
    private let maxImageBytes = 900_000

    // MARK: - Tools

    lazy var tools: [MCPTool] = [
        MCPTool(
            name: "photos_search",
            title: "사진 검색",
            description: """
            사진·동영상을 조건으로 찾아 메타데이터 목록을 돌려준다. 이미지는 포함하지 않으므로 저렴하다.
            먼저 이 도구로 후보를 좁힌 뒤 photos_contact_sheet 나 photos_view 로 실제 내용을 확인하라.
            """,
            inputSchema: Schema.object([
                "album_id": Schema.string("photos_list_albums 가 돌려준 앨범 ID. 생략하면 전체 라이브러리."),
                "media_type": Schema.string("미디어 종류", values: ["image", "video", "audio", "any"], defaultValue: "any"),
                "subtype": Schema.string("세부 종류 필터", values: ["screenshot", "live", "panorama", "hdr", "portrait", "slomo", "timelapse", "cinematic"]),
                "start_date": Schema.date("이 시각 이후에 촬영된 것만."),
                "end_date": Schema.date("이 시각 이전에 촬영된 것만."),
                "favorites_only": Schema.boolean("즐겨찾기만.", defaultValue: false),
                "has_location": Schema.boolean("GPS 좌표 유무로 거른다."),
                "limit": Schema.integer("최대 개수", minimum: 1, maximum: 300, defaultValue: 50),
                "offset": Schema.integer("건너뛸 개수(페이지네이션)", minimum: 0, defaultValue: 0),
                "sort": Schema.string("정렬 순서", values: ["newest", "oldest"], defaultValue: "newest")
            ]),
            domain: .photos
        ),

        MCPTool(
            name: "photos_contact_sheet",
            title: "사진 한눈에 보기",
            description: """
            여러 장을 번호가 붙은 격자 이미지 한 장으로 합쳐서 돌려준다.
            여러 사진을 훑어봐야 할 때는 photos_view 를 반복하지 말고 반드시 이 도구를 써라.
            asset_ids 를 주면 그 사진들을, 주지 않으면 photos_search 와 같은 필터로 찾은 결과를 배치한다.
            응답의 텍스트 부분에 번호 → asset_id 대응표가 들어 있다.
            """,
            inputSchema: Schema.object([
                "asset_ids": Schema.stringArray("배치할 자산 ID 목록.", maxItems: 30),
                "album_id": Schema.string("asset_ids 를 생략했을 때 사용할 앨범 ID."),
                "media_type": Schema.string("미디어 종류", values: ["image", "video", "any"], defaultValue: "any"),
                "subtype": Schema.string("세부 종류 필터", values: ["screenshot", "live", "panorama", "hdr", "portrait", "slomo", "timelapse", "cinematic"]),
                "start_date": Schema.date("이 시각 이후."),
                "end_date": Schema.date("이 시각 이전."),
                "favorites_only": Schema.boolean("즐겨찾기만.", defaultValue: false),
                "limit": Schema.integer("asset_ids 미지정 시 배치할 장수", minimum: 1, maximum: 30, defaultValue: 12),
                "columns": Schema.integer("격자 열 수", minimum: 1, maximum: 6, defaultValue: 4),
                "cell_size": Schema.integer("칸 한 변의 픽셀", minimum: 96, maximum: 512, defaultValue: 240)
            ]),
            domain: .photos
        ),

        MCPTool(
            name: "photos_view",
            title: "사진 보기",
            description: """
            사진 한 장(또는 몇 장)을 이미지로 돌려준다. 자세히 봐야 하는 사진만 골라서 부르고,
            max_dimension 은 필요한 만큼만 올려라. 텍스트만 읽으면 되는 스크린샷은 photos_read_text 가 더 낫다.
            """,
            inputSchema: Schema.object([
                "asset_ids": Schema.stringArray("볼 자산 ID. 최대 6개.", maxItems: 6),
                "max_dimension": Schema.integer("긴 변의 최대 픽셀", minimum: 128, maximum: 2048, defaultValue: 1024),
                "quality": Schema.number("JPEG 품질", minimum: 0.1, maximum: 1.0, defaultValue: 0.75)
            ], required: ["asset_ids"]),
            domain: .photos
        ),

        MCPTool(
            name: "photos_read_text",
            title: "사진 속 글자 읽기 (OCR)",
            description: """
            기기 내장 Vision OCR 로 사진 속 글자를 뽑아낸다. 스크린샷·문서·간판을 읽을 때
            이미지를 그대로 보는 것보다 정확하고 토큰도 훨씬 적게 든다.
            """,
            inputSchema: Schema.object([
                "asset_id": Schema.string("대상 자산 ID."),
                "languages": Schema.stringArray("인식 언어 코드. 기본값 [\"ko-KR\", \"en-US\"].")
            ], required: ["asset_id"]),
            domain: .photos
        ),

        MCPTool(
            name: "photos_video_frame",
            title: "동영상 프레임 추출",
            description: "동영상의 특정 시점 프레임을 이미지로 돌려준다.",
            inputSchema: Schema.object([
                "asset_id": Schema.string("동영상 자산 ID."),
                "seconds": Schema.number("추출할 시점(초)", minimum: 0, defaultValue: 0),
                "max_dimension": Schema.integer("긴 변의 최대 픽셀", minimum: 128, maximum: 2048, defaultValue: 1024)
            ], required: ["asset_id"]),
            domain: .photos
        ),

        MCPTool(
            name: "photos_get_details",
            title: "사진 상세 정보",
            description: "해상도, 촬영 시각, GPS, 원본 파일명 등 자산 하나의 전체 메타데이터.",
            inputSchema: Schema.object([
                "asset_id": Schema.string("대상 자산 ID.")
            ], required: ["asset_id"]),
            domain: .photos
        ),

        MCPTool(
            name: "photos_list_albums",
            title: "앨범 목록",
            description: "사용자 앨범과 시스템 스마트 앨범(즐겨찾기, 스크린샷, 셀피 등)의 ID와 항목 수.",
            inputSchema: Schema.object([
                "include_smart_albums": Schema.boolean("스마트 앨범 포함 여부", defaultValue: true)
            ]),
            domain: .photos
        ),

        MCPTool(
            name: "photos_stats",
            title: "라이브러리 통계",
            description: "사진/동영상 개수, 종류별 집계, 가장 오래된·최근 항목 날짜. 라이브러리 규모를 먼저 가늠할 때 쓴다.",
            domain: .photos
        ),

        MCPTool(
            name: "photos_export",
            title: "원본 내보내기",
            description: """
            자산을 파일로 내보내고 인증이 걸린 다운로드 URL 을 돌려준다.
            원본 화질이 필요하거나 파일 자체를 다뤄야 할 때 쓴다(응답에 curl 예시가 포함된다).
            링크는 30분 뒤 만료된다.
            """,
            inputSchema: Schema.object([
                "asset_id": Schema.string("대상 자산 ID."),
                "format": Schema.string("original 은 원본 파일 그대로, jpeg 는 축소 변환본.", values: ["original", "jpeg"], defaultValue: "original"),
                "max_dimension": Schema.integer("format=jpeg 일 때 긴 변 픽셀", minimum: 256, maximum: 8192, defaultValue: 2048),
                "save_to_files": Schema.boolean("파일 앱의 AssetBridge/Exports 에도 복사한다.", defaultValue: false)
            ], required: ["asset_id"]),
            domain: .photos
        ),

        MCPTool(
            name: "photos_set_favorite",
            title: "즐겨찾기 설정",
            description: "자산의 즐겨찾기 상태를 켜거나 끈다.",
            inputSchema: Schema.object([
                "asset_id": Schema.string("대상 자산 ID."),
                "favorite": Schema.boolean("true 면 즐겨찾기 추가.", defaultValue: true)
            ], required: ["asset_id"]),
            domain: .photos,
            isWrite: true
        ),

        MCPTool(
            name: "photos_create_album",
            title: "앨범 만들기",
            description: "새 사용자 앨범을 만들고 ID 를 돌려준다.",
            inputSchema: Schema.object([
                "title": Schema.string("앨범 이름."),
                "asset_ids": Schema.stringArray("만들면서 함께 넣을 자산 ID(선택).")
            ], required: ["title"]),
            domain: .photos,
            isWrite: true
        ),

        MCPTool(
            name: "photos_add_to_album",
            title: "앨범에 추가",
            description: "기존 사용자 앨범에 자산을 추가한다. 스마트 앨범에는 추가할 수 없다.",
            inputSchema: Schema.object([
                "album_id": Schema.string("사용자 앨범 ID."),
                "asset_ids": Schema.stringArray("추가할 자산 ID 목록.")
            ], required: ["album_id", "asset_ids"]),
            domain: .photos,
            isWrite: true
        )
    ]

    // MARK: - Dispatch

    func call(_ name: String, arguments: [String: Any]) async throws -> ToolOutput {
        try library.ensureAuthorized()

        switch name {
        case "photos_search": return try search(arguments)
        case "photos_contact_sheet": return try await contactSheet(arguments)
        case "photos_view": return try await view(arguments)
        case "photos_read_text": return try await readText(arguments)
        case "photos_video_frame": return try await videoFrame(arguments)
        case "photos_get_details": return try details(arguments)
        case "photos_list_albums": return listAlbums(arguments)
        case "photos_stats": return try stats()
        case "photos_export": return try await export(arguments)
        case "photos_set_favorite": return try await setFavorite(arguments)
        case "photos_create_album": return try await createAlbum(arguments)
        case "photos_add_to_album": return try await addToAlbum(arguments)
        default: throw ToolError("알 수 없는 도구: \(name)")
        }
    }

    // MARK: - Query parsing

    private func query(from arguments: [String: Any], defaultLimit: Int) -> PhotoLibraryService.Query {
        var query = PhotoLibraryService.Query()
        query.albumID = arguments.string("album_id")
        query.mediaType = arguments.string("media_type")
        query.subtype = arguments.string("subtype")
        query.startDate = DateParse.date(from: arguments.string("start_date"))
        query.endDate = DateParse.endDate(from: arguments.string("end_date"))
        query.favoritesOnly = arguments.bool("favorites_only") ?? false
        query.hasLocation = arguments.bool("has_location")
        query.limit = arguments.clampedInt("limit", default: defaultLimit, min: 1, max: 300)
        query.offset = arguments.clampedInt("offset", default: 0, min: 0, max: 1_000_000)
        query.newestFirst = (arguments.string("sort") ?? "newest") != "oldest"
        return query
    }

    private func limitedAccessNote() -> String? {
        library.isLimitedAccess
            ? "참고: 사진 접근이 '선택한 사진'으로 제한되어 있어 사용자가 허용한 항목만 보입니다."
            : nil
    }

    // MARK: - Read tools

    private func search(_ arguments: [String: Any]) throws -> ToolOutput {
        let page = try library.search(query(from: arguments, defaultLimit: 50))

        var payload: [String: Any] = [
            "total": page.total,
            "returned": page.assets.count,
            "offset": arguments.clampedInt("offset", default: 0, min: 0, max: 1_000_000),
            "assets": page.assets.map { library.summary($0) }
        ]
        if page.scanTruncated {
            payload["warning"] = "필터 조건상 전체 스캔이 필요해 최근 25,000개까지만 검사했습니다. 기간을 좁혀 다시 검색하세요."
        }
        if let note = limitedAccessNote() { payload["note"] = note }
        return .json(payload)
    }

    private func details(_ arguments: [String: Any]) throws -> ToolOutput {
        guard let id = arguments.string("asset_id") else { throw ToolError("asset_id 가 필요합니다.") }
        return .json(library.details(try library.asset(id: id)))
    }

    private func listAlbums(_ arguments: [String: Any]) -> ToolOutput {
        let includeSmart = arguments.bool("include_smart_albums") ?? true
        let albums = library.albums(includeSmart: includeSmart)
        var payload: [String: Any] = ["count": albums.count, "albums": albums]
        if let note = limitedAccessNote() { payload["note"] = note }
        return .json(payload)
    }

    private func stats() throws -> ToolOutput {
        .json(try library.stats())
    }

    private func view(_ arguments: [String: Any]) async throws -> ToolOutput {
        guard let ids = arguments.stringArray("asset_ids"), !ids.isEmpty else {
            throw ToolError("asset_ids 가 필요합니다.")
        }
        let assets = library.assets(ids: Array(ids.prefix(6)))
        guard !assets.isEmpty else { throw ToolError("주어진 ID 로 자산을 찾지 못했습니다.") }

        let maxDimension = CGFloat(arguments.clampedInt("max_dimension", default: 1024, min: 128, max: 2048))
        let quality = CGFloat(arguments.clampedDouble("quality", default: 0.75, min: 0.1, max: 1.0))

        var output = ToolOutput()
        for asset in assets {
            let rendered = try await library.jpeg(for: asset,
                                                  maxDimension: maxDimension,
                                                  quality: quality,
                                                  maxBytes: maxImageBytes)
            var meta = library.summary(asset)
            meta["rendered"] = "\(Int(rendered.size.width))x\(Int(rendered.size.height))"
            output.addJSON(meta)
            output.addImage(rendered.data)
        }
        if ids.count > assets.count {
            output.addText("요청한 \(ids.count)개 중 \(assets.count)개만 찾았습니다.")
        }
        return output
    }

    private func contactSheet(_ arguments: [String: Any]) async throws -> ToolOutput {
        let requested = arguments.stringArray("asset_ids")
        let assets: [PHAsset]
        if let requested, !requested.isEmpty {
            assets = library.assets(ids: Array(requested.prefix(30)))
        } else {
            var searchQuery = query(from: arguments, defaultLimit: 12)
            searchQuery.limit = arguments.clampedInt("limit", default: 12, min: 1, max: 30)
            assets = try library.search(searchQuery).assets
        }
        guard !assets.isEmpty else { throw ToolError("조건에 맞는 자산이 없습니다.") }

        let columns = arguments.clampedInt("columns", default: 4, min: 1, max: 6)
        let cellSize = CGFloat(arguments.clampedInt("cell_size", default: 240, min: 96, max: 512))

        var items: [ImageEncoding.SheetItem] = []
        var index: [[String: Any]] = []

        for (offset, asset) in assets.enumerated() {
            let number = offset + 1
            let thumbnail = try? await library.image(for: asset,
                                                     maxDimension: cellSize * 1.5,
                                                     contentMode: .aspectFill,
                                                     fast: true)
            let day = DateParse.iso8601(asset.creationDate).map { String($0.prefix(10)) } ?? "날짜 없음"
            let badge = asset.mediaType == .video
                ? "\(number)  ▶ \(Int(asset.duration))초"
                : "\(number)"

            items.append(ImageEncoding.SheetItem(label: badge, image: thumbnail, caption: day))
            var entry = library.summary(asset)
            entry["n"] = number
            index.append(entry)
        }

        let sheet = ImageEncoding.contactSheet(items: items, columns: columns, cellSize: cellSize)
        guard let data = ImageEncoding.jpeg(sheet, quality: 0.72, maxBytes: 1_400_000) else {
            throw ToolError("격자 이미지 인코딩에 실패했습니다.")
        }

        var output = ToolOutput()
        output.addJSON([
            "count": assets.count,
            "columns": columns,
            "legend": "격자 왼쪽 위 번호가 아래 목록의 n 값과 대응합니다.",
            "items": index
        ])
        output.addImage(data)
        return output
    }

    private func readText(_ arguments: [String: Any]) async throws -> ToolOutput {
        guard let id = arguments.string("asset_id") else { throw ToolError("asset_id 가 필요합니다.") }
        let asset = try library.asset(id: id)
        let languages = arguments.stringArray("languages") ?? ["ko-KR", "en-US"]
        let lines = try await library.recognizeText(in: asset, languages: languages)

        return .json([
            "asset_id": id,
            "line_count": lines.count,
            "languages": languages,
            "text": lines.joined(separator: "\n")
        ])
    }

    private func videoFrame(_ arguments: [String: Any]) async throws -> ToolOutput {
        guard let id = arguments.string("asset_id") else { throw ToolError("asset_id 가 필요합니다.") }
        let asset = try library.asset(id: id)
        let seconds = arguments.clampedDouble("seconds", default: 0, min: 0, max: 86_400)
        let maxDimension = CGFloat(arguments.clampedInt("max_dimension", default: 1024, min: 128, max: 2048))

        let frame = try await library.videoFrame(for: asset, atSeconds: seconds, maxDimension: maxDimension)
        guard let data = ImageEncoding.jpeg(frame, quality: 0.75, maxBytes: maxImageBytes) else {
            throw ToolError("프레임 인코딩에 실패했습니다.")
        }

        var output = ToolOutput()
        output.addJSON([
            "asset_id": id,
            "requested_seconds": seconds,
            "duration_sec": (asset.duration * 10).rounded() / 10
        ])
        output.addImage(data)
        return output
    }

    private func export(_ arguments: [String: Any]) async throws -> ToolOutput {
        guard let id = arguments.string("asset_id") else { throw ToolError("asset_id 가 필요합니다.") }
        let asset = try library.asset(id: id)

        let result: PhotoLibraryService.ExportResult
        if (arguments.string("format") ?? "original") == "jpeg" {
            let maxDimension = CGFloat(arguments.clampedInt("max_dimension", default: 2048, min: 256, max: 8192))
            result = try await library.exportJPEG(asset, maxDimension: maxDimension, quality: 0.9)
        } else {
            result = try await library.exportOriginal(asset)
        }

        let key = ExportStore.shared.register(url: result.url, filename: result.filename)

        var payload: [String: Any] = [
            "filename": result.filename,
            "bytes": result.byteCount,
            "download_url": DownloadLink.url(forKey: key),
            "auth": "Authorization: Bearer <토큰> 헤더가 필요합니다.",
            "curl": DownloadLink.curl(forKey: key, filename: result.filename),
            "expires_in_minutes": 30
        ]

        if arguments.bool("save_to_files") == true {
            do {
                let copied = try ExportStore.shared.copyToDocuments(from: result.url, filename: result.filename)
                payload["saved_to_files_app"] = copied.path
            } catch {
                payload["save_to_files_error"] = error.localizedDescription
            }
        }

        return .json(payload)
    }

    // MARK: - Write tools

    private func setFavorite(_ arguments: [String: Any]) async throws -> ToolOutput {
        guard let id = arguments.string("asset_id") else { throw ToolError("asset_id 가 필요합니다.") }
        let asset = try library.asset(id: id)
        let favorite = arguments.bool("favorite") ?? true
        try await library.setFavorite(asset, favorite: favorite)
        return .json(["asset_id": id, "favorite": favorite, "ok": true])
    }

    private func createAlbum(_ arguments: [String: Any]) async throws -> ToolOutput {
        guard let title = arguments.string("title"), !title.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolError("title 이 필요합니다.")
        }
        let albumID = try await library.createAlbum(title: title)

        var payload: [String: Any] = ["album_id": albumID, "title": title, "added": 0]
        if let ids = arguments.stringArray("asset_ids"), !ids.isEmpty {
            let assets = library.assets(ids: ids)
            if !assets.isEmpty {
                try await library.addAssets(assets, to: try library.collection(id: albumID))
                payload["added"] = assets.count
            }
        }
        return .json(payload)
    }

    private func addToAlbum(_ arguments: [String: Any]) async throws -> ToolOutput {
        guard let albumID = arguments.string("album_id") else { throw ToolError("album_id 가 필요합니다.") }
        guard let ids = arguments.stringArray("asset_ids"), !ids.isEmpty else {
            throw ToolError("asset_ids 가 필요합니다.")
        }
        let collection = try library.collection(id: albumID)
        guard collection.assetCollectionType == .album else {
            throw ToolError("스마트 앨범에는 사진을 추가할 수 없습니다. 사용자 앨범을 지정하세요.")
        }
        let assets = library.assets(ids: ids)
        try await library.addAssets(assets, to: collection)
        return .json(["album_id": albumID, "added": assets.count, "requested": ids.count])
    }
}
