import AVFoundation
import CoreLocation
import Photos
import UIKit
import Vision

/// PhotoKit 래퍼. 도구 계층이 PHAsset 세부사항을 몰라도 되게 감싼다.
final class PhotoLibraryService {

    static let shared = PhotoLibraryService()

    private let imageManager = PHImageManager.default()
    private let resourceManager = PHAssetResourceManager.default()

    private init() {}

    // MARK: - Authorization

    var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    @discardableResult
    func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { continuation.resume(returning: $0) }
        }
    }

    func ensureAuthorized() throws {
        switch authorizationStatus {
        case .authorized, .limited:
            return
        case .notDetermined:
            throw ToolError("사진 접근 권한이 아직 요청되지 않았습니다. iPhone 의 AssetBridge 앱을 열어 권한을 허용하세요.")
        default:
            throw ToolError("사진 접근이 거부되어 있습니다. 설정 > 개인정보 보호 > 사진에서 AssetBridge 를 허용하세요.")
        }
    }

    /// 제한 접근(limited)이면 사용자가 고른 사진만 보인다는 사실을 결과에 함께 알려준다.
    var isLimitedAccess: Bool { authorizationStatus == .limited }

    // MARK: - Lookup

    func asset(id: String) throws -> PHAsset {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw ToolError("자산을 찾을 수 없습니다: \(id)")
        }
        return asset
    }

    func assets(ids: [String]) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var found: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in found[asset.localIdentifier] = asset }
        // 요청 순서를 유지한다.
        return ids.compactMap { found[$0] }
    }

    // MARK: - Albums

    private static let smartAlbumSubtypes: [PHAssetCollectionSubtype] = [
        .smartAlbumUserLibrary,
        .smartAlbumRecentlyAdded,
        .smartAlbumFavorites,
        .smartAlbumScreenshots,
        .smartAlbumSelfPortraits,
        .smartAlbumVideos,
        .smartAlbumSlomoVideos,
        .smartAlbumTimelapses,
        .smartAlbumBursts,
        .smartAlbumLivePhotos,
        .smartAlbumPanoramas,
        .smartAlbumDepthEffect,
        .smartAlbumAnimated,
        .smartAlbumLongExposures
    ]

    func albums(includeSmart: Bool) -> [[String: Any]] {
        var output: [[String: Any]] = []

        if includeSmart {
            for subtype in Self.smartAlbumSubtypes {
                let collections = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
                collections.enumerateObjects { collection, _, _ in
                    let count = PHAsset.fetchAssets(in: collection, options: nil).count
                    guard count > 0 else { return }
                    output.append([
                        "id": collection.localIdentifier,
                        "title": collection.localizedTitle ?? "제목 없음",
                        "kind": "smart",
                        "count": count
                    ])
                }
            }
        }

        let userAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        userAlbums.enumerateObjects { collection, _, _ in
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            output.append([
                "id": collection.localIdentifier,
                "title": collection.localizedTitle ?? "제목 없음",
                "kind": "user",
                "count": count
            ])
        }

        return output
    }

    func collection(id: String) throws -> PHAssetCollection {
        guard let collection = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [id], options: nil
        ).firstObject else {
            throw ToolError("앨범을 찾을 수 없습니다: \(id)")
        }
        return collection
    }

    // MARK: - Search

    struct Query {
        var albumID: String?
        var mediaType: String?
        var subtype: String?
        var startDate: Date?
        var endDate: Date?
        var favoritesOnly = false
        var hasLocation: Bool?
        var limit = 50
        var offset = 0
        var newestFirst = true
    }

    struct Page {
        let total: Int
        let assets: [PHAsset]
        /// 메모리 필터가 필요한 조건에서 스캔 상한에 걸렸는지.
        let scanTruncated: Bool
    }

    private static let scanLimit = 25_000

    func search(_ query: Query) throws -> Page {
        try ensureAuthorized()

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: !query.newestFirst)]

        var predicates: [NSPredicate] = []
        switch query.mediaType?.lowercased() {
        case "image", "photo":
            predicates.append(NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue))
        case "video":
            predicates.append(NSPredicate(format: "mediaType = %d", PHAssetMediaType.video.rawValue))
        case "audio":
            predicates.append(NSPredicate(format: "mediaType = %d", PHAssetMediaType.audio.rawValue))
        default:
            break
        }
        if let start = query.startDate { predicates.append(NSPredicate(format: "creationDate >= %@", start as NSDate)) }
        if let end = query.endDate { predicates.append(NSPredicate(format: "creationDate <= %@", end as NSDate)) }
        if query.favoritesOnly { predicates.append(NSPredicate(format: "favorite = YES")) }
        if !predicates.isEmpty {
            options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }

        let result: PHFetchResult<PHAsset>
        if let albumID = query.albumID {
            result = PHAsset.fetchAssets(in: try collection(id: albumID), options: options)
        } else {
            result = PHAsset.fetchAssets(with: options)
        }

        // 서브타입/위치는 술어로 안정적으로 표현하기 어려워 메모리에서 거른다.
        let needsScan = query.subtype != nil || query.hasLocation != nil
        guard needsScan else {
            let total = result.count
            let start = min(max(0, query.offset), total)
            let end = min(start + query.limit, total)
            var slice: [PHAsset] = []
            slice.reserveCapacity(end - start)
            for index in start..<end { slice.append(result.object(at: index)) }
            return Page(total: total, assets: slice, scanTruncated: false)
        }

        var matched: [PHAsset] = []
        var scanned = 0
        var truncated = false
        result.enumerateObjects { asset, _, stop in
            if scanned >= Self.scanLimit {
                truncated = true
                stop.pointee = true
                return
            }
            scanned += 1
            if self.matches(asset, query) { matched.append(asset) }
        }

        let total = matched.count
        let start = min(max(0, query.offset), total)
        let end = min(start + query.limit, total)
        return Page(total: total, assets: Array(matched[start..<end]), scanTruncated: truncated)
    }

    private func matches(_ asset: PHAsset, _ query: Query) -> Bool {
        if let wantsLocation = query.hasLocation, (asset.location != nil) != wantsLocation { return false }
        if let subtype = query.subtype, !Self.matchesSubtype(asset, subtype) { return false }
        return true
    }

    static func matchesSubtype(_ asset: PHAsset, _ name: String) -> Bool {
        let subtypes = asset.mediaSubtypes
        switch name.lowercased() {
        case "screenshot": return subtypes.contains(.photoScreenshot)
        case "live", "live_photo": return subtypes.contains(.photoLive)
        case "panorama": return subtypes.contains(.photoPanorama)
        case "hdr": return subtypes.contains(.photoHDR)
        case "portrait", "depth": return subtypes.contains(.photoDepthEffect)
        case "slomo", "slow_motion": return subtypes.contains(.videoHighFrameRate)
        case "timelapse": return subtypes.contains(.videoTimelapse)
        case "cinematic": return subtypes.contains(.videoCinematic)
        default: return true
        }
    }

    static func subtypeNames(_ asset: PHAsset) -> [String] {
        var names: [String] = []
        let subtypes = asset.mediaSubtypes
        if subtypes.contains(.photoScreenshot) { names.append("screenshot") }
        if subtypes.contains(.photoLive) { names.append("live") }
        if subtypes.contains(.photoPanorama) { names.append("panorama") }
        if subtypes.contains(.photoHDR) { names.append("hdr") }
        if subtypes.contains(.photoDepthEffect) { names.append("portrait") }
        if subtypes.contains(.videoHighFrameRate) { names.append("slomo") }
        if subtypes.contains(.videoTimelapse) { names.append("timelapse") }
        if subtypes.contains(.videoCinematic) { names.append("cinematic") }
        return names
    }

    // MARK: - Serialization

    /// 목록용 요약. 컨텍스트를 아끼려고 필드를 최소로 유지한다.
    func summary(_ asset: PHAsset) -> [String: Any] {
        var payload: [String: Any] = [
            "id": asset.localIdentifier,
            "type": Self.mediaTypeName(asset.mediaType),
            "created": JSONUtil.value(DateParse.iso8601(asset.creationDate)),
            "pixels": "\(asset.pixelWidth)x\(asset.pixelHeight)"
        ]
        if asset.isFavorite { payload["favorite"] = true }
        if asset.mediaType == .video { payload["duration_sec"] = (asset.duration * 10).rounded() / 10 }
        let subtypes = Self.subtypeNames(asset)
        if !subtypes.isEmpty { payload["subtypes"] = subtypes }
        if let location = asset.location {
            payload["location"] = [
                "lat": (location.coordinate.latitude * 1e6).rounded() / 1e6,
                "lon": (location.coordinate.longitude * 1e6).rounded() / 1e6
            ]
        }
        return payload
    }

    /// 상세 정보. 리소스 조회가 들어가므로 목록에는 쓰지 않는다.
    func details(_ asset: PHAsset) -> [String: Any] {
        var payload = summary(asset)
        payload["modified"] = JSONUtil.value(DateParse.iso8601(asset.modificationDate))
        payload["width"] = asset.pixelWidth
        payload["height"] = asset.pixelHeight
        payload["hidden"] = asset.isHidden
        payload["source"] = Self.sourceName(asset.sourceType)
        if let burst = asset.burstIdentifier { payload["burst_id"] = burst }

        if let location = asset.location {
            let coordinates: [String: Any] = [
                "lat": location.coordinate.latitude,
                "lon": location.coordinate.longitude,
                "altitude_m": (location.altitude * 10).rounded() / 10,
                "horizontal_accuracy_m": (location.horizontalAccuracy * 10).rounded() / 10,
                "timestamp": JSONUtil.value(DateParse.iso8601(location.timestamp))
            ]
            payload["location"] = coordinates
        }

        let resources = PHAssetResource.assetResources(for: asset)
        if !resources.isEmpty {
            payload["resources"] = resources.map { resource in
                [
                    "filename": resource.originalFilename,
                    "uti": resource.uniformTypeIdentifier,
                    "kind": Self.resourceTypeName(resource.type)
                ]
            }
        }
        return payload
    }

    static func mediaTypeName(_ type: PHAssetMediaType) -> String {
        switch type {
        case .image: return "image"
        case .video: return "video"
        case .audio: return "audio"
        default: return "unknown"
        }
    }

    private static func sourceName(_ source: PHAssetSourceType) -> String {
        if source.contains(.typeUserLibrary) { return "user_library" }
        if source.contains(.typeCloudShared) { return "cloud_shared" }
        if source.contains(.typeiTunesSynced) { return "itunes_synced" }
        return "unknown"
    }

    private static func resourceTypeName(_ type: PHAssetResourceType) -> String {
        switch type {
        case .photo: return "photo"
        case .video: return "video"
        case .audio: return "audio"
        case .alternatePhoto: return "alternate_photo"
        case .fullSizePhoto: return "full_size_photo"
        case .fullSizeVideo: return "full_size_video"
        case .adjustmentData: return "adjustment_data"
        case .adjustmentBasePhoto: return "adjustment_base_photo"
        case .pairedVideo: return "paired_video"
        case .fullSizePairedVideo: return "full_size_paired_video"
        case .adjustmentBasePairedVideo: return "adjustment_base_paired_video"
        case .adjustmentBaseVideo: return "adjustment_base_video"
        @unknown default: return "other"
        }
    }

    // MARK: - Image loading

    /// PhotoKit 콜백이 두 번 불릴 수 있어(저품질 → 고품질) 재개를 한 번으로 제한한다.
    private final class ResumeGuard {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    func image(for asset: PHAsset,
               maxDimension: CGFloat,
               contentMode: PHImageContentMode = .aspectFit,
               fast: Bool = false) async throws -> UIImage {
        let natural = CGSize(width: CGFloat(asset.pixelWidth), height: CGFloat(asset.pixelHeight))
        let target = natural.width > 0 && natural.height > 0
            ? ImageEncoding.fit(natural, maxDimension: maxDimension)
            : CGSize(width: maxDimension, height: maxDimension)

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true            // iCloud 사진도 받아온다
        options.deliveryMode = fast ? .fastFormat : .highQualityFormat
        options.resizeMode = fast ? .fast : .exact
        options.isSynchronous = false
        options.version = .current

        // fastFormat 은 결과 자체에 degraded 플래그가 붙기도 한다. 그 모드에서는
        // 첫 결과를 그대로 받고, highQualityFormat 에서만 중간 결과를 건너뛴다.
        let skipDegraded = !fast

        return try await withCheckedThrowingContinuation { continuation in
            let guardBox = ResumeGuard()
            imageManager.requestImage(for: asset,
                                      targetSize: target,
                                      contentMode: contentMode,
                                      options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
                if skipDegraded && degraded { return }
                guard guardBox.claim() else { return }
                if let image {
                    continuation.resume(returning: image)
                } else {
                    let reason = (info?[PHImageErrorKey] as? NSError)?.localizedDescription
                        ?? "이미지를 불러오지 못했습니다(iCloud 다운로드 실패일 수 있습니다)."
                    continuation.resume(throwing: ToolError(reason))
                }
            }
        }
    }

    func jpeg(for asset: PHAsset,
              maxDimension: CGFloat,
              quality: CGFloat,
              maxBytes: Int) async throws -> (data: Data, size: CGSize) {
        let image = try await self.image(for: asset, maxDimension: maxDimension)
        guard let data = ImageEncoding.jpeg(image, quality: quality, maxBytes: maxBytes) else {
            throw ToolError("JPEG 인코딩에 실패했습니다.")
        }
        return (data, image.size)
    }

    // MARK: - Video frames

    func videoFrame(for asset: PHAsset, atSeconds seconds: Double, maxDimension: CGFloat) async throws -> UIImage {
        guard asset.mediaType == .video else {
            throw ToolError("동영상이 아닙니다. photos_view 를 사용하세요.")
        }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat

        let avAsset: AVAsset = try await withCheckedThrowingContinuation { continuation in
            let guardBox = ResumeGuard()
            imageManager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                guard guardBox.claim() else { return }
                if let avAsset {
                    continuation.resume(returning: avAsset)
                } else {
                    let reason = (info?[PHImageErrorKey] as? NSError)?.localizedDescription
                        ?? "동영상을 불러오지 못했습니다."
                    continuation.resume(throwing: ToolError(reason))
                }
            }
        }

        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        let clamped = max(0, min(seconds, max(asset.duration - 0.05, 0)))
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        let (cgImage, _) = try await generator.image(at: time)
        return UIImage(cgImage: cgImage)
    }

    // MARK: - OCR

    func recognizeText(in asset: PHAsset, languages: [String]) async throws -> [String] {
        let image = try await self.image(for: asset, maxDimension: 2400)
        guard let cgImage = image.cgImage else {
            throw ToolError("이미지를 OCR 용으로 변환하지 못했습니다.")
        }

        func perform(_ languages: [String]) throws -> [String] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = languages
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }

        do {
            return try perform(languages)
        } catch {
            // 지원하지 않는 언어 코드가 섞이면 영어로 물러선다.
            return try perform(["en-US"])
        }
    }

    // MARK: - Export

    struct ExportResult {
        let url: URL
        let filename: String
        let byteCount: Int
    }

    func exportOriginal(_ asset: PHAsset) async throws -> ExportResult {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizePhoto })
            ?? resources.first(where: { $0.type == .photo })
            ?? resources.first(where: { $0.type == .fullSizeVideo })
            ?? resources.first(where: { $0.type == .video })
            ?? resources.first else {
            throw ToolError("내보낼 원본 리소스를 찾지 못했습니다.")
        }

        let destination = ExportStore.shared.stagingURL(filename: resource.originalFilename)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            resourceManager.writeData(for: resource, toFile: destination, options: options) { error in
                if let error {
                    continuation.resume(throwing: ToolError("원본 저장 실패: \(error.localizedDescription)"))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        return ExportResult(url: destination, filename: resource.originalFilename, byteCount: size)
    }

    func exportJPEG(_ asset: PHAsset, maxDimension: CGFloat, quality: CGFloat) async throws -> ExportResult {
        let image = try await self.image(for: asset, maxDimension: maxDimension)
        guard let data = image.jpegData(compressionQuality: quality) else {
            throw ToolError("JPEG 인코딩에 실패했습니다.")
        }
        let stem = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "asset"
        let filename = ((stem as NSString).deletingPathExtension) + ".jpg"
        let destination = ExportStore.shared.stagingURL(filename: filename)
        try data.write(to: destination)
        return ExportResult(url: destination, filename: filename, byteCount: data.count)
    }

    // MARK: - Stats

    func stats() throws -> [String: Any] {
        try ensureAuthorized()

        func count(_ subtype: PHAssetCollectionSubtype) -> Int {
            guard let collection = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum, subtype: subtype, options: nil
            ).firstObject else { return 0 }
            return PHAsset.fetchAssets(in: collection, options: nil).count
        }

        func boundary(newest: Bool) -> String? {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: !newest)]
            options.fetchLimit = 1
            return DateParse.iso8601(PHAsset.fetchAssets(with: options).firstObject?.creationDate)
        }

        let images = PHAsset.fetchAssets(with: .image, options: nil).count
        let videos = PHAsset.fetchAssets(with: .video, options: nil).count

        return [
            "images": images,
            "videos": videos,
            "total": images + videos,
            "favorites": count(.smartAlbumFavorites),
            "screenshots": count(.smartAlbumScreenshots),
            "selfies": count(.smartAlbumSelfPortraits),
            "live_photos": count(.smartAlbumLivePhotos),
            "panoramas": count(.smartAlbumPanoramas),
            "bursts": count(.smartAlbumBursts),
            "oldest": JSONUtil.value(boundary(newest: false)),
            "newest": JSONUtil.value(boundary(newest: true)),
            "access": isLimitedAccess ? "limited" : "full",
            "user_albums": PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).count
        ]
    }

    // MARK: - Writes

    private func performChanges(_ changes: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: ToolError(error?.localizedDescription ?? "사진 라이브러리 변경에 실패했습니다."))
                }
            }
        }
    }

    func setFavorite(_ asset: PHAsset, favorite: Bool) async throws {
        try await performChanges {
            PHAssetChangeRequest(for: asset).isFavorite = favorite
        }
    }

    func createAlbum(title: String) async throws -> String {
        final class Box { var identifier: String? }
        let box = Box()

        try await performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            box.identifier = request.placeholderForCreatedAssetCollection.localIdentifier
        }

        guard let identifier = box.identifier else {
            throw ToolError("앨범을 만들었지만 식별자를 얻지 못했습니다.")
        }
        return identifier
    }

    func addAssets(_ assets: [PHAsset], to collection: PHAssetCollection) async throws {
        guard !assets.isEmpty else { throw ToolError("추가할 자산이 없습니다.") }
        try await performChanges {
            guard let request = PHAssetCollectionChangeRequest(for: collection) else { return }
            request.addAssets(assets as NSFastEnumeration)
        }
    }
}
