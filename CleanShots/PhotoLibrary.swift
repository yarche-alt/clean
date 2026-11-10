import Photos
import UIKit

/// Доступ к медиатеке: читаем скриншоты, грузим миниатюры, удаляем выбранное.
@MainActor
final class PhotoLibrary: ObservableObject {

    @Published var authorization: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var items: [ScreenshotItem] = []

    // MARK: - Доступ

    func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorization = status
        return status == .authorized || status == .limited
    }

    // MARK: - Чтение скриншотов

    /// Забирает всё из системного альбома «Снимки экрана»
    func fetchScreenshots() {
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumScreenshots,
            options: nil
        )
        guard let album = collections.firstObject else {
            items = []
            return
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(in: album, options: options)

        var fetched: [ScreenshotItem] = []
        fetched.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            let bytes = (PHAssetResource.assetResources(for: asset).first?
                .value(forKey: "fileSize") as? Int) ?? 0
            fetched.append(ScreenshotItem(
                id: asset.localIdentifier,
                asset: asset,
                fileBytes: bytes
            ))
        }
        items = fetched
    }

    // MARK: - Миниатюры

    /// Асинхронно загружает картинку ассета. Для скорости сначала может прийти
    /// «грубая» версия — берём только финальную.
    nonisolated func loadImage(for asset: PHAsset, targetSize: CGSize) async -> UIImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            options.resizeMode = .fast
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !resumed, !degraded else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }

    // MARK: - Обновление элемента после анализа

    func applyResult(id: String, thumbnail: UIImage?, verdict: ShotVerdict, matched: [String]) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].thumbnail = thumbnail
        items[index].verdict = verdict
        items[index].matched = matched
    }

    func removeItems(withIDs ids: Set<String>) {
        items.removeAll { ids.contains($0.id) }
    }

    // MARK: - Удаление

    /// Удаляет ассеты. iOS сама покажет системное подтверждение,
    /// а файлы попадут в «Недавно удалённые» на 30 дней.
    func delete(itemsToDelete: [ScreenshotItem]) async throws {
        let assets = itemsToDelete.map { $0.asset } as NSArray
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }
}
